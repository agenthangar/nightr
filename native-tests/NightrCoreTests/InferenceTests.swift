import XCTest
import Foundation
@testable import NightrCore
@testable import NightrController

final class InferenceTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1000)
    private func observation(at date: Date, activity: ModelActivity = .generating) -> ActivityObservation {
        ActivityObservation(runtimes: [.init(runtime: .mlx, observedAt: date,
            models: [.init(id: "synthetic", activity: activity, inferenceExpiresAt: date.addingTimeInterval(15))])])
    }
    func testInitialCheckingHasBoundedAllowanceWithoutActivityGraceMutation() {
        var settings = Settings(); settings.internet = false; settings.every = 1; settings.grace = 0; settings.retries = 0
        var engine = MonitorEngine(settings: settings, sample: .init(agentObservation: .checking))
        _ = engine.handle(.start, now: now)
        _ = engine.handle(.tick(.init(agentObservation: .checking)), now: now.addingTimeInterval(1))
        XCTAssertTrue(engine.holding); XCTAssertNil(engine.state.pause)
        XCTAssertEqual(engine.state.lastAgentActiveAt, now)
        _ = engine.handle(.tick(.init(agentActive: true, agentObservation: .active)), now: now.addingTimeInterval(2))
        XCTAssertTrue(engine.holding); XCTAssertNil(engine.state.pause)
        XCTAssertEqual(engine.state.lastAgentActiveAt, now.addingTimeInterval(2))
        settings.every = 3600
        var stuck = MonitorEngine(settings: settings, sample: .init(agentObservation: .checking))
        _ = stuck.handle(.start, now: now)
        for offset in [1.0, 5.0, 14.0] { _ = stuck.handle(.tick(.init(agentObservation: .checking)), now: now.addingTimeInterval(offset)); XCTAssertTrue(stuck.holding) }
        XCTAssertEqual(stuck.state.lastAgentActiveAt, now)
        _ = stuck.handle(.tick(.init(agentObservation: .checking)), now: now.addingTimeInterval(15))
        XCTAssertFalse(stuck.holding); XCTAssertEqual(stuck.state.pause, .inactivity)
        var quickActive = MonitorEngine(settings: settings, sample: .init(agentObservation: .checking))
        _ = quickActive.handle(.start, now: now)
        _ = quickActive.handle(.tick(.init(agentActive: true, agentObservation: .active)), now: now.addingTimeInterval(2))
        XCTAssertEqual(quickActive.state.lastAgentActiveAt, now.addingTimeInterval(2))
        settings.every = 1; settings.internet = true
        var both = MonitorEngine(settings: settings, sample: .init(agentObservation: .checking))
        _ = both.handle(.start, now: now)
        _ = both.handle(.tick(.init(agentObservation: .checking)), now: now.addingTimeInterval(1))
        XCTAssertFalse(both.holding); XCTAssertEqual(both.state.pause, .connectivity)
    }
    func testBackwardPayloadAndSettingsDefaults() throws {
        let sample = try JSONDecoder().decode(MachineSample.self, from: Data(#"{"onBattery":false,"agentActive":false,"lidClosed":false,"setupReady":true}"#.utf8))
        XCTAssertNil(sample.agentObservation); XCTAssertNil(sample.activity)
        XCTAssertFalse(try JSONDecoder().decode(Settings.self, from: Data("{}".utf8)).localInference)
        var settings = Settings(); settings.localInference = true
        XCTAssertEqual(try JSONDecoder().decode(Settings.self, from: JSONEncoder().encode(settings)), settings)
        XCTAssertTrue(try CLIOptions.applying(["--local-inference", "on"], to: Settings()).localInference)
    }
    func testInferenceRecoversConnectivityWithoutRefreshingAgentGraceAndExpiresAtTick() {
        var settings = Settings(); settings.localInference = true; settings.every = 300; settings.grace = 0; settings.retries = 0
        var engine = MonitorEngine(settings: settings)
        _ = engine.handle(.start, now: now)
        _ = engine.handle(.tick(.init()), now: now.addingTimeInterval(301))
        XCTAssertEqual(engine.state.pause, .connectivity); XCTAssertFalse(engine.holding)
        let agentGrace = engine.state.lastAgentActiveAt
        let processingAt = now.addingTimeInterval(302)
        _ = engine.handle(.tick(.init(activity: observation(at: processingAt))), now: processingAt)
        XCTAssertTrue(engine.holding); XCTAssertNil(engine.state.pause)
        XCTAssertEqual(engine.state.lastAgentActiveAt, agentGrace)
        _ = engine.handle(.tick(.init(activity: observation(at: processingAt))), now: processingAt.addingTimeInterval(15))
        XCTAssertFalse(engine.holding); XCTAssertEqual(engine.state.pause, .connectivity)
        XCTAssertEqual(engine.state.lastAgentActiveAt, agentGrace)
    }
    func testPreviouslyExhaustedOfflineRetriesRemainExhaustedAfterInference() {
        var settings = Settings(); settings.localInference = true; settings.every = 1; settings.grace = 0; settings.retries = 2; settings.backoff = 1
        var engine = MonitorEngine(settings: settings)
        _ = engine.handle(.start, now: now)
        for offset in [1.0, 2.0, 4.0] { _ = engine.handle(.tick(.init()), now: now.addingTimeInterval(offset)) }
        XCTAssertEqual(engine.state.pause, .connectivity); XCTAssertEqual(engine.state.conditionRetries, 2)
        let processingAt = now.addingTimeInterval(5)
        _ = engine.handle(.tick(.init(activity: observation(at: processingAt))), now: processingAt)
        XCTAssertTrue(engine.holding); XCTAssertEqual(engine.state.conditionRetries, 2)
        _ = engine.handle(.tick(.init()), now: processingAt.addingTimeInterval(1))
        XCTAssertFalse(engine.holding); XCTAssertEqual(engine.state.pause, .connectivity)
        settings.forever = true
        var forever = MonitorEngine(settings: settings)
        _ = forever.handle(.start, now: now)
        XCTAssertTrue(forever.holding); XCTAssertFalse(forever.inferenceEligible)
    }
    func testInactivityLatchAndSafetyAlwaysWin() {
        var settings = Settings(); settings.localInference = true; settings.internet = false; settings.grace = 0; settings.retries = 0; settings.every = 1; settings.batteryProtection = true
        var idle = MonitorEngine(settings: settings)
        _ = idle.handle(.start, now: now)
        _ = idle.handle(.tick(.init()), now: now.addingTimeInterval(1))
        XCTAssertEqual(idle.state.pause, .inactivity)
        _ = idle.handle(.tick(.init(activity: observation(at: now.addingTimeInterval(2)))), now: now.addingTimeInterval(2))
        XCTAssertFalse(idle.holding)
        for event in [MonitorEvent.stop, .sleep, .maintenanceWake, .ownershipLost] {
            var engine = MonitorEngine(settings: settings, sample: .init(activity: observation(at: now)))
            _ = engine.handle(.start, now: now); XCTAssertTrue(engine.holding)
            _ = engine.handle(event, now: now)
            _ = engine.handle(.tick(.init(activity: observation(at: now))), now: now)
            XCTAssertFalse(engine.holding)
        }
        var engine = MonitorEngine(settings: settings, sample: .init(activity: observation(at: now)))
        _ = engine.handle(.start, now: now)
        _ = engine.handle(.tick(.init(onBattery: true, batteryPercent: 1, activity: observation(at: now))), now: now)
        XCTAssertFalse(engine.holding); XCTAssertEqual(engine.state.pause, .battery)
    }
    func testLoadedAndUnknownNeverProtectAndOptOutIgnoresInference() {
        var settings = Settings(); settings.grace = 0; settings.retries = 0; settings.every = 1
        for activity in [ModelActivity.idle, .unknown] {
            settings.localInference = true
            var engine = MonitorEngine(settings: settings)
            _ = engine.handle(.start, now: now)
            _ = engine.handle(.tick(.init(activity: observation(at: now.addingTimeInterval(1), activity: activity))), now: now.addingTimeInterval(1))
            XCTAssertFalse(engine.holding)
        }
        settings.localInference = false
        var engine = MonitorEngine(settings: settings)
        _ = engine.handle(.start, now: now)
        _ = engine.handle(.tick(.init(activity: observation(at: now.addingTimeInterval(1)))), now: now.addingTimeInterval(1))
        XCTAssertFalse(engine.holding)
    }
    func testMonotonicLeaseExpiryCallerBindingBoundsAndPrivacy() throws {
        let peer = ControllerPeer(uid: 501, pid: 123)
        let other = ControllerPeer(uid: 501, pid: 124)
        let metadata = InferenceMetadata(runtime: .ollama, model: "synthetic")
        var leases = InferenceLeases()
        let token = try leases.begin(metadata, peer: peer, uptime: 10)
        XCTAssertThrowsError(try leases.heartbeat(token, peer: other, uptime: 11))
        XCTAssertThrowsError(try leases.end(token, peer: other, uptime: 11))
        try leases.heartbeat(token, peer: peer, uptime: 20)
        let running = leases.adding(to: nil, now: now, uptime: 34)!
        XCTAssertTrue(running.hasActiveInference(at: now))
        XCTAssertEqual(running.runtimes.first?.models.first?.startedAt, now.addingTimeInterval(-24))
        XCTAssertNil(leases.adding(to: nil, now: now.addingTimeInterval(-3600), uptime: 35))
        XCTAssertThrowsError(try leases.heartbeat(token, peer: peer, uptime: 35))
        for _ in 0..<InferenceLeases.maximum { _ = try leases.begin(metadata, peer: peer, uptime: 40) }
        XCTAssertThrowsError(try leases.begin(metadata, peer: peer, uptime: 40))
        let activeToken = leases.leases.keys.first!
        let publicObservation = leases.adding(to: nil, now: now, uptime: 40)!
        XCTAssertFalse(String(decoding: try JSONEncoder().encode(publicObservation), as: UTF8.self).contains(activeToken.uuidString))
        leases.clear(); XCTAssertTrue(leases.leases.isEmpty)
        for invalid in ["bad\nname", "/Users/synthetic/model", "~/model", "../model", "./model", "org//model", "org/../model", "org/model/", "https://example.invalid/model", "file:local-model", "C:\\models\\sample"] {
            XCTAssertThrowsError(try InferenceMetadata(runtime: .mlx, model: invalid).validate())
        }
        try InferenceMetadata(runtime: .mlx, model: "mlx-community/sample-8b").validate()
        try InferenceMetadata(runtime: .ollama, model: "qwen2.5-coder:14b").validate()
        XCTAssertThrowsError(try InferenceMetadata(runtime: .mlx, model: "ok", activity: .idle).validate())
        let json = String(decoding: try JSONEncoder().encode(metadata), as: UTF8.self)
        XCTAssertFalse(json.contains("expiry")); XCTAssertFalse(json.contains("path")); XCTAssertFalse(json.contains("prompt"))
    }
    func testRedirectedSnapshotsIgnoreCosmeticMetrics() {
        var first = MonitorEngine(sample: .init(agentObservation: .checking, activity: .init(cpuPercent: 10, gpuPercent: 20)))
        _ = first.handle(.start, now: now)
        var second = MonitorEngine(sample: .init(agentObservation: .checking, activity: .init(cpuPercent: 99, gpuPercent: 80)))
        _ = second.handle(.start, now: now)
        let a = ControllerResponse(status: .init(engine: first)), b = ControllerResponse(status: .init(engine: second))
        XCTAssertEqual(ForegroundStatus.snapshot(a, includeMetrics: false), ForegroundStatus.snapshot(b, includeMetrics: false))
        XCTAssertTrue(ForegroundStatus.snapshot(a).contains("CPU: 10% | GPU: 20%"))
        XCTAssertTrue(ForegroundStatus.snapshot(a).contains("Agent: checking"))
        XCTAssertFalse(ForegroundStatus.snapshot(a).contains("·"))
    }
    func testLeaseOverlayDoesNotFreshenStaleInventory() throws {
        var leases = InferenceLeases()
        _ = try leases.begin(.init(runtime: .mlx, model: "new"), peer: .init(uid: 1, pid: 2), uptime: 10)
        let stale = observation(at: now.addingTimeInterval(-30))
        let merged = leases.adding(to: stale, now: now, uptime: 10)!
        XCTAssertEqual(merged.runtimes.first?.observedAt, stale.runtimes.first?.observedAt)
        XCTAssertTrue(merged.hasActiveInference(at: now))
        leases.clear()
        XCTAssertFalse(leases.adding(to: stale, now: now, uptime: 10)!.hasActiveInference(at: now))
    }
}
