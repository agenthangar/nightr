import XCTest
import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif
@testable import NightrCore
@testable import NightrController

final class CoreTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 1_000)
    func testBatteryCutoffDefaultsAndSavedOptOut() throws {
        XCTAssertTrue(Settings().batteryProtection)
        XCTAssertTrue(try JSONDecoder().decode(Settings.self, from: Data("{}".utf8)).batteryProtection)
        XCTAssertFalse(try JSONDecoder().decode(Settings.self, from: Data(#"{"battery_protection":false}"#.utf8)).batteryProtection)
    }

    func testForceOverridesChecksButHonorsSafetyAndOriginalIntent() {
        let now = Date()
        var engine = MonitorEngine()
        _ = engine.handle(.beginForce, now: now)
        XCTAssertTrue(engine.holding)
        XCTAssertFalse(engine.verificationEligible)
        _ = engine.handle(.pathChanged, now: now)
        XCTAssertEqual(GUIProtectionSummary(status: ControllerStatus(engine: engine)).internet, "Checks paused")
        XCTAssertFalse(engine.journalState.desiredEnabled)
        _ = engine.handle(.beginForce, now: now)
        _ = engine.handle(.tick(.init(onBattery: true, batteryPercent: 5)), now: now)
        XCTAssertFalse(engine.holding)
        XCTAssertEqual(engine.state.pause, .battery)
        _ = engine.handle(.tick(.init(onBattery: false, batteryPercent: 5)), now: now)
        XCTAssertTrue(engine.forceMode)
        XCTAssertTrue(engine.holding)
        XCTAssertNil(engine.state.pause)
        _ = engine.handle(.tick(.init(onBattery: true, batteryPercent: 5)), now: now)
        XCTAssertFalse(engine.holding)
        XCTAssertEqual(engine.state.pause, .battery)
        _ = engine.handle(.endForce, now: now)
        XCTAssertFalse(engine.state.desiredEnabled)
        _ = engine.handle(.start, now: now)
        _ = engine.handle(.beginForce, now: now)
        XCTAssertTrue(engine.journalState.desiredEnabled)
        _ = engine.handle(.endForce, now: now)
        XCTAssertTrue(engine.state.desiredEnabled)
        XCTAssertFalse(engine.settings.forever)
        _ = engine.handle(.beginForce, now: now)
        _ = engine.handle(.stop, now: now)
        XCTAssertFalse(engine.forceMode)
        XCTAssertFalse(engine.holding)
    }

    func testLegacyDefaultsAndPoliciesRoundTrip() throws {
        let settings = try JSONDecoder().decode(Settings.self, from: Data("{\"requirement\":99,\"agent\":false,\"internet\":false,\"every\":900,\"grace\":90001,\"dim\":true,\"inactivity\":47}".utf8))
        XCTAssertEqual(settings.requirement, .count(99)); XCTAssertFalse(settings.monitoring)
        XCTAssertEqual(settings.every, 900); XCTAssertEqual(settings.grace, 90001)
        XCTAssertTrue(settings.displayOn); XCTAssertEqual(settings.inactivity, 47)
        XCTAssertEqual(try JSONDecoder().decode(Settings.self, from: JSONEncoder().encode(settings)), settings)
    }
    func testLocalModelCanBeTheOnlyProtectionCondition() throws {
        var settings = Settings()
        settings.setProtectionCondition(\.agent, enabled: false)
        settings.setProtectionCondition(\.internet, enabled: false)
        XCTAssertThrowsError(try settings.validateProtectionSelection(edited: true))
        XCTAssertNoThrow(try settings.validateProtectionSelection(edited: false))
        settings.setProtectionCondition(\.localInference, enabled: true)
        try settings.validateProtectionSelection(edited: true)
        var engine = MonitorEngine(settings: settings)
        _ = engine.handle(.start, now: now)
        XCTAssertFalse(engine.holding)
        XCTAssertFalse(engine.verificationEligible)
        XCTAssertTrue(engine.inferenceEligible)
        XCTAssertEqual(GUIProtectionSummary(status: .init(engine: engine)).detail, "Waiting for local model activity.")

        let model = LocalModelObservation(id: "sample", residency: .loaded, activity: .generating,
                                          inferenceExpiresAt: now.addingTimeInterval(10))
        var sample = MachineSample(activity: .init(runtimes: [.init(runtime: .lmStudio, observedAt: now, models: [model])]))
        XCTAssertTrue(engine.handle(.tick(sample), now: now).contains(.acquireHold(settings)))
        XCTAssertTrue(engine.handle(.tick(sample), now: now.addingTimeInterval(10)).contains(.releaseHold))
        XCTAssertTrue(engine.inferenceEligible)
        sample.activity?.runtimes[0].observedAt = now.addingTimeInterval(12)
        sample.activity?.runtimes[0].models[0].inferenceExpiresAt = now.addingTimeInterval(22)
        XCTAssertTrue(engine.handle(.tick(sample), now: now.addingTimeInterval(12)).contains(.acquireHold(settings)))
        XCTAssertTrue(engine.handle(.stop, now: now.addingTimeInterval(13)).contains(.releaseHold))
        _ = engine.handle(.tick(sample), now: now.addingTimeInterval(14))
        XCTAssertFalse(engine.holding)

        settings.requirement = .none
        var legacy = MonitorEngine(settings: settings)
        XCTAssertTrue(legacy.handle(.start, now: now).contains(.acquireHold(settings)))
        settings.requirement = .all
        settings.setProtectionCondition(\.localInference, enabled: false)
        XCTAssertThrowsError(try settings.validateProtectionSelection(edited: true))
    }

    func testPendingAgentCheckIsVisibleWithoutReportingAnActiveAgent() {
        var settings = Settings()
        settings.internet = false
        var state = ControllerState()
        state.desiredEnabled = true
        state.pause = nil
        var engine = MonitorEngine(settings: settings, state: state, sample: .init(agentObservation: .checking))
        let pending = GUIProtectionSummary(status: .init(engine: engine))
        XCTAssertEqual(pending.label, "Checking…")
        XCTAssertFalse(pending.showsActiveAgent)
        _ = engine.handle(.beginForce, now: now)
        let forced = GUIProtectionSummary(status: .init(engine: engine))
        XCTAssertEqual(forced.label, "Force mode")
        XCTAssertFalse(forced.showsActiveAgent)
    }
    func testStrictSettingsAndExactSSID() throws {
        for json in ["{\"every\":true}", "{\"every\":0}", "{\"retries\":11}", "{\"hotspot_attempts\":0}", "{\"unknown\":1}", "{\"requirement\":0}"] {
            XCTAssertThrowsError(try JSONDecoder().decode(Settings.self, from: Data(json.utf8)), json)
        }
        try Settings.validateSSID("  "); try Settings.validateSSID("éphone ")
        var composed = Settings(); composed.hotspotSSID = "é"
        var decomposed = Settings(); decomposed.hotspotSSID = "e\u{301}"
        XCTAssertNotEqual(composed, decomposed)
        for ssid in ["", "phone\n", String(repeating: "é", count: 17)] { XCTAssertThrowsError(try Settings.validateSSID(ssid)) }
    }
    func testGroupedLegacyFlagsAndModeRetention() throws {
        var saved = Settings(); saved.requirement = .count(1); saved.dim = true; saved.displayOn = true
        let settings = try CLIOptions.applying(["-dML", "-mLI", "-AI", "-f", "-e60", "--grace=1000"], to: saved)
        XCTAssertTrue(settings.dim); XCTAssertFalse(settings.lock); XCTAssertFalse(settings.agent); XCTAssertFalse(settings.internet)
        XCTAssertEqual(settings.every, 60); XCTAssertEqual(settings.grace, 1000)
        XCTAssertEqual(settings.requirement, .count(1)); XCTAssertTrue(settings.forever)
    }
    func testStopWinsLateNetworkAndWake() {
        var engine = MonitorEngine(); _ = engine.handle(.start, now: now)
        let token = engine.verificationToken!
        let effects = engine.handle(.stop, now: now)
        XCTAssertTrue(effects.contains(.releaseHold)); XCTAssertFalse(engine.holding)
        _ = engine.handle(.internetResult(token, true), now: now)
        _ = engine.handle(.normalWake, now: now)
        _ = engine.handle(.pathChanged, now: now)
        XCTAssertFalse(engine.holding); XCTAssertFalse(engine.state.desiredEnabled); XCTAssertNil(engine.verificationToken)
    }
    func testMaintenanceSleepAndBatteryGuards() {
        var settings = Settings(); settings.forever = true; settings.batteryProtection = true
        var engine = MonitorEngine(settings: settings)
        _ = engine.handle(.start, now: now); XCTAssertTrue(engine.holding)
        _ = engine.handle(.tick(MachineSample(onBattery: true, batteryPercent: 19)), now: now)
        XCTAssertFalse(engine.holding); XCTAssertEqual(engine.state.pause, .battery)
        _ = engine.handle(.normalWake, now: now); XCTAssertFalse(engine.holding)
        _ = engine.handle(.tick(MachineSample(onBattery: false, batteryPercent: 5)), now: now)
        XCTAssertTrue(engine.holding)
        _ = engine.handle(.sleep, now: now); _ = engine.handle(.maintenanceWake, now: now)
        _ = engine.handle(.pathChanged, now: now.addingTimeInterval(300))
        XCTAssertFalse(engine.holding); XCTAssertNil(engine.verificationToken)
        _ = engine.handle(.normalWake, now: now.addingTimeInterval(301)); XCTAssertTrue(engine.holding)
    }
    func testFreshNormalWakeAndSingleVerificationCadence() {
        var engine = MonitorEngine(); _ = engine.handle(.start, now: now)
        let token = engine.verificationToken!
        _ = engine.handle(.pathChanged, now: now.addingTimeInterval(2)); XCTAssertEqual(engine.verificationToken, token)
        _ = engine.handle(.internetResult(token, true), now: now.addingTimeInterval(3))
        _ = engine.handle(.pathChanged, now: now.addingTimeInterval(4)); XCTAssertNil(engine.verificationToken)
        _ = engine.handle(.sleep, now: now.addingTimeInterval(5))
        _ = engine.handle(.normalWake, now: now.addingTimeInterval(6)); XCTAssertNotNil(engine.verificationToken)
    }
    func testLiveCheckIntervalReschedulesInternetWithoutOverlappingProbes() throws {
        var settings = Settings()
        settings.every = 60
        var engine = MonitorEngine(settings: settings)
        _ = engine.handle(.start, now: now)
        let first = try XCTUnwrap(engine.verificationToken)
        _ = engine.handle(.internetResult(first, true), now: now.addingTimeInterval(1))
        _ = engine.handle(.tick(MachineSample()), now: now.addingTimeInterval(30))
        XCTAssertNil(engine.verificationToken)
        settings.every = 5
        _ = engine.handle(.settings(settings), now: now.addingTimeInterval(31))
        _ = engine.handle(.tick(MachineSample()), now: now.addingTimeInterval(31))
        let second = try XCTUnwrap(engine.verificationToken)
        _ = engine.handle(.tick(MachineSample()), now: now.addingTimeInterval(37))
        XCTAssertEqual(engine.verificationToken, second)
        settings.internet = false
        _ = engine.handle(.settings(settings), now: now.addingTimeInterval(38))
        _ = engine.handle(.tick(MachineSample()), now: now.addingTimeInterval(38))
        _ = engine.handle(.internetResult(second, true), now: now.addingTimeInterval(39))
        XCTAssertNil(engine.verificationToken)
        XCTAssertEqual(engine.state.internet, .unknown)
    }

    func testSavingAnotherHotspotRetiresPreviousAttemptAndPreservesBudget() throws {
        var settings = Settings()
        settings.hotspot = true
        settings.hotspotAfter = 0
        settings.hotspotSSID = "é"
        var engine = MonitorEngine(settings: settings)
        _ = engine.handle(.start, now: now)
        let verify = try XCTUnwrap(engine.verificationToken)
        _ = engine.handle(.internetResult(verify, false), now: now)
        let oldJoin = try XCTUnwrap(engine.joinToken)
        settings.hotspotSSID = "e\u{301}"
        _ = engine.handle(.settings(settings), now: now)
        let applied = engine.handle(.tick(MachineSample()), now: now)
        XCTAssertTrue(applied.contains(.cancelOperations))
        _ = engine.handle(.hotspotResult(oldJoin, .missingCredential), now: now)
        XCTAssertNil(engine.state.outage?.repairRequired)
        let retry = engine.handle(.retryNow, now: now)
        let target = retry.compactMap { effect -> String? in
            if case let .joinHotspot(_, ssid, _) = effect { return ssid }
            return nil
        }.first
        XCTAssertEqual(try XCTUnwrap(target).utf8.map { $0 }, Array(settings.hotspotSSID.utf8))
        XCTAssertEqual(engine.state.outage?.consumed, 2)
        XCTAssertFalse(retry.contains(.promptHotspot))
    }

    func testCapturedOutageBudgetPersistsAndExhaustionStillVerifies() throws {
        var settings = Settings(); settings.agent = false; settings.hotspot = true; settings.hotspotSSID = " phone "; settings.hotspotAfter = 0; settings.hotspotAttempts = 1
        var engine = MonitorEngine(settings: settings)
        _ = engine.handle(.start, now: now)
        _ = engine.handle(.internetResult(engine.verificationToken!, false), now: now)
        let join = engine.joinToken!; XCTAssertEqual(engine.state.outage?.consumed, 1)
        _ = engine.handle(.hotspotResult(join, .associated), now: now.addingTimeInterval(1))
        XCTAssertNotEqual(engine.state.internet, .verified)
        settings.hotspotAttempts = 10
        _ = engine.handle(.settings(settings), now: now.addingTimeInterval(2))
        _ = engine.handle(.tick(MachineSample()), now: now.addingTimeInterval(3))
        XCTAssertEqual(engine.state.outage?.capturedLimit, 1)
        let state = try JSONDecoder().decode(ControllerState.self, from: JSONEncoder().encode(engine.state))
        var restored = MonitorEngine(settings: settings, state: state)
        _ = restored.handle(.tick(MachineSample()), now: now.addingTimeInterval(300))
        XCTAssertNil(restored.joinToken); XCTAssertNotNil(restored.verificationToken)
        _ = restored.handle(.retryNow, now: now.addingTimeInterval(301)); XCTAssertNil(restored.joinToken)
        _ = restored.handle(.tryAgain, now: now.addingTimeInterval(302))
        XCTAssertEqual(restored.state.outage?.capturedLimit, 10); XCTAssertEqual(restored.state.outage?.consumed, 1)
    }
    func testRepairAndPromptOncePerOutage() {
        var settings = Settings(); settings.hotspot = true; settings.hotspotSSID = "phone"; settings.hotspotAfter = 0
        var engine = MonitorEngine(settings: settings); _ = engine.handle(.start, now: now)
        let effects = engine.handle(.internetResult(engine.verificationToken!, false), now: now)
        XCTAssertEqual(effects.filter { $0 == .promptHotspot }.count, 1)
        _ = engine.handle(.hotspotResult(engine.joinToken!, .missingCredential), now: now)
        _ = engine.handle(.tick(MachineSample()), now: now.addingTimeInterval(60))
        XCTAssertNil(engine.joinToken) // Repair is never retried automatically.
        let retry = engine.handle(.retryNow, now: now.addingTimeInterval(61))
        XCTAssertNotNil(engine.joinToken); XCTAssertFalse(retry.contains(.promptHotspot))
        XCTAssertEqual(engine.state.outage?.consumed, 2); XCTAssertEqual(engine.state.outage?.capturedLimit, 3)
        _ = engine.handle(.retryNow, now: now.addingTimeInterval(62))
        XCTAssertEqual(engine.state.outage?.consumed, 2) // An active join cannot spend twice.
    }
    func testInactivityWaitsForNormalWakeWhileConnectivityCanResume() {
        var settings = Settings(); settings.grace = 0; settings.retries = 0; settings.agent = false
        var engine = MonitorEngine(settings: settings)
        _ = engine.handle(.sample(MachineSample(lidClosed: true)), now: now)
        _ = engine.handle(.start, now: now)
        _ = engine.handle(.tick(MachineSample(lidClosed: true)), now: now.addingTimeInterval(31))
        XCTAssertEqual(engine.state.pause, .connectivity)
        _ = engine.handle(.internetResult(engine.verificationToken!, true), now: now)
        XCTAssertTrue(engine.holding)
        settings.agent = true; settings.internet = false
        var idle = MonitorEngine(settings: settings)
        _ = idle.handle(.sample(MachineSample(lidClosed: true)), now: now)
        _ = idle.handle(.start, now: now)
        _ = idle.handle(.tick(MachineSample(lidClosed: true)), now: now.addingTimeInterval(31))
        XCTAssertEqual(idle.state.pause, .inactivity)
        _ = idle.handle(.pathChanged, now: now)
        XCTAssertNil(idle.verificationToken); XCTAssertFalse(idle.holding)
    }
    func testCrashAndBatteryCannotRearmInactivityPause() {
        var state = ControllerState(); state.desiredEnabled = true; state.pause = .inactivity; state.uncleanShutdown = true
        var settings = Settings(); settings.batteryProtection = true
        var engine = MonitorEngine(settings: settings, state: state)
        _ = engine.handle(.bootstrap(wasUnclean: true), now: now)
        XCTAssertEqual(engine.state.pause, .inactivity); XCTAssertFalse(engine.holding)
        _ = engine.handle(.tick(MachineSample(onBattery: true, batteryPercent: 10)), now: now)
        XCTAssertEqual(engine.state.pause, .battery)
        _ = engine.handle(.tick(MachineSample(onBattery: false)), now: now.addingTimeInterval(1))
        XCTAssertEqual(engine.state.pause, .inactivity); XCTAssertFalse(engine.holding)
        state.pause = nil; state.crashRestarts = 3
        var exhausted = MonitorEngine(settings: settings, state: state)
        _ = exhausted.handle(.bootstrap(wasUnclean: true), now: now)
        XCTAssertEqual(exhausted.state.pause, .crashLimit); XCTAssertNil(exhausted.verificationToken); XCTAssertFalse(exhausted.holding)
        _ = exhausted.handle(.normalWake, now: now)
        XCTAssertFalse(exhausted.holding)
    }
    func testDesktopInstallRestoresEnabledIntentIndependentlyOfLoginPreference() {
        var settings = Settings(); settings.launchAtLogin = false; settings.forever = true
        var enabled = ControllerState(); enabled.desiredEnabled = true; enabled.pause = nil
        var resumed = MonitorEngine(settings: settings, state: enabled)
        _ = resumed.handle(.bootstrap(wasUnclean: false, afterDesktopInstall: true), now: now)
        XCTAssertTrue(resumed.holding)
        XCTAssertTrue(resumed.state.desiredEnabled)

        var login = MonitorEngine(settings: settings, state: enabled)
        _ = login.handle(.bootstrap(wasUnclean: false), now: now)
        XCTAssertFalse(login.holding)
        XCTAssertEqual(login.state.pause, .loginOptOut)
    }
    func testDesktopInstallRespectsStoppedIntentAndSafetyPauses() {
        var settings = Settings(); settings.launchAtLogin = false; settings.forever = true
        settings.batteryProtection = true
        let afterInstall = MonitorEvent.bootstrap(wasUnclean: false, afterDesktopInstall: true)
        var stopped = MonitorEngine(settings: settings)
        _ = stopped.handle(afterInstall, now: now)
        XCTAssertFalse(stopped.holding)
        XCTAssertFalse(stopped.state.desiredEnabled)
        XCTAssertEqual(stopped.state.pause, .stopped)

        var enabled = ControllerState(); enabled.desiredEnabled = true; enabled.pause = nil
        var battery = MonitorEngine(settings: settings, state: enabled, sample: MachineSample(onBattery: true, batteryPercent: 5))
        _ = battery.handle(afterInstall, now: now)
        XCTAssertFalse(battery.holding)
        XCTAssertEqual(battery.state.pause, .battery)
        XCTAssertTrue(battery.state.desiredEnabled)
    }
    func testConditionCadenceAndBackoffDeadlines() {
        var settings = Settings(); settings.internet = false; settings.grace = 0; settings.retries = 3
        var engine = MonitorEngine(settings: settings, sample: MachineSample(lidClosed: true))
        _ = engine.handle(.start, now: now)
        _ = engine.handle(.tick(MachineSample(lidClosed: true)), now: now.addingTimeInterval(1))
        XCTAssertEqual(engine.state.agentSamples, 1)
        _ = engine.handle(.tick(MachineSample(lidClosed: true)), now: now.addingTimeInterval(31))
        XCTAssertEqual(engine.state.nextConditionRetryAt, now.addingTimeInterval(61))
        _ = engine.handle(.tick(MachineSample(lidClosed: true)), now: now.addingTimeInterval(61))
        XCTAssertEqual(engine.state.conditionRetries, 1)
        XCTAssertEqual(engine.state.nextConditionRetryAt, now.addingTimeInterval(121))
        _ = engine.handle(.tick(MachineSample(lidClosed: true)), now: now.addingTimeInterval(121))
        XCTAssertEqual(engine.state.nextConditionRetryAt, now.addingTimeInterval(241))
        _ = engine.handle(.tick(MachineSample(lidClosed: true)), now: now.addingTimeInterval(241))
        XCTAssertEqual(engine.state.pause, .inactivity); XCTAssertFalse(engine.holding)
    }
    func testAutomaticHoldReleasesAfterBothChecksFailWithEitherLidPosition() {
        var settings = Settings(); settings.requirement = .count(1)
        for lidClosed in [false, true] {
            let idle = MachineSample(lidClosed: lidClosed)
            var engine = MonitorEngine(settings: settings, sample: MachineSample(agentActive: true, lidClosed: lidClosed))
            _ = engine.handle(.start, now: now)
            _ = engine.handle(.internetResult(engine.verificationToken!, true), now: now)
            _ = engine.handle(.tick(idle), now: now.addingTimeInterval(30))
            _ = engine.handle(.internetResult(engine.verificationToken!, false), now: now.addingTimeInterval(31))
            _ = engine.handle(.tick(idle), now: now.addingTimeInterval(930))
            XCTAssertTrue(engine.holding)
            _ = engine.handle(.tick(idle), now: now.addingTimeInterval(960))
            XCTAssertEqual(engine.state.nextConditionRetryAt, now.addingTimeInterval(990))
            _ = engine.handle(.tick(idle), now: now.addingTimeInterval(990))
            _ = engine.handle(.tick(idle), now: now.addingTimeInterval(1050))
            XCTAssertTrue(engine.holding)
            let effects = engine.handle(.tick(idle), now: now.addingTimeInterval(1170))
            XCTAssertTrue(effects.contains(.releaseHold))
            XCTAssertFalse(engine.holding)
            XCTAssertTrue(engine.state.desiredEnabled)
            XCTAssertEqual(engine.state.pause, .connectivity)
            XCTAssertTrue(engine.verificationEligible)
        }
    }
    func testOpeningLidDuringRetriesDoesNotExtendTheHold() {
        var settings = Settings(); settings.internet = false; settings.grace = 0; settings.retries = 1
        let closed = MachineSample(lidClosed: true)
        var engine = MonitorEngine(settings: settings, sample: closed)
        _ = engine.handle(.start, now: now)
        _ = engine.handle(.tick(closed), now: now.addingTimeInterval(30))
        let retryDeadline = now.addingTimeInterval(60)
        XCTAssertEqual(engine.state.nextConditionRetryAt, retryDeadline)
        _ = engine.handle(.tick(MachineSample()), now: now.addingTimeInterval(31))
        XCTAssertEqual(engine.state.nextConditionRetryAt, retryDeadline)
        XCTAssertTrue(engine.holding)
        let effects = engine.handle(.tick(MachineSample()), now: retryDeadline)
        XCTAssertTrue(effects.contains(.releaseHold))
        XCTAssertFalse(engine.holding)
        XCTAssertEqual(engine.state.pause, .inactivity)
    }
    func testDisabledNetworkPoliciesNeverProbeJoinOrSpendOnExplicitRetry() {
        var base = Settings(); base.hotspot = true; base.hotspotSSID = "phone"; base.hotspotAfter = 0
        var policies: [Settings] = []
        var forever = base; forever.forever = true; policies.append(forever)
        var noInternet = base; noInternet.internet = false; policies.append(noInternet)
        var none = base; none.requirement = .none; policies.append(none)
        var noChecks = base; noChecks.agent = false; noChecks.internet = false; policies.append(noChecks)
        for settings in policies {
            var state = ControllerState(); state.desiredEnabled = true; state.pause = nil
            state.outage = OutageLedger(now: now, settings: settings)
            var engine = MonitorEngine(settings: settings, state: state)
            let events: [MonitorEvent] = [.bootstrap(wasUnclean: false), .normalWake, .pathChanged, .retryNow, .tryAgain, .tick(MachineSample())]
            for event in events {
                let effects = engine.handle(event, now: now.addingTimeInterval(100))
                XCTAssertFalse(effects.contains { effect in
                    switch effect { case .verifyInternet, .joinHotspot, .promptHotspot: return true; default: return false }
                })
                XCTAssertNil(engine.verificationToken); XCTAssertNil(engine.joinToken)
            }
            XCTAssertEqual(engine.state.outage?.consumed, 0)
        }
    }
    func testDisablingInternetAtLoopBoundaryCancelsProbeJoinAndLateResults() {
        var settings = Settings(); settings.hotspot = true; settings.hotspotSSID = "phone"; settings.hotspotAfter = 0
        var engine = MonitorEngine(settings: settings)
        _ = engine.handle(.start, now: now)
        _ = engine.handle(.internetResult(engine.verificationToken!, false), now: now)
        let join = engine.joinToken!
        _ = engine.handle(.tick(MachineSample()), now: now.addingTimeInterval(30))
        let probe = engine.verificationToken!
        settings.internet = false
        _ = engine.handle(.settings(settings), now: now.addingTimeInterval(31))
        let effects = engine.handle(.tick(MachineSample()), now: now.addingTimeInterval(31))
        XCTAssertTrue(effects.contains(.cancelOperations))
        XCTAssertNil(engine.joinToken); XCTAssertNil(engine.verificationToken)
        _ = engine.handle(.internetResult(probe, true), now: now.addingTimeInterval(32))
        _ = engine.handle(.hotspotResult(join, .associated), now: now.addingTimeInterval(32))
        XCTAssertEqual(engine.state.internet, .unknown)
        XCTAssertEqual(engine.state.outage?.consumed, 1)
        XCTAssertFalse(engine.verificationEligible)
    }
    func testRetainedOutageCannotHoldAgentOnlyRunPastInactivity() {
        var settings = Settings(); settings.internet = false; settings.hotspot = true; settings.hotspotSSID = "phone"; settings.grace = 0; settings.retries = 0
        var state = ControllerState(); state.desiredEnabled = true; state.pause = nil
        state.outage = OutageLedger(now: now, settings: settings)
        state.lastAgentActiveAt = now.addingTimeInterval(-100); state.agentSamples = 2
        var engine = MonitorEngine(settings: settings, state: state)
        _ = engine.handle(.tick(MachineSample(lidClosed: true)), now: now)
        XCTAssertEqual(engine.state.pause, .inactivity); XCTAssertFalse(engine.holding)
        XCTAssertEqual(engine.state.outage?.capturedLimit, 3); XCTAssertEqual(engine.state.outage?.consumed, 0)
        XCTAssertNil(engine.verificationToken); XCTAssertNil(engine.joinToken)
    }
    func testDisablingInternetPolicyClearsOnlyObsoleteConnectivityPause() {
        var policies: [Settings] = []
        var noInternet = Settings(); noInternet.internet = false; policies.append(noInternet)
        var forever = Settings(); forever.forever = true; policies.append(forever)
        var none = Settings(); none.requirement = .none; policies.append(none)
        var noChecks = Settings(); noChecks.agent = false; noChecks.internet = false; policies.append(noChecks)
        for changed in policies {
            var state = ControllerState(); state.desiredEnabled = true; state.pause = .connectivity
            var engine = MonitorEngine(state: state)
            _ = engine.handle(.settings(changed), now: now)
            _ = engine.handle(.tick(MachineSample(agentActive: true, lidClosed: true)), now: now)
            XCTAssertNil(engine.state.pause); XCTAssertTrue(engine.holding)
            XCTAssertNil(engine.verificationToken); XCTAssertNil(engine.joinToken)
        }
        // Unrelated edits do not bypass verification for the still-selected condition.
        var state = ControllerState(); state.desiredEnabled = true; state.pause = .connectivity
        var engine = MonitorEngine(state: state)
        var changed = Settings(); changed.displayOn = true
        _ = engine.handle(.settings(changed), now: now)
        _ = engine.handle(.tick(MachineSample(agentActive: true)), now: now)
        XCTAssertEqual(engine.state.pause, .connectivity); XCTAssertFalse(engine.holding)
    }
    func testPolicyChangeCannotResumeStopSafetyOrInactivityPauses() {
        let reasons: [PauseReason] = [.stopped, .battery, .inactivity, .asleep, .maintenanceWake, .setup, .ownership, .crashLimit, .loginOptOut]
        for reason in reasons {
            var settings = Settings(); settings.batteryProtection = true
            var state = ControllerState(); state.desiredEnabled = reason != .stopped; state.pause = reason
            if reason == .battery || reason == .setup { state.resumePause = .inactivity }
            var engine = MonitorEngine(settings: settings, state: state)
            settings.forever = true
            _ = engine.handle(.settings(settings), now: now)
            let sample = MachineSample(onBattery: reason == .battery, batteryPercent: reason == .battery ? 10 : 80, agentActive: true, setupReady: reason != .setup)
            let effects = engine.handle(.tick(sample), now: now)
            XCTAssertEqual(engine.state.pause, reason); XCTAssertFalse(engine.holding)
            XCTAssertFalse(effects.contains { if case .acquireHold = $0 { return true }; return false })
            if reason == .battery || reason == .setup { XCTAssertEqual(engine.state.resumePause, .inactivity) }
        }
    }
    func testPolicyChangeDropsSuspendedConnectivityCauseWithoutClearingBattery() {
        var settings = Settings(); settings.batteryProtection = true
        var state = ControllerState(); state.desiredEnabled = true; state.pause = .battery; state.resumePause = .connectivity
        var engine = MonitorEngine(settings: settings, state: state, sample: MachineSample(onBattery: true, batteryPercent: 10))
        settings.forever = true
        _ = engine.handle(.settings(settings), now: now)
        _ = engine.handle(.tick(MachineSample(onBattery: true, batteryPercent: 10)), now: now)
        XCTAssertEqual(engine.state.pause, .battery); XCTAssertNil(engine.state.resumePause); XCTAssertFalse(engine.holding)
        _ = engine.handle(.tick(MachineSample(onBattery: false, batteryPercent: 10)), now: now.addingTimeInterval(1))
        XCTAssertNil(engine.state.pause); XCTAssertTrue(engine.holding)
    }
    func testStatusJSONUsesVersionedEnvelopeForAvailableAndUnavailableStates() throws {
        let failure = ControllerResponse(error: "Nightr status unavailable: private controller socket is unavailable or unsafe")
        let failureData = try JSONEncoder().encode(failure)
        let failureJSON = try XCTUnwrap(JSONSerialization.jsonObject(with: failureData) as? [String: Any])
        XCTAssertEqual(failureJSON["version"] as? Int, 1)
        XCTAssertNil(failureJSON["status"])
        XCTAssertNotNil(failureJSON["error"] as? String)
        XCTAssertNil(failureJSON["running"]); XCTAssertNil(failureJSON["protocol_version"])
        let decoded = try JSONDecoder().decode(ControllerResponse.self, from: failureData)
        XCTAssertNil(decoded.status); XCTAssertEqual(decoded.error, failure.error)
        let off = ControllerResponse(status: ControllerStatus(engine: MonitorEngine()))
        let offJSON = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(off)) as? [String: Any])
        XCTAssertEqual(offJSON["version"] as? Int, 1)
        let status = try XCTUnwrap(offJSON["status"] as? [String: Any])
        XCTAssertEqual(status["holding"] as? Bool, false)
        XCTAssertNil(offJSON["holding"]); XCTAssertNil(offJSON["error"])
    }
    func testBundleVersionReadsBoundedRegularMetadataAndExactVersion() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("nightr-version-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let plist = directory.appendingPathComponent("Info.plist")
        for version in ["0.1.777", "0.1.999999999999999999999999999999"] {
            try PropertyListSerialization.data(fromPropertyList: ["CFBundleShortVersionString": version], format: .xml, options: 0).write(to: plist)
            XCTAssertEqual(AppBundleVersion.read(infoPlist: plist), version)
        }
        let link = directory.appendingPathComponent("linked.plist")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: plist)
        XCTAssertNil(AppBundleVersion.read(infoPlist: link))
        let invalidValues: [Any] = ["0.1", "0.1.7\n", "future", true]
        for invalid in invalidValues {
            try PropertyListSerialization.data(fromPropertyList: ["CFBundleShortVersionString": invalid], format: .binary, options: 0).write(to: plist)
            XCTAssertNil(AppBundleVersion.read(infoPlist: plist))
        }
        try Data(repeating: 32, count: AppBundleVersion.maximumInfoBytes + 1).write(to: plist)
        XCTAssertNil(AppBundleVersion.read(infoPlist: plist))
        try Data("not a plist".utf8).write(to: plist)
        XCTAssertNil(AppBundleVersion.read(infoPlist: plist))
        XCTAssertNil(AppBundleVersion.read(infoPlist: directory.appendingPathComponent("missing")))
    }
    func testFrameLimitsAndProtocolRoundTrip() throws {
        for length in [0, 65_537, UInt32.max] {
            var size = UInt32(length).bigEndian
            XCTAssertThrowsError(try FrameCodec.payloadLength(withUnsafeBytes(of: &size) { Data($0) }))
        }
        let request = ControllerRequest(command: .stop)
        let frame = try FrameCodec.encode(request)
        XCTAssertEqual(try FrameCodec.payloadLength(frame.prefix(4)), frame.count - 4)
        let decoded = try JSONDecoder().decode(ControllerRequest.self, from: frame.dropFirst(4))
        XCTAssertEqual(decoded.command, .stop); XCTAssertEqual(decoded.version, 1)
    }
    func testPrivateLifetimeLockAndUnsafePaths() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("nightr-core-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        var owner: RuntimeOwnership? = try RuntimeOwnership(directory: directory)
        XCTAssertThrowsError(try RuntimeOwnership(directory: directory))
        owner = nil
        _ = owner
        let successor = try RuntimeOwnership(directory: directory)
        withExtendedLifetime(successor) {}
        let unsafe = directory.appendingPathComponent("unsafe")
        try FileManager.default.createDirectory(at: unsafe, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o755])
        XCTAssertThrowsError(try RuntimeOwnership(directory: unsafe))
    }
    func testOptimisticConfigSavePreservesOnConflict() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("nightr-config-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SettingsStore(url: directory.appendingPathComponent("config.json"))
        try store.save(Settings(), expected: nil)
        var changed = Settings(); changed.grace = 40
        XCTAssertThrowsError(try store.save(changed, expected: nil))
        XCTAssertEqual(try store.load().grace, 900)
    }
}

private actor MockControllerPlatform: ControllerPlatform {
    var acquired = 0
    var released = 0
    func acquireProtection(settings: Settings) async throws { acquired += 1 }
    func releaseProtection() async { released += 1 }
    func verifyInternet(timeout: TimeInterval) async -> Bool { false }
    func joinHotspot(ssid: String, timeout: TimeInterval) async -> JoinResult { .failed }
    func sample() async -> MachineSample { MachineSample() }
}

final class ControllerIntegrationTests: XCTestCase {
    func testSharedSocketStopAndOfflineStopAreDurable() async throws {
        let directory = URL(fileURLWithPath: "/tmp/nc-" + UUID().uuidString.prefix(8))
        defer { try? FileManager.default.removeItem(at: directory) }
        let config = directory.appendingPathComponent("config.json")
        let runtime = directory.appendingPathComponent("run")
        let service = try ControllerService(platform: MockControllerPlatform(), settingsStore: SettingsStore(url: config), runtimeDirectory: runtime)
        try await service.start()
        let client = ControllerClient(runtimeDirectory: runtime)
        let started = try await Task.detached { try client.request(.init(command: .start)) }.value
        XCTAssertTrue(started.status?.state.desiredEnabled == true)
        let stopped = try await Task.detached { try client.request(.init(command: .stop)) }.value
        XCTAssertFalse(stopped.status!.state.desiredEnabled)
        await service.shutdown(preserveIntent: true)
        XCTAssertFalse(try StateJournal.load(directory: runtime).desiredEnabled)
        try OfflineController.stop(runtimeDirectory: runtime)
        XCTAssertEqual(try StateJournal.load(directory: runtime).pause, .stopped)
    }
    func testMalformedAndSymlinkStateFailClosed() throws {
        let directory = URL(fileURLWithPath: "/tmp/nc-" + UUID().uuidString.prefix(8))
        defer { try? FileManager.default.removeItem(at: directory) }
        let owner = try RuntimeOwnership(directory: directory)
        try withExtendedLifetime(owner) {
            let target = directory.appendingPathComponent("target")
            try Data("private".utf8).write(to: target)
            try FileManager.default.createSymbolicLink(at: directory.appendingPathComponent("state.json"), withDestinationURL: target)
            XCTAssertThrowsError(try StateJournal.load(directory: directory))
            XCTAssertEqual(try String(contentsOf: target), "private")
        }
    }
}

private actor DelayedProtection: ControllerPlatform {
    var events: [String] = []
    var gate: CheckedContinuation<Void, Never>?
    var waiting: [CheckedContinuation<Void, Never>] = []
    var shouldDelay = true
    func acquireProtection(settings: Settings) async throws {
        events.append("acquire")
        if shouldDelay {
            shouldDelay = false
            await withCheckedContinuation { continuation in
                gate = continuation
                waiting.forEach { $0.resume() }; waiting.removeAll()
            }
        }
        events.append("acquired")
    }
    func waitForAcquire() async { if gate != nil { return }; await withCheckedContinuation { waiting.append($0) } }
    func completeAcquire() { gate?.resume(); gate = nil }
    func releaseProtection() async { events.append("release") }
    func verifyInternet(timeout: TimeInterval) async -> Bool { false }
    func joinHotspot(ssid: String, timeout: TimeInterval) async -> JoinResult { .failed }
    func sample() async -> MachineSample { MachineSample() }
}
final class ProtectionInterleavingTests: XCTestCase {
    func testStopDuringAcquireReleasesAfterCompletion() async {
        let platform = DelayedProtection()
        let executor = ProtectionExecutor(platform: platform) { _, _, _ in }
        await executor.submit(Settings(), epoch: 1)
        await platform.waitForAcquire()
        await executor.submit(nil, epoch: 2)
        await platform.completeAcquire()
        await executor.flush()
        let events = await platform.events
        XCTAssertEqual(events, ["acquire", "acquired", "release"])
    }
    func testStopThenNewStartNeverRunsStaleRelease() async {
        let platform = DelayedProtection()
        let executor = ProtectionExecutor(platform: platform) { _, _, _ in }
        await executor.submit(Settings(), epoch: 1)
        await platform.waitForAcquire()
        await executor.submit(nil, epoch: 2)
        var newer = Settings(); newer.batteryBelow = 30
        await executor.submit(newer, epoch: 3)
        await platform.completeAcquire()
        await executor.flush()
        let events = await platform.events
        XCTAssertEqual(events, ["acquire", "acquired", "acquire", "acquired"])
        await executor.submit(nil, epoch: 4); await executor.flush()
    }
}
