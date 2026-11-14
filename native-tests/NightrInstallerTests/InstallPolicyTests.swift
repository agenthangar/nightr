import XCTest
import NightrInstallProtocol
import Foundation

private let boot = "11111111-1111-4111-8111-111111111111"
private let nextBoot = "22222222-2222-4222-8222-222222222222"
private let invocation = "/synthetic/Scripts/guard:1:2:3:4"
final class InstallPolicyTests: XCTestCase {
    let owner = InstallOwner(pid: 101, uid: 501, processStartSeconds: 1, processStartMicroseconds: 0, bootID: boot)
    func request(_ transaction: UUID = UUID(), path: String = "/Volumes/Nightr/Nightr.pkg", version: String = "0.1.1", operation: String = "install") -> InstallRequest {
        InstallRequest(transaction: transaction, owner: owner, packagePath: path, version: version, originalVersion: "0.1.0", teamID: "ABCDE12345", operation: operation)
    }
    func testMalformedMarkersCannotSupplyRebootProof() throws {
        let valid = InstallMarker(owner: nil, originalVersion: "0.1.0", teamID: "ABCDE12345", packagePath: "/Volumes/Nightr/Nightr.pkg", version: "0.1.1", bootID: boot, invocation: invocation)
        let data = try JSONEncoder().encode(valid)
        let base = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        for (key, value) in [("schemaVersion", 2 as Any), ("bootID", "not-a-boot" as Any), ("bootID", "" as Any), ("phase", "unknown" as Any), ("teamID", "wrong" as Any), ("version", "bad" as Any), ("newVersion", "bad" as Any), ("originalVersion", "bad" as Any), ("packagePath", "relative.pkg" as Any), ("invocation", "" as Any)] {
            var object = base; object[key] = value
            let marker = try JSONDecoder().decode(InstallMarker.self, from: JSONSerialization.data(withJSONObject: object))
            XCTAssertThrowsError(try InstallPolicy.validateMarker(marker))
            XCTAssertThrowsError(try InstallPolicy.begin(existing: marker, owner: nil, request: nil, packagePath: valid.packagePath, version: valid.version, teamID: valid.teamID, originalVersion: nil, controllerExclusive: true, bootID: nextBoot, invocation: invocation))
        }
    }
    func testMalformedOwnerIdentityIsRejectedBeforeRecovery() throws {
        let valid = InstallMarker(owner: owner, originalVersion: "0.1.0", teamID: "ABCDE12345", packagePath: "/Volumes/Nightr/Nightr.pkg", version: "0.1.1", bootID: boot, invocation: invocation)
        let encoded = try JSONEncoder().encode(valid)
        let base = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        for (key, value) in [("pid", 0 as Any), ("processStartSeconds", 0 as Any), ("processStartMicroseconds", 1_000_000 as Any), ("bootID", nextBoot as Any)] {
            var object = base
            var changedOwner = try XCTUnwrap(object["owner"] as? [String: Any]); changedOwner[key] = value; object["owner"] = changedOwner
            let marker = try JSONDecoder().decode(InstallMarker.self, from: JSONSerialization.data(withJSONObject: object))
            XCTAssertThrowsError(try InstallPolicy.validateMarker(marker))
            XCTAssertThrowsError(try InstallPolicy.begin(existing: marker, owner: nil, request: nil, packagePath: valid.packagePath, version: valid.version, teamID: valid.teamID, originalVersion: nil, controllerExclusive: true, bootID: nextBoot, invocation: invocation))
        }
    }
    func testManualMarkerBlocksAnySecondInstallUntilVerifiedCompletion() throws {
        let marker = try InstallPolicy.begin(existing: nil, owner: nil, request: nil, packagePath: "/Volumes/Nightr/Nightr.pkg", version: "0.1.0", teamID: "ABCDE12345", originalVersion: nil, controllerExclusive: true, bootID: boot, invocation: invocation)
        XCTAssertThrowsError(try InstallPolicy.begin(existing: marker, owner: nil, request: nil, packagePath: marker.packagePath, version: marker.version, teamID: marker.teamID, originalVersion: nil, controllerExclusive: true, bootID: boot, invocation: invocation))
        let complete = try InstallPolicy.complete(marker, owner: nil, request: nil, packagePath: marker.packagePath, version: marker.version, teamID: marker.teamID)
        XCTAssertEqual(complete.phase, "complete")
    }
    func testManagedInstallBindsKernelOwnerAndExactPackageAndTransaction() throws {
        let r = request()
        let marker = try InstallPolicy.begin(existing: nil, owner: owner, request: r, packagePath: r.packagePath, version: r.version, teamID: r.teamID, originalVersion: r.originalVersion, controllerExclusive: true, bootID: boot, invocation: invocation)
        XCTAssertThrowsError(try InstallPolicy.begin(existing: nil, owner: InstallOwner(pid: 202, uid: 502, processStartSeconds: 1, processStartMicroseconds: 0, bootID: boot), request: r, packagePath: r.packagePath, version: r.version, teamID: r.teamID, originalVersion: r.originalVersion, controllerExclusive: true, bootID: boot, invocation: invocation))
        XCTAssertThrowsError(try InstallPolicy.complete(marker, owner: owner, request: r, packagePath: "/Volumes/Other/Nightr.pkg", version: r.version, teamID: r.teamID))
        XCTAssertThrowsError(try InstallPolicy.finish(marker, owner: owner, request: r, transaction: r.transaction, installedVersion: r.version, teamID: r.teamID))
        let completed = try InstallPolicy.complete(marker, owner: owner, request: r, packagePath: r.packagePath, version: r.version, teamID: r.teamID)
        try InstallPolicy.finish(completed, owner: owner, request: r, transaction: r.transaction, installedVersion: r.version, teamID: r.teamID)
        XCTAssertThrowsError(try InstallPolicy.finish(completed, owner: owner, request: request(), transaction: r.transaction, installedVersion: r.version, teamID: r.teamID))
    }
    func testRollbackPreservesRootGenerationAndOnlyOriginalVersionIsAllowed() throws {
        let r = request()
        let marker = try InstallPolicy.begin(existing: nil, owner: owner, request: r, packagePath: r.packagePath, version: r.version, teamID: r.teamID, originalVersion: r.originalVersion, controllerExclusive: true, bootID: boot, invocation: invocation)
        let completed = try InstallPolicy.complete(marker, owner: owner, request: r, packagePath: r.packagePath, version: r.version, teamID: r.teamID)
        let rollback = request(r.transaction, path: "/Volumes/Previous/Nightr.pkg", version: "0.1.0", operation: "rollback")
        let result = try InstallPolicy.begin(existing: completed, owner: owner, request: rollback, packagePath: rollback.packagePath, version: rollback.version, teamID: rollback.teamID, originalVersion: nil, controllerExclusive: true, bootID: boot, invocation: invocation)
        XCTAssertEqual(result.generation, marker.generation)
        XCTAssertEqual(result.newVersion, "0.1.1")
        try InstallPolicy.repair(result, installedVersion: "0.1.1", teamID: result.teamID, currentBootID: nextBoot)
        let wrong = request(r.transaction, version: "0.9.9", operation: "rollback")
        XCTAssertThrowsError(try InstallPolicy.begin(existing: marker, owner: owner, request: wrong, packagePath: wrong.packagePath, version: wrong.version, teamID: wrong.teamID, originalVersion: nil, controllerExclusive: true, bootID: boot, invocation: invocation))
    }
    func testPendingTransactionsRequireRebootAndAuthenticatedRepairInstall() throws {
        let r = request()
        let pending = try InstallPolicy.begin(existing: nil, owner: owner, request: r, packagePath: r.packagePath, version: r.version, teamID: r.teamID, originalVersion: r.originalVersion, controllerExclusive: true, bootID: boot, invocation: invocation)
        XCTAssertThrowsError(try InstallPolicy.rollbackReady(pending, owner: owner, request: r, transaction: r.transaction))
        XCTAssertThrowsError(try InstallPolicy.repair(pending, installedVersion: "0.1.0", teamID: r.teamID, currentBootID: pending.bootID))
        let recovery = try InstallPolicy.begin(existing: pending, owner: nil, request: nil, packagePath: "/Volumes/Repair/Nightr.pkg", version: r.version, teamID: r.teamID, originalVersion: nil, controllerExclusive: true, bootID: nextBoot, invocation: invocation)
        XCTAssertEqual(recovery.generation, pending.generation)
        XCTAssertEqual(recovery.transaction, pending.transaction)
        XCTAssertEqual(recovery.phase, "pending")
        XCTAssertNil(recovery.owner)
        XCTAssertEqual(recovery.bootID, nextBoot)
        XCTAssertThrowsError(try InstallPolicy.begin(existing: pending, owner: nil, request: nil, packagePath: "/Volumes/Other/Nightr.pkg", version: "0.9.0", teamID: r.teamID, originalVersion: nil, controllerExclusive: true, bootID: nextBoot, invocation: invocation))
        try InstallPolicy.repair(pending, installedVersion: "0.1.0", teamID: r.teamID, currentBootID: nextBoot)
    }
    func testParentExitOrControllerStartAfterPublicationRetainsFailClosedMarker() throws {
        let r = request()
        let marker = try InstallPolicy.begin(existing: nil, owner: owner, request: r, packagePath: r.packagePath, version: r.version, teamID: r.teamID, originalVersion: r.originalVersion, controllerExclusive: true, bootID: boot, invocation: invocation)
        XCTAssertThrowsError(try InstallPolicy.authorizePublishedBegin(marker, observedOwner: nil, controllerExclusive: true))
        XCTAssertThrowsError(try InstallPolicy.authorizePublishedBegin(marker, observedOwner: owner, controllerExclusive: false))
        XCTAssertEqual(marker.phase, "pending")
        XCTAssertEqual(marker.transaction, r.transaction)
        try InstallPolicy.authorizePublishedBegin(marker, observedOwner: owner, controllerExclusive: true)
    }
    func testReusedPIDOrAnotherBootCannotReplayAnInterruptedOwner() throws {
        let r = request()
        let marker = try InstallPolicy.begin(existing: nil, owner: owner, request: r, packagePath: r.packagePath, version: r.version, teamID: r.teamID, originalVersion: r.originalVersion, controllerExclusive: true, bootID: boot, invocation: invocation)
        let reused = InstallOwner(pid: owner.pid, uid: owner.uid, processStartSeconds: 99, processStartMicroseconds: 0, bootID: owner.bootID)
        let rebooted = InstallOwner(pid: owner.pid, uid: owner.uid, processStartSeconds: owner.processStartSeconds, processStartMicroseconds: 0, bootID: nextBoot)
        for changed in [reused, rebooted] {
            XCTAssertThrowsError(try InstallPolicy.complete(marker, owner: changed, request: r, packagePath: r.packagePath, version: r.version, teamID: r.teamID))
        }
    }
    func testDifferentTrustedScriptExtractionCannotCompleteAnExistingMarker() throws {
        var marker = InstallMarker(owner: nil, originalVersion: nil, teamID: "ABCDE12345", packagePath: "/Volumes/Nightr/Nightr.pkg", version: "0.1.0", bootID: boot, invocation: invocation)
        marker.invocation = "/trusted/Scripts/guard:1:100:2:200"
        try InstallPolicy.verifyInvocation(marker, identity: marker.invocation)
        XCTAssertThrowsError(try InstallPolicy.verifyInvocation(marker, identity: "/other/Scripts/guard:1:300:2:400"))
        XCTAssertThrowsError(try InstallPolicy.verifyInvocation(marker, identity: nil))
    }
    func testLiveControllerAndUnverifiedRepairFailClosed() throws {
        let r = request()
        XCTAssertThrowsError(try InstallPolicy.begin(existing: nil, owner: owner, request: r, packagePath: r.packagePath, version: r.version, teamID: r.teamID, originalVersion: r.originalVersion, controllerExclusive: false, bootID: boot, invocation: invocation))
        let marker = InstallMarker(owner: owner, originalVersion: "0.1.0", teamID: r.teamID, packagePath: r.packagePath, version: r.version, bootID: boot, invocation: invocation)
        try InstallPolicy.repair(marker, installedVersion: "0.1.0", teamID: r.teamID, currentBootID: nextBoot)
        XCTAssertThrowsError(try InstallPolicy.repair(marker, installedVersion: "0.1.2", teamID: r.teamID, currentBootID: nextBoot))
        XCTAssertThrowsError(try InstallPolicy.repair(marker, installedVersion: marker.version, teamID: "OTHER12345", currentBootID: nextBoot))
    }
}
