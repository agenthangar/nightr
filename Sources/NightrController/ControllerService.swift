import Foundation
import NightrCore
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
            engine = MonitorEngine(settings: engine.settings, state: engine.state, sample: initialSample)
            let wasUnclean = engine.state.uncleanShutdown
            protection = ProtectionExecutor(platform: platform) { [weak self] epoch, holding, error in
                await self?.protectionChanged(epoch: epoch, holding: holding, error: error)
            }
            running = true
            socket = try ControllerSocket(directory: runtimeDirectory) { [weak self] request in
                guard let self else { return ControllerResponse(error: "controller stopping") }
                return await self.request(request)
            }
            await send(.bootstrap(wasUnclean: wasUnclean, afterDesktopInstall: afterDesktopInstall))
            timer = Task { [weak self] in
                while !Task.isCancelled {
                    do { try await Task.sleep(nanoseconds: 1_000_000_000) } catch { return }
                    guard let self else { return }
                    let sample = await self.platform.sample()
                    await self.send(.tick(sample))
                }
            }
        } catch { running = false; socket?.stop(); socket = nil; protection = nil; ownership = nil; throw error }
    }
    public func isRunning() -> Bool { running }
    public func status() -> ControllerStatus { ControllerStatus(engine: engine, message: message, holding: protectionConfirmed && engine.holding) }
    public func request(_ request: ControllerRequest) async -> ControllerResponse {
        guard request.version == ControllerRequest.version else { return ControllerResponse(error: "incompatible controller protocol") }
        do {
            var requestError: String?
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
            case .stop: requestError = await send(.stop)
            case .applySettings:
                guard let settings = request.settings else { return ControllerResponse(error: "settings required") }
                try settings.validate(); requestError = await send(.settings(settings))
            case .retryNow: requestError = await send(.retryNow)
            case .tryAgain: requestError = await send(.tryAgain)
            case .skipFallback: requestError = await send(.skipFallback)
            case .prepareUpdate: await shutdown(preserveIntent: true)
            }
            return ControllerResponse(status: status(), error: requestError ?? persistenceError)
        } catch { return ControllerResponse(error: error.localizedDescription) }
    }
    @discardableResult public func send(_ event: MonitorEvent) async -> String? {
        guard running else { return "controller stopping" }
        let effects = engine.handle(event, now: Date())
        if effects.contains(where: { effect in
            switch effect { case .acquireHold, .releaseHold: return true; default: return false }
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
            await cancelPlatformOperations(); protectionEpoch += 1; await protection?.submit(nil, epoch: protectionEpoch); return failure
        }
        for effect in effects {
            switch effect {
            case .persist: break
            case .cancelOperations:
                generation += 1; operations.values.forEach { $0.cancel() }; operations.removeAll(); await cancelPlatformOperations()
            case .releaseHold:
                if transitionEpoch == protectionEpoch && !engine.holding { await protection?.submit(nil, epoch: transitionEpoch) }
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
        running = false; generation += 1; timer?.cancel(); timer = nil
        operations.values.forEach { $0.cancel() }; operations.removeAll()
        await cancelPlatformOperations(); protectionEpoch += 1; await protection?.submit(nil, epoch: protectionEpoch); await protection?.flush(); protection = nil
        socket?.stop(); socket = nil; ownership = nil
    }
    private func persist() throws { try StateJournal.save(engine.state, directory: runtimeDirectory) }
}
