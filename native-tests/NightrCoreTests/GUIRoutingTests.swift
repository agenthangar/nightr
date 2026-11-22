import XCTest
import Foundation
@testable import NightrCore
@testable import NightrController

final class GUIRoutingTests: XCTestCase {
    func testOnlyTwoFixedPresentationRequestsAreAccepted() {
        for route in GUISettingsRoute.allCases {
            let request = GUISettingsRequest(route: route)
            XCTAssertEqual(GUISettingsRequest(userInfo: request.userInfo), request)
        }
        let id = "AAAAAAAA-BBBB-4CCC-8DDD-EEEEEEEEEEEE"
        let invalid: [[AnyHashable: Any]] = [[:], ["requestID": id], ["requestID": "bad", "section": "general"],
            ["requestID": id.lowercased(), "section": "general"], ["requestID": id, "section": "General"],
            ["requestID": id, "section": "start"], ["requestID": id, "section": "connectivity", "start": true],
            ["requestID": id, "section": "general?start=true"], ["requestID": 42, "section": "general"]]
        for payload in invalid {
            XCTAssertNil(GUISettingsRequest(userInfo: payload))
        }
        XCTAssertTrue(GUISettingsRequest.acceptsReceiver(bundleID: "ai.nightr.app", bundlePath: "/Applications/Nightr.app"))
        XCTAssertFalse(GUISettingsRequest.acceptsReceiver(bundleID: "ai.nightr.app", bundlePath: "/tmp/Nightr.app"))
        XCTAssertFalse(GUISettingsRequest.acceptsReceiver(bundleID: "other.app", bundlePath: "/Applications/Nightr.app"))
    }
    func testColdSettingsLaunchIsPresentationOnlyAndWarmDeliveryKeepsState() {
        XCTAssertEqual(GUIStartupMode(arguments: GUIStartupMode.settingsArguments), .presentation)
        XCTAssertEqual(GUIStartupMode(arguments: []), .controller)
        XCTAssertEqual(GUIStartupMode(arguments: ["--controller-only"]), .controller)
        var presentation = GUIPresentationState(headless: true)
        var draft = Settings(); draft.every = 47; draft.hotspotSSID = "Unsaved exact SSID"
        let original = draft
        let desiredEnabled = false
        presentation.receive(.connectivity)
        presentation.section = .advanced
        presentation.receive(.general)
        XCTAssertEqual(draft, original)
        XCTAssertFalse(desiredEnabled)
        XCTAssertEqual(presentation.section, .general)
    }
    func testDesktopAndHeadlessOwnerLaunchMatrix() {
        for arguments in [[String]()] {
            let launch = GUILaunchConfiguration(arguments: arguments)
            XCTAssertEqual(launch.startup, .controller)
            XCTAssertFalse(launch.headless)
            XCTAssertFalse(launch.exitsAfterConnectingToExistingOwner)
            XCTAssertTrue(GUIPresentationState(headless: launch.headless).menuVisible)
        }
        let owner = GUILaunchConfiguration(arguments: ["--controller-only"])
        XCTAssertEqual(owner.startup, .controller)
        XCTAssertTrue(owner.headless)
        XCTAssertTrue(owner.exitsAfterConnectingToExistingOwner)
        for flag in ["--settings-only", "--setup-desktop", "--setup-helper-only", "--hotspot-setup", "--enable-discovery"] {
            let settings = GUILaunchConfiguration(arguments: [flag])
            XCTAssertEqual(settings.startup, .presentation)
            XCTAssertFalse(settings.headless)
            XCTAssertFalse(settings.exitsAfterConnectingToExistingOwner)
        }
    }
    func testDesktopInstallLaunchUsesVisibleControllerOnly() {
        let desktop = GUILaunchConfiguration(arguments: ["--after-install"])
        XCTAssertEqual(desktop.startup, .controller)
        XCTAssertFalse(desktop.headless)
        XCTAssertTrue(desktop.afterDesktopInstall)
        for arguments in [[], ["--controller-only", "--after-install"], ["--settings-only", "--after-install"]] {
            XCTAssertFalse(GUILaunchConfiguration(arguments: arguments).afterDesktopInstall)
        }
    }
    func testObservedProtectionStatesHaveDistinctTextAndGlyphs() {
        var labels: Set<String> = [], symbols: Set<String> = []
        for (enabled, holding, internet, pause): (Bool, Bool, InternetState, PauseReason?) in [
            (false, false, .unknown, .stopped), (true, true, .verified, nil),
            (true, false, .unavailable, .connectivity), (true, false, .checking, .connectivity),
            (true, false, .unknown, .setup)] {
            var state = ControllerState(); state.desiredEnabled = enabled; state.internet = internet; state.pause = pause
            let summary = GUIProtectionSummary(status: ControllerStatus(engine: MonitorEngine(state: state), holding: holding))
            XCTAssertEqual(summary.activelyProtecting, holding)
            labels.insert(summary.label); symbols.insert(summary.symbol)
        }
        XCTAssertEqual(labels, ["Off", "On", "Paused", "Recovering", "Error"])
        XCTAssertEqual(symbols.count, 5)
        XCTAssertEqual(GUIProtectionSummary(status: nil).label, "Checking…")
        XCTAssertEqual(GUIProtectionSummary(status: nil, error: "Connection failed").label, "Error")
    }
    func testCommittedSettingsBytesRemainAnExactConflictBaseline() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("nightr-save-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SettingsStore(url: directory.appendingPathComponent("config.json"))
        var saved = Settings(); saved.launchAtLogin = false
        let committed = try store.save(saved, expected: nil)
        XCTAssertEqual(try Data(contentsOf: store.url), committed)
        var external = saved; external.every = 47
        _ = try store.save(external, expected: committed)
        XCTAssertThrowsError(try store.save(saved, expected: committed))
        XCTAssertEqual(try store.load(), external)
    }
    func testLostAcknowledgementHasFixedRetryAndDeadlineBudget() {
        let request = GUISettingsRequest(route: .connectivity)
        var delivery = GUISettingsDelivery(request: request, now: 10)
        var posts = 0
        for step in 0..<300 {
            if delivery.next(now: 10 + Double(step) / 100) == .post { posts += 1 }
        }
        XCTAssertEqual(posts, 6)
        XCTAssertEqual(delivery.next(now: 13), .expired)
        XCTAssertEqual(delivery.next(now: 100), .expired)
    }
    func testAcknowledgementMustMatchUUIDAndSectionAndStopsRetries() {
        let request = GUISettingsRequest(route: .general)
        var delivery = GUISettingsDelivery(request: request, now: 0)
        XCTAssertEqual(delivery.next(now: 0), .post)
        delivery.acknowledge(GUISettingsRequest(route: .general))
        delivery.acknowledge(GUISettingsRequest(id: request.id, route: .connectivity))
        XCTAssertEqual(delivery.next(now: 0.1), .wait)
        delivery.acknowledge(request)
        XCTAssertEqual(delivery.next(now: 0.2), .acknowledged)
        XCTAssertEqual(delivery.next(now: 4), .acknowledged)
    }
    func testSettingsRoutePromotesHeadlessPresentationAndEveryRequestSelectsItsSection() {
        var state = GUIPresentationState(headless: true)
        XCTAssertFalse(state.menuVisible)
        state.receive(.connectivity)
        XCTAssertTrue(state.menuVisible); XCTAssertEqual(state.section, .connectivity)
        state.section = .protection
        state.receive(.connectivity)
        XCTAssertEqual(state.section, .connectivity)
        state.section = .advanced
        state.receive(.general)
        XCTAssertEqual(state.section, .general)
    }
    func testReopenOnlyPromotesPresentationAndKeepsSelectedSection() {
        var state = GUIPresentationState(headless: true); state.section = .advanced
        state.reopen()
        XCTAssertTrue(state.menuVisible); XCTAssertEqual(state.section, .advanced)
    }
    func testLaterStopQuitOrNewStartInvalidatesPendingStart() {
        let intent = GUIStartIntent()
        let first = intent.begin(); XCTAssertTrue(intent.isCurrent(first))
        intent.cancel(); XCTAssertFalse(intent.isCurrent(first))
        let second = intent.begin(); XCTAssertTrue(intent.isCurrent(second))
        let third = intent.begin(); XCTAssertFalse(intent.isCurrent(second)); XCTAssertTrue(intent.isCurrent(third))
        intent.cancel(); XCTAssertFalse(intent.isCurrent(third))
    }
    func testEarlySettingsEventsWaitForReadinessAndCoalesceToLatestSection() {
        var queue = GUIEventQueue()
        queue.receive(.general); queue.reopen(); queue.receive(.connectivity)
        XCTAssertEqual(queue.drain(ready: false), [])
        XCTAssertEqual(queue.drain(ready: true), [.settings(.connectivity)])
        XCTAssertEqual(queue.drain(ready: true), [])
        queue.reopen()
        XCTAssertEqual(queue.drain(ready: true), [.reopen])
    }

    func testCancelledQueuedStartDoesNotReachTransport() async throws {
        let record = GUICommandRecord()
        let commands = GUIControllerCommands { request in record.append(request.command); return ControllerResponse() }
        let intent = GUIStartIntent(), token = intent.begin()
        intent.cancel()
        let stale = try await commands.request(.init(command: .start), intent: intent, token: token)
        XCTAssertNil(stale)
        _ = try await commands.request(.init(command: .stop))
        XCTAssertEqual(record.commands, [.stop])
    }
    func testApplicationRejectionRemainsAResponse() async throws {
        let record = GUICommandRecord()
        let commands = GUIControllerCommands { request in record.append(request.command); return ControllerResponse(error: "setup is required") }
        let response = try await commands.request(.init(command: .start))
        XCTAssertEqual(response?.error, "setup is required")
        XCTAssertEqual(record.commands, [.start])
    }
    func testStopCannotBeOvertakenByAnInFlightStart() async throws {
        let record = GUICommandRecord(), release = DispatchSemaphore(value: 0)
        let started = expectation(description: "Start entered transport")
        let stopQueued = expectation(description: "Stop queued")
        let commands = GUIControllerCommands { request in
            record.append(request.command)
            if request.command == .start {
                started.fulfill()
                _ = release.wait(timeout: .now() + 3)
            }
            return ControllerResponse()
        }
        let intent = GUIStartIntent(), token = intent.begin()
        let first = Task { try await commands.request(.init(command: .start), intent: intent, token: token) }
        await fulfillment(of: [started], timeout: 2)
        intent.cancel()
        let stop = Task { stopQueued.fulfill(); return try await commands.request(.init(command: .stop)) }
        await fulfillment(of: [stopQueued], timeout: 2)
        XCTAssertEqual(record.commands, [.start])
        release.signal()
        _ = try await first.value; _ = try await stop.value
        XCTAssertEqual(record.commands, [.start, .stop])
    }
    func testMissingAndUnsafeControllerEndpointsHaveDifferentErrorTypes() throws {
        let directory = URL(fileURLWithPath: "/tmp/nightr-routing-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let client = ControllerClient(runtimeDirectory: directory)
        XCTAssertThrowsError(try client.request(.init(command: .status))) { XCTAssertTrue($0 is ControllerUnavailableError) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        XCTAssertThrowsError(try client.request(.init(command: .status))) { XCTAssertTrue($0 is ControllerUnavailableError) }
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory.path)
        XCTAssertThrowsError(try client.request(.init(command: .status))) { XCTAssertFalse($0 is ControllerUnavailableError) }
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        let fakeSocket = directory.appendingPathComponent("controller.sock")
        try Data().write(to: fakeSocket)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fakeSocket.path)
        XCTAssertThrowsError(try client.request(.init(command: .status))) { XCTAssertFalse($0 is ControllerUnavailableError) }
    }

}

private final class GUICommandRecord: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [ControllerCommand] = []
    func append(_ command: ControllerCommand) { lock.lock(); values.append(command); lock.unlock() }
    var commands: [ControllerCommand] { lock.lock(); defer { lock.unlock() }; return values }
}
