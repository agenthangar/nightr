import Foundation

public enum PauseReason: String, Codable, Sendable { case stopped, asleep, maintenanceWake, battery, inactivity, connectivity, setup, ownership, crashLimit, loginOptOut }
public enum InternetState: String, Codable, Sendable { case unknown, checking, verified, unavailable, stale }
public enum JoinResult: String, Codable, Sendable { case associated, unavailable, missingCredential, permissionDenied, failed }
public struct MachineSample: Codable, Equatable, Sendable {
    public var onBattery: Bool
    public var batteryPercent: Int?
    public var agentObservation: AgentObservation?
    public var activity: ActivityObservation?
    public var agentActive: Bool
    public var lidClosed: Bool
    public var setupReady: Bool
    public init(onBattery: Bool = false, batteryPercent: Int? = nil, agentActive: Bool = false, lidClosed: Bool = false, setupReady: Bool = true, agentObservation: AgentObservation? = nil, activity: ActivityObservation? = nil) {
        self.agentObservation = agentObservation; self.activity = activity
        self.onBattery = onBattery; self.batteryPercent = batteryPercent; self.agentActive = agentActive; self.lidClosed = lidClosed; self.setupReady = setupReady
    }
}
public struct OutageLedger: Codable, Equatable, Sendable {
    public var beganAt: Date
    public var capturedLimit: Int
    public var consumed = 0
    public var prompted = false
    public var skipped = false
    public var nextAttemptAt: Date
    public var repairRequired: JoinResult?
    public init(now: Date, settings: Settings) {
        beganAt = now; capturedLimit = settings.hotspotAttempts
        nextAttemptAt = now.addingTimeInterval(Double(settings.hotspotAfter))
    }
}
public struct ControllerState: Codable, Equatable, Sendable {
    public var schemaVersion = 1
    public var desiredEnabled = false
    public var pause: PauseReason? = .stopped
    public var resumePause: PauseReason?
    public var outage: OutageLedger?
    public var crashRestarts = 0
    public var uncleanShutdown = false
    public var internet: InternetState = .unknown
    public var lastInternetVerified = false
    public var verifiedAt: Date?
    public var lastVerificationStarted: Date?
    public var lastAgentActiveAt: Date?
    public var lastInternetAvailableAt: Date?
    public var agentSamples = 0
    public var retryFor: PauseReason?
    public var failureBeganAt: Date?
    public var conditionRetries = 0
    public var nextConditionRetryAt: Date?
    public init() {}
}
public enum MonitorEvent: Sendable {
    case bootstrap(wasUnclean: Bool, afterDesktopInstall: Bool = false)
    case lifecycleStarted, lifecycleStopped, start, stop, beginForce, endForce, tick(MachineSample), sample(MachineSample), sleep, normalWake, maintenanceWake, pathChanged
    case internetResult(UUID, Bool), hotspotResult(UUID, JoinResult)
    case retryNow, tryAgain, skipFallback, settings(Settings), login, crashed, ownershipLost
}
public enum MonitorEffect: Equatable, Sendable {
    case acquireHold(Settings), releaseHold, cancelOperations
    case verifyInternet(UUID, timeout: TimeInterval), joinHotspot(UUID, ssid: String, timeout: TimeInterval)
    case promptHotspot, persist
}

/// All decisions are deterministic and system mutations belong to ControllerPlatform.
/// In-flight identities are deliberately not persisted: reservations are persisted before effects.
public struct MonitorEngine: Sendable {
    public private(set) var settings: Settings
    public private(set) var state: ControllerState
    public private(set) var sample = MachineSample()
    public private(set) var holding = false
    public private(set) var verificationToken: UUID?
    public private(set) var joinToken: UUID?
    // Force is a session override. Only the pre-existing enabled intent may survive a restart.
    public private(set) var forceMode = false
    private var forcePriorIntent: (enabled: Bool, pause: PauseReason?)?
    public var journalState: ControllerState {
        var durable = state
        if let prior = forcePriorIntent, !prior.enabled || prior.pause == .loginOptOut {
            durable.desiredEnabled = prior.enabled
            durable.pause = prior.pause
            durable.resumePause = nil
        }
        return durable
    }
    private var asleep = false
    private var maintenance = false
    private var pendingSettings: Settings?
    private var lastConditionCheck: Date?
    private var inferenceWasActive = false
    private var agentCheckingBeganAt: Date?
    private var checkingAllowanceWasActive = false
    private var lastAgentObservation: AgentObservation?
    public init(settings: Settings = Settings(), state: ControllerState = ControllerState(), sample: MachineSample = MachineSample()) { self.settings = settings; self.state = state; self.sample = sample; self.asleep = state.pause == .asleep || state.pause == .maintenanceWake; self.maintenance = state.pause == .maintenanceWake }
    public mutating func replaceActivityObservation(_ observation: ActivityObservation?) { sample.activity = observation }
    public var verificationEligible: Bool {
        !forceMode && settings.monitoring && settings.internet && state.desiredEnabled && !asleep && !maintenance && sample.setupReady && !unsafeBattery &&
        ![PauseReason.stopped, .ownership, .crashLimit, .loginOptOut].contains(where: { state.pause == $0 })
    }
    public var unsafeBattery: Bool { settings.batteryProtection && sample.onBattery && (sample.batteryPercent.map { $0 < settings.batteryBelow } ?? true) }
    public mutating func handle(_ event: MonitorEvent, now: Date) -> [MonitorEffect] {
        var effects: [MonitorEffect] = []
        var changedSettings = false
        switch event {
        case .lifecycleStarted: state.uncleanShutdown = true
        case .lifecycleStopped: state.uncleanShutdown = false; return [.persist]
        case .bootstrap(let wasUnclean, let afterDesktopInstall):
            state.uncleanShutdown = true
            state.crashRestarts = wasUnclean ? min(3, state.crashRestarts) + 1 : 0
            if state.desiredEnabled {
                if !settings.launchAtLogin && !afterDesktopInstall { state.pause = .loginOptOut }
                else if state.crashRestarts > 3 { state.pause = .crashLimit }
                else if !hardPause && !asleep { refreshSamples(now: now); state.lastInternetVerified = false; state.internet = .unknown }
            }
        case .beginForce:
            guard !forceMode, state.pause != .ownership, state.pause != .crashLimit else { return [] }
            forcePriorIntent = (state.desiredEnabled, state.pause)
            forceMode = true
            state.desiredEnabled = true
            if !asleep && !maintenance { state.pause = nil }
            state.resumePause = nil
            state.internet = .unknown
            state.lastInternetVerified = false
            cancel(&effects)
        case .endForce:
            guard forceMode else { return [] }
            forceMode = false
            if let prior = forcePriorIntent, !prior.enabled || prior.pause == .loginOptOut {
                state.desiredEnabled = prior.enabled
                state.pause = prior.pause
            }
            forcePriorIntent = nil
            state.lastVerificationStarted = nil
            refreshSamples(now: now)
        case .stop:
            forceMode = false
            forcePriorIntent = nil
            state.desiredEnabled = false; state.pause = .stopped; state.failureBeganAt = nil
            cancel(&effects); release(&effects)
        case .start:
            forceMode = false
            forcePriorIntent = nil
            state.desiredEnabled = true; state.pause = nil; state.resumePause = nil; state.crashRestarts = 0
            refreshSamples(now: now); state.internet = .unknown; state.lastInternetVerified = false
        case .settings(let value): pendingSettings = value
        case .sample(let value): sample = value
        case .tick(let value):
            sample = value
            if let pendingSettings {
                changedSettings = settings != pendingSettings
                let previouslyRequiredInternet = settings.monitoring && settings.internet
                let changedHotspot = !settings.hotspotSSID.utf8.elementsEqual(pendingSettings.hotspotSSID.utf8)
                settings = pendingSettings; self.pendingSettings = nil
                if !settings.monitoring || !settings.internet {
                    cancel(&effects); state.internet = .unknown; state.lastInternetVerified = false
                    if previouslyRequiredInternet {
                        // A deliberate policy change can make only this cause obsolete.
                        if state.pause == .connectivity { state.pause = nil; resetConditions() }
                        if state.resumePause == .connectivity { state.resumePause = nil }
                    }
                } else if !settings.hotspot || changedHotspot {
                    cancelJoin(&effects)
                    if changedHotspot { state.outage?.repairRequired = nil }
                }
            }
        case .sleep:
            asleep = true; maintenance = false
            if state.desiredEnabled { state.pause = .asleep }; state.internet = .stale
            cancel(&effects); release(&effects)
        case .maintenanceWake:
            maintenance = true; asleep = true
            if state.desiredEnabled { state.pause = .maintenanceWake }
            cancel(&effects); release(&effects)
        case .normalWake:
            asleep = false; maintenance = false; state.resumePause = nil; state.lastVerificationStarted = nil; state.lastInternetVerified = false
            if state.desiredEnabled && !hardPause { state.pause = nil; refreshSamples(now: now); state.internet = .stale }
        case .pathChanged:
            if state.internet != .checking { state.internet = .stale }
        case .internetResult(let token, let success):
            guard token == verificationToken else { return [] }
            verificationToken = nil
            guard verificationEligible else { return [] }
            let recovered = success && !state.lastInternetVerified
            state.internet = success ? .verified : .unavailable; state.lastInternetVerified = success
            if success {
                state.verifiedAt = now; state.outage = nil; cancelJoin(&effects)
                state.lastInternetAvailableAt = now
                if recovered { refreshSamples(now: now); if state.pause == .connectivity { state.pause = nil }; lastConditionCheck = nil }
            } else if state.outage == nil { state.outage = OutageLedger(now: now, settings: settings) }
        case .hotspotResult(let token, let result):
            guard token == joinToken else { return [] }
            joinToken = nil
            if let consumed = state.outage?.consumed { state.outage?.nextAttemptAt = now.addingTimeInterval(min(300, 30 * pow(2, Double(consumed - 1)))) }
            if result == .missingCredential || result == .permissionDenied { state.outage?.repairRequired = result }
            // Wi-Fi association is never internet proof.
        case .retryNow:
            if verificationEligible, joinToken == nil, let outage = state.outage, outage.consumed < outage.capturedLimit {
                // Explicit user retry can follow a repair; automatic retries stay suppressed.
                state.outage?.repairRequired = nil; state.outage?.skipped = false; state.outage?.nextAttemptAt = now
            }
        case .tryAgain:
            if verificationEligible && state.outage.map({ $0.consumed >= $0.capturedLimit }) == true && joinToken == nil {
                state.outage = OutageLedger(now: now, settings: settings); state.outage?.nextAttemptAt = now
            }
        case .skipFallback:
            state.outage?.skipped = true; cancelJoin(&effects)
        case .login:
            if !settings.launchAtLogin { state.pause = .loginOptOut; cancel(&effects); release(&effects) }
            else if state.desiredEnabled && !hardPause { state.pause = nil; resetConditions(); state.internet = .unknown }
        case .crashed:
            state.crashRestarts = min(3, state.crashRestarts) + 1
            if state.desiredEnabled && state.crashRestarts > 3 { state.pause = .crashLimit }
        case .ownershipLost: state.pause = .ownership; cancel(&effects); release(&effects)
        }
        if !state.desiredEnabled { release(&effects) }
        else if asleep || maintenance { release(&effects) }
        else if hardPause { cancel(&effects); release(&effects) }
        else if !sample.setupReady { rememberSafetyPause(); state.pause = .setup; cancel(&effects); release(&effects) }
        else if unsafeBattery { rememberSafetyPause(); state.pause = .battery; cancel(&effects); release(&effects) }
        else if forceMode {
            state.pause = nil
            if !holding { holding = true; effects.append(.acquireHold(settings)) }
        }
        else if !hardPause {
            if state.pause == .battery || state.pause == .setup { state.pause = state.resumePause; state.resumePause = nil; refreshSamples(now: now); state.internet = .stale }
            if state.pause != .inactivity {
                if changedSettings || sample.agentObservation != lastAgentObservation || checkingAllowance(now: now) != checkingAllowanceWasActive || inferenceActive(now: now) || inferenceWasActive || (state.nextConditionRetryAt.map({ now >= $0 }) ?? false) || (lastConditionCheck.map({ now.timeIntervalSince($0) >= Double(settings.every) }) ?? true) {
                    evaluateConditions(now: now, effects: &effects); lastConditionCheck = now
                }
            }
        }
        lastAgentObservation = sample.agentObservation
        checkingAllowanceWasActive = checkingAllowance(now: now)
        inferenceWasActive = inferenceActive(now: now)
        if verificationEligible {
            startVerification(now: now, effects: &effects)
            startHotspot(now: now, effects: &effects)
        }
        if changedSettings && holding && !effects.contains(.acquireHold(settings)) { effects.append(.acquireHold(settings)) }
        effects.append(.persist)
        return effects
    }
    private var fallbackEligible: Bool { verificationEligible && settings.hotspot && !settings.hotspotSSID.isEmpty }
    private var hardPause: Bool { [.stopped, .ownership, .crashLimit, .loginOptOut].contains(where: { state.pause == $0 }) }
    private mutating func resetConditions() { lastConditionCheck = nil; state.failureBeganAt = nil; state.conditionRetries = 0; state.nextConditionRetryAt = nil; state.retryFor = nil }
    private mutating func rememberSafetyPause() {
        if state.pause == .inactivity || state.pause == .connectivity { state.resumePause = state.pause }
    }
    private mutating func refreshSamples(now: Date) {
        agentCheckingBeganAt = now
        resetConditions(); state.lastAgentActiveAt = now; state.lastInternetAvailableAt = now; state.agentSamples = 0
    }
    public var inferenceEligible: Bool {
        !forceMode && settings.localInference && pendingSettings?.localInference != false && !settings.forever && state.desiredEnabled && !asleep && !maintenance && sample.setupReady && !unsafeBattery && !hardPause && state.pause != .inactivity && state.resumePause != .inactivity
    }
    private func inferenceActive(now: Date) -> Bool { inferenceEligible && (sample.activity?.hasActiveInference(at: now) ?? false) }
    private func checkingAllowance(now: Date) -> Bool {
        guard sample.agentObservation == .checking, let beganAt = agentCheckingBeganAt else { return false }
        let age = now.timeIntervalSince(beganAt)
        return age >= 0 && age < 15
    }
    private mutating func evaluateConditions(now: Date, effects: inout [MonitorEffect]) {
        let inference = inferenceActive(now: now)
        if state.pause == .connectivity && !state.lastInternetVerified && !inference { release(&effects); return }
        if state.lastAgentActiveAt == nil { state.lastAgentActiveAt = now }
        if state.lastInternetAvailableAt == nil { state.lastInternetAvailableAt = now }
        state.agentSamples = min(Int.max - 1, state.agentSamples) + 1
        let observedAgentActive = sample.agentObservation.map { $0 == .active } ?? sample.agentActive
        if observedAgentActive { state.lastAgentActiveAt = now }
        if state.lastInternetVerified { state.lastInternetAvailableAt = now }
        // Local processing is independent; only real agent/internet observations
        // update their respective grace timestamps above.
        if inference {
            if state.pause == .connectivity { state.pause = nil }
            if state.pause == nil && !holding { holding = true; effects.append(.acquireHold(settings)) }
            return
        }
        // The first bounded asynchronous probe must be allowed to complete even
        // with zero user grace. Checking is never an activity/grace observation.
        let checkingPass = checkingAllowance(now: now)
        let agentPass = observedAgentActive || checkingPass || state.agentSamples <= 1 || now.timeIntervalSince(state.lastAgentActiveAt!) <= Double(settings.grace)
        let internetPass = state.lastInternetVerified || now.timeIntervalSince(state.lastInternetAvailableAt!) <= Double(settings.grace)
        if settings.conditionsPass(agentActive: agentPass, internetVerified: internetPass) {
            resetConditions()
            if state.pause == .connectivity { state.pause = nil }
            if state.pause == nil && !holding { holding = true; effects.append(.acquireHold(settings)) }
            return
        }
        // Grace is tracked independently for each selected signal, matching legacy runs.
        if state.pause == .connectivity { release(&effects); return }
        let missing: PauseReason = settings.internet && !internetPass ? .connectivity : .inactivity
        if state.retryFor != missing {
            resetConditions(); state.retryFor = missing; state.failureBeganAt = now
        }
        if !holding { holding = true; effects.append(.acquireHold(settings)) }
        if state.conditionRetries < settings.retries {
            if state.nextConditionRetryAt == nil {
                state.nextConditionRetryAt = now.addingTimeInterval(min(300, Double(settings.backoff) * pow(2, Double(state.conditionRetries))))
            }
            if let deadline = state.nextConditionRetryAt, now >= deadline {
                state.conditionRetries += 1
                state.nextConditionRetryAt = state.conditionRetries < settings.retries ? now.addingTimeInterval(min(300, Double(settings.backoff) * pow(2, Double(state.conditionRetries)))) : nil
            }
            if state.conditionRetries < settings.retries { return }
        }
        // A live bounded fallback cycle gets its configured outage delay and attempts.
        if let outage = state.outage, fallbackEligible, !outage.skipped, outage.repairRequired == nil,
           outage.consumed < outage.capturedLimit || joinToken != nil { return }
        state.pause = missing
        release(&effects)
    }
    private mutating func startVerification(now: Date, effects: inout [MonitorEffect]) {
        guard verificationToken == nil, state.lastVerificationStarted.map({ now.timeIntervalSince($0) >= Double(settings.every) }) ?? true else { return }
        let token = UUID(); verificationToken = token; state.lastVerificationStarted = now; state.internet = .checking
        effects.append(.verifyInternet(token, timeout: 10))
    }
    private mutating func startHotspot(now: Date, effects: inout [MonitorEffect]) {
        guard fallbackEligible, joinToken == nil, var outage = state.outage,
              !outage.skipped, outage.repairRequired == nil, outage.consumed < outage.capturedLimit,
              now >= outage.nextAttemptAt else { return }
        if !outage.prompted { outage.prompted = true; effects.append(.promptHotspot) }
        outage.consumed += 1
        outage.nextAttemptAt = now.addingTimeInterval(30 + min(300, 30 * pow(2, Double(outage.consumed - 1))))
        state.outage = outage
        let token = UUID(); joinToken = token
        effects.append(.joinHotspot(token, ssid: settings.hotspotSSID, timeout: min(30, Double(settings.hotspotTimeout))))
    }
    private mutating func release(_ effects: inout [MonitorEffect]) { if holding { holding = false; effects.append(.releaseHold) } }
    private mutating func cancelJoin(_ effects: inout [MonitorEffect]) { if joinToken != nil { joinToken = nil; effects.append(.cancelOperations); verificationToken = nil } }
    private mutating func cancel(_ effects: inout [MonitorEffect]) { verificationToken = nil; joinToken = nil; effects.append(.cancelOperations) }
}
