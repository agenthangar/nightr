import XCTest
import NightrCore
import NightrController
import NightrMCP
import NightrMCPController

private final class ControllerFixture: @unchecked Sendable {
    let lock = NSLock()
    var settings = Settings()
    var savedSettings: Settings?
    var state = ControllerState()
    var sample = MachineSample()
    var unavailable = false
    var unsafe = false
    var invalidSettings = false
    var uncertainStart = false
    var launchFails = false
    var stopFails = false
    var commands: [ControllerCommand] = []
    var launches = 0
    var stops = 0
    var settingsReads = 0
    var setupReads = 0
    func operations() -> MCPControllerOperations {
        MCPControllerOperations(request: { [self] request in
            lock.lock(); defer { lock.unlock() }; commands.append(request.command)
            if unsafe { throw IPCError.invalid("private /Users/example/unsafe token=SECRET") }
            if unavailable { throw ControllerUnavailableError(message: "absent") }
            if request.command == .start {
                if uncertainStart { throw ControllerStartUncertainError(message: "private SECRET") }
                if state.desiredEnabled && request.settings != settings { return .init(error: "conflicting settings SECRET") }
                settings = request.settings ?? settings; state.desiredEnabled = true; state.pause = nil
            }
            return .init(status: ControllerStatus(engine: MonitorEngine(settings: settings, state: state, sample: sample)))
        }, settings: { [self] in
            lock.lock(); defer { lock.unlock() }; settingsReads += 1
            if invalidSettings { throw SettingsError.invalid("SECRET config") }; return savedSettings ?? settings
        }, stop: { [self] in try self.stop() }, launchController: { [self] in try self.launch() }, setupStatus: { [self] in self.setup() })
    }
    private func stop() throws -> ControllerStatus? {
        lock.lock(); defer { lock.unlock() }; stops += 1
        if stopFails { throw IPCError.invalid("SECRET") }
        state.desiredEnabled = false; state.pause = .stopped
        return unavailable ? nil : ControllerStatus(engine: MonitorEngine(settings: settings, state: state, sample: sample))
    }
    private func launch() throws {
        lock.lock(); defer { lock.unlock() }; launches += 1
        if launchFails { throw IPCError.invalid("SECRET") }; unavailable = false
    }
    private func setup() -> MCPToolResult {
        lock.lock(); defer { lock.unlock() }; setupReads += 1
        return .init("Synthetic readiness", data: ["helperReadiness": .string("unknown")])
    }
}
final class ControllerBackendTests: XCTestCase {
    func testReadOnlyNeverLaunchesOrStopsOrMutatesAndUnavailableIsUnknown() async {
        let fixture = ControllerFixture(); fixture.unavailable = true
        let backend = MCPControllerBackend(operations: fixture.operations())
        let status = await backend.execute(.status)
        XCTAssertEqual(status.data["desiredEnabled"], .null)
        XCTAssertEqual(status.data["holding"], .null)
        _ = await backend.execute(.config); _ = await backend.execute(.setupStatus)
        XCTAssertEqual(fixture.launches, 0); XCTAssertEqual(fixture.stops, 0)
        XCTAssertEqual(fixture.commands, [.status, .status])
        XCTAssertEqual(fixture.settingsReads, 1); XCTAssertEqual(fixture.setupReads, 1)
    }
    func testStartDispatchesOnceAndUncertainResultIsNeverReplayed() async {
        let fixture = ControllerFixture(); fixture.uncertainStart = true
        let backend = MCPControllerBackend(operations: fixture.operations())
        let result = await backend.execute(.start)
        XCTAssertTrue(result.isError)
        XCTAssertEqual(result.data["code"], .string("mutation_outcome_unknown"))
        XCTAssertEqual(fixture.commands, [.status, .start]); XCTAssertEqual(fixture.launches, 0)
        XCTAssertFalse(result.summary.contains("SECRET"))
    }
    func testStartBootstrapsOnlyAbsenceAndReportsBootstrapUncertainty() async {
        let fixture = ControllerFixture(); fixture.unavailable = true; fixture.launchFails = true
        let backend = MCPControllerBackend(operations: fixture.operations())
        let result = await backend.execute(.start)
        XCTAssertEqual(result.data["code"], .string("mutation_outcome_unknown"))
        XCTAssertEqual(fixture.launches, 1); XCTAssertEqual(fixture.commands, [.status])
        fixture.unavailable = false; fixture.unsafe = true
        let unsafeResult = await backend.execute(.start)
        XCTAssertTrue(unsafeResult.isError); XCTAssertEqual(fixture.launches, 1)
        XCTAssertFalse(unsafeResult.summary.contains("SECRET"))
    }
    func testExplicitStartCanBootstrapAndTwoClientsShareOneState() async {
        let fixture = ControllerFixture(); fixture.unavailable = true
        let first = MCPControllerBackend(operations: fixture.operations()), second = MCPControllerBackend(operations: fixture.operations())
        let started = await first.execute(.start)
        XCTAssertEqual(started.data["desiredEnabled"], .bool(true)); XCTAssertEqual(fixture.launches, 1)
        let observed = await second.execute(.status)
        XCTAssertEqual(observed.data["desiredEnabled"], .bool(true))
        _ = await second.execute(.stop)
        let stopped = await first.execute(.status)
        XCTAssertEqual(stopped.data["desiredEnabled"], .bool(false))
        XCTAssertEqual(fixture.launches, 1); XCTAssertEqual(fixture.stops, 1)
    }
    func testStartPreservesConflictingActivePolicy() async {
        let fixture = ControllerFixture(); fixture.settings.forever = true
        fixture.savedSettings = Settings(); fixture.state.desiredEnabled = true
        let backend = MCPControllerBackend(operations: fixture.operations())
        let result = await backend.execute(.start)
        XCTAssertTrue(result.isError); XCTAssertEqual(result.data["code"], .string("start_rejected"))
        XCTAssertTrue(fixture.settings.forever); XCTAssertTrue(fixture.state.desiredEnabled)
        XCTAssertEqual(fixture.launches, 0); XCTAssertEqual(fixture.stops, 0)
        XCTAssertEqual(fixture.commands, [.status, .start])
    }
    func testStopBypassesInvalidSettingsAndUsesDurableOfflineRoute() async {
        let fixture = ControllerFixture(); fixture.unavailable = true; fixture.invalidSettings = true; fixture.state.desiredEnabled = true
        let backend = MCPControllerBackend(operations: fixture.operations())
        let result = await backend.execute(.stop)
        XCTAssertFalse(result.isError); XCTAssertEqual(result.data["durableStopConfirmed"], .bool(true))
        XCTAssertEqual(result.data["desiredEnabled"], .bool(false))
        XCTAssertEqual(fixture.settingsReads, 0); XCTAssertEqual(fixture.stops, 1); XCTAssertEqual(fixture.launches, 0)
        fixture.stopFails = true
        let failure = await backend.execute(.stop)
        XCTAssertTrue(failure.isError); XCTAssertEqual(failure.data["code"], .string("stop_not_confirmed"))
    }
    func testProjectionSeparatesIntentObservedAndCapturedBudgetAndOmitsSecrets() async throws {
        let fixture = ControllerFixture(); fixture.settings.hotspot = true; fixture.settings.hotspotSSID = "SECRET-SSID"
        fixture.settings.hotspotAttempts = 9; fixture.state.desiredEnabled = true; fixture.state.pause = .battery
        fixture.state.internet = .stale; fixture.sample = .init(onBattery: true, batteryPercent: 5)
        var old = Settings(); old.hotspotAttempts = 3
        fixture.state.outage = OutageLedger(now: Date(), settings: old); fixture.state.outage?.consumed = 2
        let backend = MCPControllerBackend(operations: fixture.operations())
        let result = await backend.execute(.status)
        XCTAssertEqual(result.data["desiredEnabled"], .bool(true)); XCTAssertEqual(result.data["holding"], .bool(false))
        XCTAssertEqual(result.data["pauseReason"], .string("battery")); XCTAssertEqual(result.data["internet"], .string("stale"))
        XCTAssertEqual(result.data["hotspotCycle"]?.object?["capturedAttemptLimit"], .integer(3))
        XCTAssertEqual(result.data["activePolicy"]?.object?["nextCycleAttemptLimit"], .integer(9))
        XCTAssertFalse(String(decoding: try JSON.object(result.data).encoded(), as: UTF8.self).contains("SECRET"))
    }
    func testHotspotGuardsUseRunningCapturedBudget() async {
        let fixture = ControllerFixture(); fixture.settings.hotspot = true; fixture.settings.hotspotSSID = "sample"
        fixture.state.desiredEnabled = true; fixture.state.pause = nil
        fixture.state.outage = OutageLedger(now: Date(), settings: fixture.settings)
        let backend = MCPControllerBackend(operations: fixture.operations())
        let retry = await backend.execute(.retryNow); XCTAssertFalse(retry.isError)
        XCTAssertEqual(fixture.commands.last, .retryNow)
        let premature = await backend.execute(.tryAgain); XCTAssertTrue(premature.isError)
        fixture.state.outage?.consumed = 3
        let exhausted = await backend.execute(.retryNow); XCTAssertTrue(exhausted.isError)
        let again = await backend.execute(.tryAgain); XCTAssertFalse(again.isError)
        XCTAssertEqual(fixture.commands.last, .tryAgain)
        fixture.state.pause = .asleep
        let asleep = await backend.execute(.retryNow); XCTAssertTrue(asleep.isError)
        fixture.state.pause = nil; fixture.settings.batteryProtection = true
        fixture.sample = .init(onBattery: true, batteryPercent: 1)
        let battery = await backend.execute(.tryAgain); XCTAssertTrue(battery.isError)
        fixture.sample = .init(setupReady: false)
        let setup = await backend.execute(.tryAgain); XCTAssertTrue(setup.isError)
        let skip = await backend.execute(.skip); XCTAssertFalse(skip.isError)
        XCTAssertEqual(fixture.commands.last, .skipFallback)
    }
}
