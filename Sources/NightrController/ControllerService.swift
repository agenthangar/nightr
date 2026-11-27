import Foundation
import NightrCore
#if canImport(OSLog)
import OSLog
#endif
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

public actor ControllerService {
    private let platform: any ControllerPlatform
    private let settingsStore: SettingsStore
    private let runtimeDirectory: URL
    private var ownership: RuntimeOwnership?
    private var socket: ControllerSocket?
    private var engine: MonitorEngine
    private var timer: Task<Void, Never>?
    private var operations: [UUID: Task<Void, Never>] = [:]
    private var cancellationBarrier: Task<Void, Never>?
    private var generation = 0
    private var protection: ProtectionExecutor?
    private var protectionConfirmed = false
    private var protectionEpoch = 0
    private var message: String?
    private var running = false
    private var persistenceError: String?
    private var inferenceLeases = InferenceLeases()
    private var rawSample = MachineSample()
    public init(platform: any ControllerPlatform, settingsStore: SettingsStore = SettingsStore(), runtimeDirectory: URL = NightrPaths.runtime) throws {
        self.platform = platform; self.settingsStore = settingsStore; self.runtimeDirectory = runtimeDirectory
        engine = MonitorEngine(settings: try settingsStore.load())
    }
    public func start(afterDesktopInstall: Bool = false) async throws {
        guard !running else { return }
        ownership = try RuntimeOwnership(directory: runtimeDirectory)
        do {
            let state = try StateJournal.load(directory: runtimeDirectory)
            engine = MonitorEngine(settings: try settingsStore.load(), state: state)
            let initialSample = await platform.sample()
            rawSample = initialSample; inferenceLeases.clear()
            engine = MonitorEngine(settings: engine.settings, state: engine.state, sample: initialSample)
            let wasUnclean = engine.state.uncleanShutdown
            protection = ProtectionExecutor(platform: platform) { [weak self] epoch, holding, error in
                await self?.protectionChanged(epoch: epoch, holding: holding, error: error)
            }
            running = true
            socket = try ControllerSocket(directory: runtimeDirectory) { [weak self] request, peer in
                guard let self else { return ControllerResponse(error: "controller stopping") }
                return await self.request(request, peer: peer)
            }
            await send(.bootstrap(wasUnclean: wasUnclean, afterDesktopInstall: afterDesktopInstall))
            timer = Task { [weak self] in
                while !Task.isCancelled {
                    do { try await Task.sleep(nanoseconds: 1_000_000_000) } catch { return }
                    guard let self else { return }
                    let sample = await self.platform.sample(checkAgentActivity: !self.engine.forceMode)
                    await self.send(.tick(sample))
                }
            }
        } catch { running = false; socket?.stop(); socket = nil; protection = nil; ownership = nil; throw error }
    }
    public func isRunning() -> Bool { running }
    public func status() -> ControllerStatus { ControllerStatus(engine: engine, message: message, holding: protectionConfirmed && engine.holding) }
    public func request(_ request: ControllerRequest, peer: ControllerPeer? = nil) async -> ControllerResponse {
        guard request.version == ControllerRequest.version else { return ControllerResponse(error: "incompatible controller protocol") }
        do {
            var requestError: String?
            var inferenceToken: UUID?
            switch request.command {
            case .status: break
            case .start:
                if let requested = request.settings {
                    try requested.validate()
                    if engine.state.desiredEnabled && requested != engine.settings { return ControllerResponse(error: "monitor is already running with different settings; stop it first") }
                    if requested != engine.settings {
                        guard !engine.state.desiredEnabled else { return ControllerResponse(error: "conflicting run settings") }
                        engine = MonitorEngine(settings: requested, state: engine.state, sample: engine.sample)
                    }
                }
                requestError = await send(.start)
            case .beginForce: requestError = await send(.beginForce)
            case .endForce: requestError = await send(.endForce)
            case .stop: requestError = await send(.stop)
            case .applySettings:
                guard let settings = request.settings else { return ControllerResponse(error: "settings required") }
                try settings.validate(); requestError = await send(.settings(settings))
            case .retryNow: requestError = await send(.retryNow)
            case .tryAgain: requestError = await send(.tryAgain)
            case .skipFallback: requestError = await send(.skipFallback)
            case .inferenceBegin, .inferenceHeartbeat, .inferenceEnd:
                guard running, let peer, peer.uid == getuid(), engine.inferenceEligible else { return ControllerResponse(error: "local inference is disabled or protection is paused; producer cannot start protection") }
                let uptime = ProcessInfo.processInfo.systemUptime
                switch request.command {
                case .inferenceBegin:
                    guard let metadata = request.inference else { return ControllerResponse(error: "inference metadata required") }
                    inferenceToken = try inferenceLeases.begin(metadata, peer: peer, uptime: uptime)
                case .inferenceHeartbeat:
                    guard let token = request.inferenceToken else { return ControllerResponse(error: "inference token required") }
                    try inferenceLeases.heartbeat(token, peer: peer, uptime: uptime); inferenceToken = token
                case .inferenceEnd:
                    guard let token = request.inferenceToken else { return ControllerResponse(error: "inference token required") }
                    try inferenceLeases.end(token, peer: peer, uptime: uptime)
                default: break
                }
                requestError = await send(.tick(rawSample))
            case .prepareUpdate: await shutdown(preserveIntent: true)
            }
            return ControllerResponse(status: status(), error: requestError ?? persistenceError, inferenceToken: inferenceToken)
        } catch { return ControllerResponse(error: error.localizedDescription) }
    }
    @discardableResult public func send(_ event: MonitorEvent) async -> String? {
        guard running else { return "controller stopping" }
        let now = Date()
        let effectiveEvent: MonitorEvent
        switch event {
        case .tick(let sample), .sample(let sample):
            rawSample = sample
            var effective = sample
            effective.activity = inferenceLeases.adding(to: sample.activity, now: now, uptime: ProcessInfo.processInfo.systemUptime)
            if case .tick = event { effectiveEvent = .tick(effective) } else { effectiveEvent = .sample(effective) }
        case .stop, .sleep, .maintenanceWake, .ownershipLost, .bootstrap, .crashed, .login:
            inferenceLeases.clear(); engine.replaceActivityObservation(rawSample.activity); effectiveEvent = event
        case .settings(let settings):
            if !settings.localInference { inferenceLeases.clear(); engine.replaceActivityObservation(rawSample.activity) }; effectiveEvent = event
        default: effectiveEvent = event
        }
        let wasBatteryPaused = engine.state.pause == .battery
        let effects = engine.handle(effectiveEvent, now: now)
        var cancelBatterySleep = wasBatteryPaused && engine.state.pause != .battery
        if wasBatteryPaused, case .settings(let settings) = effectiveEvent,
           !settings.batteryProtection || settings.batteryBelow < engine.settings.batteryBelow {
            cancelBatterySleep = true
        }
        if !engine.inferenceEligible { inferenceLeases.clear(); engine.replaceActivityObservation(rawSample.activity) }
        if cancelBatterySleep || effects.contains(where: { effect in
            switch effect { case .acquireHold, .releaseHold, .releaseHoldForBattery: return true; default: return false }
        }) { protectionEpoch += 1 }
        let transitionEpoch = protectionEpoch
        // Desired intent and consumed attempt reservations reach disk before any external effect.
        do { try persist(); persistenceError = nil }
        catch {
            message = "Unable to persist controller safety state: \(error.localizedDescription)"
            let failure = message
            persistenceError = failure
            _ = engine.handle(.stop, now: Date()); generation += 1
            operations.values.forEach { $0.cancel() }; operations.removeAll()
            protectionEpoch += 1; await protection?.submit(nil, epoch: protectionEpoch); await cancelPlatformOperations(); return failure
        }
        if cancelBatterySleep { await protection?.submit(nil, epoch: transitionEpoch) }
        for effect in effects {
            switch effect {
            case .persist: break
            case .cancelOperations:
                generation += 1; operations.values.forEach { $0.cancel() }; operations.removeAll(); await cancelPlatformOperations()
            case .releaseHold:
                if transitionEpoch == protectionEpoch && !engine.holding { await protection?.submit(nil, epoch: transitionEpoch) }
            case .releaseHoldForBattery(let cutoff):
                if transitionEpoch == protectionEpoch && engine.state.pause == .battery {
                    #if canImport(OSLog)
                    if protectionConfirmed, let percent = engine.sample.batteryPercent {
                        Logger(subsystem: "ai.nightr", category: "battery").notice("battery-cutoff percent=\(percent, privacy: .public) cutoff=\(cutoff, privacy: .public)")
                    }
                    #endif
                    await protection?.submit(nil, epoch: transitionEpoch, sleepBelow: protectionConfirmed ? cutoff : nil)
                }
            case .acquireHold(let settings):
                if transitionEpoch == protectionEpoch && engine.holding && settings == engine.settings { await protection?.submit(settings, epoch: transitionEpoch) }
            case .verifyInternet(let token, let timeout):
                guard running, engine.verificationEligible, engine.verificationToken == token else { continue }
                operations[token] = Task { [weak self] in guard let self else { return }; await self.performVerification(token: token, timeout: timeout) }
            case .joinHotspot(let token, let ssid, let timeout):
                guard running, engine.verificationEligible, engine.joinToken == token else { continue }
                operations[token] = Task { [weak self] in guard let self else { return }; await self.performJoin(token: token, ssid: ssid, timeout: timeout) }
            case .promptHotspot:
                if engine.verificationEligible { await platform.notifyHotspot() }
            }
        }
        return nil
    }
    private func cancelPlatformOperations() async {
        let barrier = Task { [platform] in await platform.cancelOperations() }
        cancellationBarrier = barrier
        await barrier.value
    }
    private func performVerification(token: UUID, timeout: TimeInterval) async {
        await cancellationBarrier?.value
        guard !Task.isCancelled, running, engine.verificationEligible, engine.verificationToken == token else { operations[token] = nil; return }
        let result = await platform.verifyInternet(timeout: timeout)
        guard !Task.isCancelled else { return }
        await completed(.internetResult(token, result), token: token)
    }
    private func performJoin(token: UUID, ssid: String, timeout: TimeInterval) async {
        await cancellationBarrier?.value
        guard !Task.isCancelled, running, engine.verificationEligible, engine.joinToken == token else { operations[token] = nil; return }
        let result = await platform.joinHotspot(ssid: ssid, timeout: timeout)
        guard !Task.isCancelled else { return }
        await completed(.hotspotResult(token, result), token: token)
    }
    private func protectionChanged(epoch: Int, holding: Bool, error: String?) async {
        guard epoch == protectionEpoch else { return }
        protectionConfirmed = holding && engine.holding
        if let error { message = error; if running { await send(.ownershipLost) } }
    }
    private func completed(_ event: MonitorEvent, token: UUID) async { operations[token] = nil; await send(event) }
    public func shutdown(preserveIntent: Bool = false) async {
        guard running else { return }
        if !preserveIntent { await send(.stop) }
        await send(.lifecycleStopped)
        inferenceLeases.clear()
        running = false; generation += 1; timer?.cancel(); timer = nil
        operations.values.forEach { $0.cancel() }; operations.removeAll()
        protectionEpoch += 1; await protection?.submit(nil, epoch: protectionEpoch)
        await cancelPlatformOperations(); await protection?.flush(); protection = nil
        socket?.stop(); socket = nil; ownership = nil
    }
    private func persist() throws { try StateJournal.save(engine.journalState, directory: runtimeDirectory) }
}
