import XCTest
@testable import NightrPowerProtocol
import NightrPowerClient
final class Backend: PowerBackend {
    var value = 0; var safe = true; var receivedThresholds: [Int] = []; var failRead = false; var failBattery = false; var failWrite = false; var writes: [Bool] = []
    func readDisabledSleep() throws -> Int { if failRead { throw PowerError.externalChange }; return value }
    func setDisabledSleep(_ disabled: Bool) throws { writes.append(disabled); if failWrite { throw PowerError.restoreFailed }; value = disabled ? 1 : 0 }
    func batteryIsSafe(threshold: Int) throws -> Bool { receivedThresholds.append(threshold); if failBattery { throw PowerError.unsafeBattery }; return safe }
}
final class Journal: JournalStore {
    var record: PowerJournal?; var failSave = false; var failActive = false
    func load() throws -> PowerJournal? { record }
    func save(_ journal: PowerJournal) throws { if failSave || (failActive && journal.phase == "active") { throw PowerError.invalidJournal }; record = journal }
    func clear() throws { record = nil }
}
final class LeaseEngineTests: XCTestCase {
    func testSigningFailsClosedWithoutProductionTeamAndPinsIdentifiers() throws {
        for team in ["", "unsigned", "TEAM; true", "A\" or true"] {
            XCTAssertThrowsError(try SigningPolicy.requirement(teamID: team, identifiers: ["ai.nightr.app"]))
        }
        XCTAssertThrowsError(try SigningPolicy.requirement(teamID: "ABCDE12345", identifiers: ["app\" or true"]))
        let requirement = try SigningPolicy.requirement(teamID: "ABCDE12345", identifiers: ["ai.nightr.app", "ai.nightr.controller"])
        XCTAssertTrue(requirement.contains("anchor apple generic")); XCTAssertTrue(requirement.contains("ABCDE12345"))
        XCTAssertTrue(requirement.contains("ai.nightr.controller"))
    }
    func testActiveJournalFailureRestoresAndUnsafeLivePolicyReleases() throws {
        let b = Backend(), j = Journal(); j.failActive = true
        let e = PowerLeaseEngine(backend: b, journal: j, now: {0})
        XCTAssertThrowsError(try e.acquire(uid: 1, connection: UUID(), batteryThreshold: 20))
        XCTAssertEqual(b.value, 0); XCTAssertNil(j.record)
        j.failActive = false
        let token = try e.acquire(uid: 1, connection: UUID(), batteryThreshold: 0)
        try e.renew(token, batteryThreshold: 30)
        XCTAssertEqual(b.receivedThresholds.last, 30)
        b.safe = false
        XCTAssertThrowsError(try e.renew(token, batteryThreshold: 80))
        XCTAssertEqual(b.value, 0); XCTAssertNil(e.activeLease)
    }
    func testInvalidJournalAndDisconnect() throws {
        let b = Backend(), j = Journal(); j.record = PowerJournal(generation: UUID(), original: 1)
        let e = PowerLeaseEngine(backend: b, journal: j, now: {0})
        XCTAssertThrowsError(try e.recover()); XCTAssertTrue(e.restorationBlocked)
        j.record = nil; try e.recover()
        let connection = UUID()
        _ = try e.acquire(uid: 1, connection: connection, batteryThreshold: 20)
        try e.disconnected(UUID()); XCTAssertEqual(b.value, 1)
        try e.disconnected(connection); XCTAssertEqual(b.value, 0)
    }
    func testOneGlobalOwnerAndAuthenticatedIdentity() throws {
        let b = Backend(), j = Journal(); let e = PowerLeaseEngine(backend: b, journal: j, now: {0})
        let t = try e.acquire(uid: 501, connection: UUID(), batteryThreshold: 20)
        XCTAssertThrowsError(try e.acquire(uid: 502, connection: UUID(), batteryThreshold: 20))
        XCTAssertThrowsError(try e.release(LeaseIdentity(uid: 502, connection: t.connection, generation: t.generation)))
        XCTAssertThrowsError(try e.renew(LeaseIdentity(uid: t.uid, connection: t.connection)))
        try e.release(t); XCTAssertEqual(b.value, 0); XCTAssertNil(j.record)
    }
    func testExpiryIncludesSuspendAndNoRenewAfterExpiry() throws {
        let b = Backend(), j = Journal(); var time = 0.0; let e = PowerLeaseEngine(backend: b, journal: j, now: {time})
        let t = try e.acquire(uid: 1, connection: UUID(), batteryThreshold: 20)
        time = 300; XCTAssertThrowsError(try e.renew(t)); XCTAssertEqual(b.value, 0)
    }
    func testJournalBeforeMutationAndRecoveryAtEveryCrashPhase() throws {
        for phase in ["pending", "active"] { for current in [0, 1] {
            let b = Backend(), j = Journal(); b.value = current; j.record = PowerJournal(generation: UUID(), phase: phase)
            let e = PowerLeaseEngine(backend: b, journal: j, now: {0}); try e.recover()
            XCTAssertEqual(b.value, 0); XCTAssertNil(j.record)
        }}
        let b = Backend(), j = Journal(); j.failSave = true
        let e = PowerLeaseEngine(backend: b, journal: j, now: {0})
        XCTAssertThrowsError(try e.acquire(uid: 1, connection: UUID(), batteryThreshold: 20)); XCTAssertTrue(b.writes.isEmpty)
    }
    func testExternalResetNeverRearmsAndPreexistingHoldIsRejected() throws {
        let b = Backend(), j = Journal(); let e = PowerLeaseEngine(backend: b, journal: j, now: {0})
        b.value = 1; XCTAssertThrowsError(try e.acquire(uid: 1, connection: UUID(), batteryThreshold: 20)); XCTAssertTrue(b.writes.isEmpty)
        b.value = 0; _ = try e.acquire(uid: 1, connection: UUID(), batteryThreshold: 20)
        b.value = 0; XCTAssertThrowsError(try e.tick()); XCTAssertNil(e.activeLease); XCTAssertEqual(b.writes, [true])
    }
    func testBatteryAndRestoreFailureBlockFutureAcquisition() throws {
        let b = Backend(), j = Journal(); let e = PowerLeaseEngine(backend: b, journal: j, now: {0})
        _ = try e.acquire(uid: 1, connection: UUID(), batteryThreshold: 20); b.safe = false; b.failWrite = true
        XCTAssertThrowsError(try e.tick()); XCTAssertTrue(e.restorationBlocked); XCTAssertNotNil(j.record)
        XCTAssertThrowsError(try e.acquire(uid: 2, connection: UUID(), batteryThreshold: 20))
    }
    func testExpiredLeaseRestoresDespiteFailedObservationsAndRetriesCleanup() throws {
        let b = Backend(), j = Journal(); var time = 0.0
        let e = PowerLeaseEngine(backend: b, journal: j, now: { time })
        let token = try e.acquire(uid: 1, connection: UUID(), batteryThreshold: 20)
        time = 31; b.failRead = true; b.failBattery = true
        XCTAssertThrowsError(try e.tick())
        XCTAssertEqual(b.value, 0); XCTAssertNil(e.activeLease)
        XCTAssertTrue(e.restorationBlocked); XCTAssertNotNil(j.record)
        b.failRead = false
        try e.tick()
        XCTAssertFalse(e.restorationBlocked); XCTAssertNil(j.record)
        XCTAssertThrowsError(try e.renew(token))
        XCTAssertEqual(b.writes, [true, false])
    }
    func testSensorFailureReleasesBeforeDeadlineAndFailedWriteRetries() throws {
        let b = Backend(), j = Journal()
        let e = PowerLeaseEngine(backend: b, journal: j, now: { 0 })
        _ = try e.acquire(uid: 1, connection: UUID(), batteryThreshold: 20)
        b.failBattery = true; b.failWrite = true
        XCTAssertThrowsError(try e.tick()); XCTAssertNil(e.activeLease)
        XCTAssertTrue(e.restorationBlocked); XCTAssertEqual(b.value, 1)
        b.failWrite = false
        try e.tick()
        XCTAssertEqual(b.value, 0); XCTAssertNil(j.record)
        XCTAssertFalse(e.restorationBlocked)
    }

}
