#if os(macOS)
import Foundation
import IOKit
import IOKit.ps
import IOKit.pwr_mgt
import UserNotifications
import Security
import OSLog
import NightrCore
import NightrController
import NightrPowerClient
import NightrPowerProtocol

private final class NoRedirects: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}

public enum ProtectionFailure: Error, LocalizedError {
    case setup, lease, assertion
    public var errorDescription: String? {
        switch self {
        case .setup: return "The signed power helper needs setup. Closed-lid protection is unavailable."
        case .lease: return "The power helper lease ended. Protection has been released."
        case .assertion: return "macOS could not create the awake assertion."
        }
    }
}

public actor MacControllerPlatform: ControllerPlatform {
    private var power: SignedPowerClient?
    private var powerTeam: String?
    private var pendingAcquire: SignedPowerClient?
    private var lease: String?
    private var protectionGeneration = UUID()
    private var renewer: Task<Void, Never>?
    private var assertions: [IOPMAssertionID] = []
    private var displayAssertion: IOPMAssertionID?
    private var heldSettings: Settings?
    private var lidWasClosed = false
    private let displayActions = DisplayActions()
    private var activeJoin: BoundedProcess?
    private var internetTask: URLSessionDataTask?
    private var ready = false
    private var lastReadiness = Date.distantPast
    private let agentActivity = AgentActivityMonitor()
    private let activityTelemetry = ActivityTelemetry()
    private let worker: NetworkWorkerClient
    private var session: URLSession?
    public init() {
        let bundle = Bundle.main.bundleURL
        let executable = bundle.pathExtension == "app" ? bundle.appendingPathComponent("Contents/MacOS/NightrNetworkWorker") :
            URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().appendingPathComponent("NightrNetworkWorker")
        worker = NetworkWorkerClient(executable: executable)
        if let team = Self.signedTeam(),
           let client = try? SignedPowerClient(teamID: team) { powerTeam = team; power = client }
    }
    public static func signedTeam() -> String? {
        var code: SecCode?
        var staticCode: SecStaticCode?
        var information: CFDictionary?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code,
              SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode,
              SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess,
              let values = information as? [String: Any],
              let identifier = values[kSecCodeInfoIdentifier as String] as? String,
              ["ai.nightr.app", "ai.nightr.controller"].contains(identifier),
              let team = values[kSecCodeInfoTeamIdentifier as String] as? String,
              let expression = try? SigningPolicy.requirement(teamID: team, identifiers: [identifier]) else { return nil }
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(expression as CFString, [], &requirement) == errSecSuccess,
              SecCodeCheckValidity(code, [], requirement) == errSecSuccess else { return nil }
        return team
    }
    public func acquireProtection(settings: Settings) async throws {
        guard let power = currentPower() else { throw ProtectionFailure.setup }
        let generation = protectionGeneration
        if let token = lease {
            do {
                _ = try await withCheckedThrowingContinuation { continuation in
                    power.update(lease: token, batteryThreshold: settings.batteryProtection ? settings.batteryBelow : 0) { continuation.resume(with: $0) }
                }
                guard !Task.isCancelled, lease == token else { throw ProtectionFailure.lease }
                heldSettings = settings; try updateDisplay(lidClosed: lidWasClosed, force: true)
                return
            } catch {
                if generation == protectionGeneration { await releaseProtection() }
                throw error
            }
        }
        pendingAcquire = power
        let reply: NightrPowerProtocol.PowerReply
        do {
            reply = try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    power.acquire(batteryThreshold: settings.batteryProtection ? settings.batteryBelow : 0) { continuation.resume(with: $0) }
                }
            } onCancel: { power.invalidate() }
        } catch {
            power.invalidate()
            if pendingAcquire === power { pendingAcquire = nil }
            if self.power === power { self.power = nil }
            ready = false; lastReadiness = Date()
            throw error
        }
        if pendingAcquire === power { pendingAcquire = nil }
        guard !Task.isCancelled, let token = reply.lease, reply.active else { power.invalidate(); throw ProtectionFailure.lease }
        guard generation == protectionGeneration else {
            power.invalidate()
            throw ProtectionFailure.lease
        }
        lease = token; ready = true
        do {
            try assertion(kIOPMAssertionTypePreventUserIdleSystemSleep as CFString)
            heldSettings = settings
            try updateDisplay(lidClosed: lidWasClosed, force: true)
        } catch { await releaseProtection(); throw error }
        renewer = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(nanoseconds: 10_000_000_000) } catch { return }
                await self?.renew()
            }
        }
    }
    private func assertion(_ kind: CFString) throws {
        var id: IOPMAssertionID = 0
        guard IOPMAssertionCreateWithName(kind, IOPMAssertionLevel(kIOPMAssertionLevelOn), "Nightr coding-agent protection" as CFString, &id) == kIOReturnSuccess else { throw ProtectionFailure.assertion }
        assertions.append(id)
    }
    private func renew() async {
        guard let power, let lease else { return }
        do {
            _ = try await withCheckedThrowingContinuation { continuation in power.renew(lease: lease) { continuation.resume(with: $0) } }
        } catch { if self.lease == lease { ready = false; lastReadiness = Date(); await releaseProtection() } }
    }
    public func releaseProtection() async {
        protectionGeneration = UUID()
        pendingAcquire?.invalidate(); pendingAcquire = nil
        renewer?.cancel(); renewer = nil
        if let id = displayAssertion { IOPMAssertionRelease(id) }; displayAssertion = nil
        _ = displayActions.restore(); heldSettings = nil
        assertions.forEach { IOPMAssertionRelease($0) }; assertions = []
        let client = power, token = lease
        power = nil; lease = nil
        if let client, let token {
            _ = try? await withCheckedThrowingContinuation { continuation in client.release(lease: token) { continuation.resume(with: $0) } }
        }
        client?.invalidate()
    }
    public func requestBatterySleep(below cutoff: Int) async {
        guard !Task.isCancelled, let powerTeam, let client = try? SignedPowerClient(teamID: powerTeam) else { return }
        defer { client.invalidate() }
        let process = BoundedProcess()
        await withTaskCancellationHandler {
            do {
                try await BatterySleepCommand.request(
                    below: cutoff,
                    restoration: {
                        let reply = try await withCheckedThrowingContinuation { continuation in
                            client.status { continuation.resume(with: $0) }
                        }
                        return (reply.active, reply.restorationBlocked)
                    },
                    hasLease: { self.lease != nil },
                    battery: { Self.batteryStatus() },
                    execute: { executable, arguments, timeout in
                        try await Task.detached {
                            _ = try process.run(executable: executable, arguments: arguments, timeout: timeout)
                        }.value
                    }
                )
            } catch NativeOperationError.cancelled {
                return
            } catch {
                Logger(subsystem: "ai.nightr", category: "battery").error("macOS battery cutoff sleep request failed: \(error.localizedDescription, privacy: .public)")
            }
        } onCancel: { process.cancel() }
    }
    private func updateDisplay(lidClosed: Bool, force: Bool) throws {
        guard let settings = heldSettings else { return }
        if !lidClosed { _ = displayActions.restore() }
        let keepDisplay = !lidClosed || settings.displayOn || settings.dim
        if keepDisplay && displayAssertion == nil {
            var id: IOPMAssertionID = 0
            guard IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString, IOPMAssertionLevel(kIOPMAssertionLevelOn), "Nightr display policy" as CFString, &id) == kIOReturnSuccess else { throw ProtectionFailure.assertion }
            displayAssertion = id
        } else if !keepDisplay, let id = displayAssertion { IOPMAssertionRelease(id); displayAssertion = nil }
        if lidClosed && (force || !lidWasClosed) {
            if settings.lock { try displayActions.lock() }
            if settings.dim { try displayActions.dim() }
            else if !settings.displayOn {
                _ = try BoundedProcess().run(executable: URL(fileURLWithPath: "/usr/bin/pmset"), arguments: ["displaysleepnow"], timeout: 3)
            }
        }
    }
    private func currentPower() -> SignedPowerClient? {
        if power == nil, let powerTeam { power = try? SignedPowerClient(teamID: powerTeam) }
        return power
    }
    public func cancelOperations() async {
        activeJoin?.cancel(); internetTask?.cancel(); session?.invalidateAndCancel(); session = nil
        if let pendingAcquire {
            protectionGeneration = UUID(); pendingAcquire.invalidate()
            if power === pendingAcquire { power = nil }
            self.pendingAcquire = nil
        }
    }
    public func verifyInternet(timeout: TimeInterval) async -> Bool {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = min(5, max(0.1, timeout / 2))
        configuration.timeoutIntervalForResource = min(5, max(0.1, timeout / 2))
        configuration.httpCookieStorage = nil; configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        let checking = URLSession(configuration: configuration, delegate: NoRedirects(), delegateQueue: nil); session = checking
        defer { checking.invalidateAndCancel(); session = nil; internetTask = nil }
        // A TLS exchange, rather than path association, proves usable internet.
        for address in ["https://api.anthropic.com/", "https://api.openai.com/"] {
            guard !Task.isCancelled else { return false }
            var request = URLRequest(url: URL(string: address)!); request.httpMethod = "HEAD"
            do {
                let (_, response) = try await checking.data(for: request)
                if let http = response as? HTTPURLResponse, http.url?.host == URL(string: address)?.host,
                   (200...499).contains(http.statusCode) { return true }
            } catch {}
        }
        return false
    }
    public func joinHotspot(ssid: String, timeout: TimeInterval) async -> JoinResult {
        let process = BoundedProcess(); activeJoin = process; let worker = self.worker
        defer { activeJoin = nil }
        let result = await withTaskCancellationHandler {
            await Task.detached { try? worker.join(ssid: ssid, timeout: timeout, process: process) }.value
        } onCancel: { process.cancel() }
        switch result {
        case .associated: return .associated
        case .credentialMissing: return .missingCredential
        case .permissionDenied: return .permissionDenied
        case .notSeen, .unavailable: return .unavailable
        default: return .failed
        }
    }
    public func sample() async -> MachineSample { await sample(checkAgentActivity: true) }
    public func sample(checkAgentActivity: Bool) async -> MachineSample {
        if Date().timeIntervalSince(lastReadiness) >= 10, lease == nil {
            lastReadiness = Date()
            if let power = currentPower() {
                let reply = try? await withCheckedThrowingContinuation { continuation in power.status { continuation.resume(with: $0) } }
                ready = reply != nil && reply?.restorationBlocked == false
                if reply == nil { power.invalidate(); if self.power === power { self.power = nil } }
            } else { ready = false }
        }
        let battery = Self.batteryStatus()
        let root = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        var lid = false
        if root != 0 {
            let closed = (IORegistryEntryCreateCFProperty(root, "AppleClamshellState" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? Bool) ?? false
            let causesSleep = (IORegistryEntryCreateCFProperty(root, "AppleClamshellCausesSleep" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? Bool) ?? false
            lid = closed && causesSleep
            IOObjectRelease(root)
        }
        if lid != lidWasClosed {
            do { try updateDisplay(lidClosed: lid, force: false) }
            catch { ready = false; lastReadiness = Date(); await releaseProtection() }
            lidWasClosed = lid
        }
        let agent = await agentActivity.snapshot(enabled: checkAgentActivity)
        let telemetry = await activityTelemetry.snapshot()
        return MachineSample(onBattery: battery.onBattery, batteryPercent: battery.percent, agentActive: agent == .active,
                             lidClosed: lid, setupReady: ready, agentObservation: agent, activity: telemetry)
    }
    private static func batteryStatus() -> (onBattery: Bool, percent: Int?) {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return (false, nil) }
        for source in sources {
            guard let description = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
                  description[kIOPSTypeKey] as? String == kIOPSInternalBatteryType else { continue }
            let onBattery = description[kIOPSPowerSourceStateKey] as? String == kIOPSBatteryPowerValue
            guard let current = description[kIOPSCurrentCapacityKey] as? Int,
                  let total = description[kIOPSMaxCapacityKey] as? Int,
                  total > 0, current >= 0, current <= total else { return (onBattery, nil) }
            return (onBattery, Int(Double(current) * 100 / Double(total)))
        }
        return (false, nil)
    }
    public func notifyHotspot() async {
        let content = UNMutableNotificationContent()
        content.title = "Check Personal Hotspot"
        content.body = "Turn on Personal Hotspot on your phone if the saved network is not broadcasting. Open Nightr for retry and repair options."
        // No implicit notification permission prompt during recovery.
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else { return }
        try? await center.add(UNNotificationRequest(identifier: "nightr-hotspot", content: content, trigger: nil))
    }
}
#endif
