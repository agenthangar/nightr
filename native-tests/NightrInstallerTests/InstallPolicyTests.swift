import XCTest
import NightrInstallProtocol
final class InstallPolicyTests: XCTestCase {
    let owner = InstallOwner(pid: 101, uid: 501)
    func request(_ transaction: UUID = UUID(), path: String = "/Volumes/Nightr/Nightr.pkg", version: String = "0.1.1", operation: String = "install") -> InstallRequest {
        InstallRequest(transaction: transaction, owner: owner, packagePath: path, version: version, originalVersion: "0.1.0", teamID: "ABCDE12345", operation: operation)
    }
    func testManualMarkerBlocksAnySecondInstallUntilVerifiedCompletion() throws {
        let marker = try InstallPolicy.begin(existing: nil, owner: nil, request: nil, packagePath: "/Volumes/Nightr/Nightr.pkg", version: "0.1.0", teamID: "ABCDE12345", originalVersion: nil, controllerExclusive: true)
        XCTAssertThrowsError(try InstallPolicy.begin(existing: marker, owner: nil, request: nil, packagePath: marker.packagePath, version: marker.version, teamID: marker.teamID, originalVersion: nil, controllerExclusive: true))
        let complete = try InstallPolicy.complete(marker, owner: nil, request: nil, packagePath: marker.packagePath, version: marker.version, teamID: marker.teamID)
        XCTAssertEqual(complete.phase, "complete")
    }
    func testManagedInstallBindsKernelOwnerAndExactPackageAndTransaction() throws {
        let r = request()
        let marker = try InstallPolicy.begin(existing: nil, owner: owner, request: r, packagePath: r.packagePath, version: r.version, teamID: r.teamID, originalVersion: r.originalVersion, controllerExclusive: true)
        XCTAssertThrowsError(try InstallPolicy.begin(existing: nil, owner: InstallOwner(pid: 202, uid: 502), request: r, packagePath: r.packagePath, version: r.version, teamID: r.teamID, originalVersion: r.originalVersion, controllerExclusive: true))
        XCTAssertThrowsError(try InstallPolicy.complete(marker, owner: owner, request: r, packagePath: "/Volumes/Other/Nightr.pkg", version: r.version, teamID: r.teamID))
        XCTAssertThrowsError(try InstallPolicy.finish(marker, owner: owner, request: r, transaction: r.transaction, installedVersion: r.version, teamID: r.teamID))
        let completed = try InstallPolicy.complete(marker, owner: owner, request: r, packagePath: r.packagePath, version: r.version, teamID: r.teamID)
        try InstallPolicy.finish(completed, owner: owner, request: r, transaction: r.transaction, installedVersion: r.version, teamID: r.teamID)
        XCTAssertThrowsError(try InstallPolicy.finish(completed, owner: owner, request: request(), transaction: r.transaction, installedVersion: r.version, teamID: r.teamID))
    }
    func testRollbackPreservesRootGenerationAndOnlyOriginalVersionIsAllowed() throws {
        let r = request()
        let marker = try InstallPolicy.begin(existing: nil, owner: owner, request: r, packagePath: r.packagePath, version: r.version, teamID: r.teamID, originalVersion: r.originalVersion, controllerExclusive: true)
        let rollback = request(r.transaction, path: "/Volumes/Previous/Nightr.pkg", version: "0.1.0", operation: "rollback")
        let result = try InstallPolicy.begin(existing: marker, owner: owner, request: rollback, packagePath: rollback.packagePath, version: rollback.version, teamID: rollback.teamID, originalVersion: nil, controllerExclusive: true)
        XCTAssertEqual(result.generation, marker.generation)
        let wrong = request(r.transaction, version: "0.9.9", operation: "rollback")
        XCTAssertThrowsError(try InstallPolicy.begin(existing: marker, owner: owner, request: wrong, packagePath: wrong.packagePath, version: wrong.version, teamID: wrong.teamID, originalVersion: nil, controllerExclusive: true))
    }
    func testLiveControllerAndUnverifiedRepairFailClosed() throws {
        let r = request()
        XCTAssertThrowsError(try InstallPolicy.begin(existing: nil, owner: owner, request: r, packagePath: r.packagePath, version: r.version, teamID: r.teamID, originalVersion: r.originalVersion, controllerExclusive: false))
        let marker = InstallMarker(owner: owner, originalVersion: "0.1.0", teamID: r.teamID, packagePath: r.packagePath, version: r.version)
        try InstallPolicy.repair(marker, installedVersion: "0.1.0", teamID: r.teamID)
        XCTAssertThrowsError(try InstallPolicy.repair(marker, installedVersion: "0.1.2", teamID: r.teamID))
        XCTAssertThrowsError(try InstallPolicy.repair(marker, installedVersion: marker.version, teamID: "OTHER12345"))
    }
}
