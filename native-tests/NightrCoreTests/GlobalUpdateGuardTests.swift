import XCTest
import Foundation
import NightrTestProcess
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif
@testable import NightrController

@_silgen_name("flock") private func testGlobalFlock(_ fd: Int32, _ operation: Int32) -> Int32
final class GlobalUpdateGuardTests: XCTestCase {
    private func fixture() throws -> URL {
        let directory = URL(fileURLWithPath: "/tmp/ng-" + UUID().uuidString.prefix(8))
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o755])
        for name in ["update.lock", "controller.lock"] {
            let file = directory.appendingPathComponent(name)
            try Data().write(to: file)
            try FileManager.default.setAttributes([.posixPermissions: 0o666], ofItemAtPath: file.path)
        }
        return directory
    }
    private func record(_ type: Int16) -> flock {
        var value = flock(); value.l_type = type; value.l_whence = Int16(SEEK_SET); value.l_start = 0; value.l_len = 0
        return value
    }
    func testControllerFlockLivesUntilGuardReleaseAndRejectsSymlinks() throws {
        let directory = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        var controller: GlobalControllerGuard? = try GlobalControllerGuard(directory: directory, expectedUID: getuid())
        let controllerFD = open(directory.appendingPathComponent("controller.lock").path, O_RDONLY)
        let updateFD = open(directory.appendingPathComponent("update.lock").path, O_RDWR)
        defer { close(controllerFD); close(updateFD) }
        XCTAssertNotEqual(testGlobalFlock(controllerFD, LOCK_EX | LOCK_NB), 0)
        // Startup releases its short record lock after retaining the controller flock.
        var exclusive = record(Int16(F_WRLCK))
        XCTAssertEqual(fcntl(updateFD, F_SETLK, &exclusive), 0)
        var unlock = record(Int16(F_UNLCK)); XCTAssertEqual(fcntl(updateFD, F_SETLK, &unlock), 0)
        controller = nil; _ = controller
        XCTAssertEqual(testGlobalFlock(controllerFD, LOCK_EX | LOCK_NB), 0)
        _ = testGlobalFlock(controllerFD, LOCK_UN)
        try FileManager.default.removeItem(at: directory.appendingPathComponent("controller.lock"))
        try FileManager.default.createSymbolicLink(at: directory.appendingPathComponent("controller.lock"), withDestinationURL: directory.appendingPathComponent("update.lock"))
        XCTAssertThrowsError(try GlobalControllerGuard(directory: directory, expectedUID: getuid()))
    }
    func testAnyMarkerAndLookupFailureBlockStartup() throws {
        let directory = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let marker = directory.appendingPathComponent("install-transaction.json")
        for data in [Data(), Data("not JSON".utf8), Data("{\"stage\":\"interrupted\"}".utf8)] {
            try data.write(to: marker)
            try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: marker.path)
            XCTAssertThrowsError(try GlobalControllerGuard(directory: directory, expectedUID: getuid()))
            try FileManager.default.removeItem(at: marker)
        }
        try FileManager.default.createSymbolicLink(at: marker, withDestinationURL: directory.appendingPathComponent("missing"))
        XCTAssertThrowsError(try GlobalControllerGuard(directory: directory, expectedUID: getuid()))
        try FileManager.default.removeItem(at: marker)
        XCTAssertThrowsError(try GlobalControllerGuard(directory: directory, expectedUID: getuid(), markerCheck: { _ in
            throw CocoaError(.fileReadNoPermission)
        }))
    }
    func testLateMarkerIsCheckedAndControllerLockIsReleasedOnFailure() throws {
        let directory = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        var checks = 0
        XCTAssertThrowsError(try GlobalControllerGuard(directory: directory, expectedUID: getuid(), markerCheck: { marker in
            checks += 1
            if checks == 2 { try Data("interrupted".utf8).write(to: marker) }
            try GlobalControllerGuard.requireNoTransaction(marker)
        }))
        XCTAssertEqual(checks, 2)
        let fd = open(directory.appendingPathComponent("controller.lock").path, O_RDONLY)
        defer { close(fd) }
        XCTAssertEqual(testGlobalFlock(fd, LOCK_EX | LOCK_NB), 0)
        _ = testGlobalFlock(fd, LOCK_UN)
    }
    func testPOSIXUpdaterLockExcludesStartupAndReportsOwningPID() throws {
        let directory = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let updateFD = open(directory.appendingPathComponent("update.lock").path, O_RDWR)
        guard updateFD >= 0 else { throw CocoaError(.fileReadUnknown) }
        defer { close(updateFD) }
        var ready: [Int32] = [0, 0]; var release: [Int32] = [0, 0]
        guard pipe(&ready) == 0, pipe(&release) == 0 else { throw CocoaError(.fileReadUnknown) }
        defer { close(ready[0]); close(ready[1]); close(release[0]); close(release[1]) }
        let child = nightr_test_spawn_lock_owner(updateFD, ready[1], release[0])
        guard child >= 0 else { throw CocoaError(.fileReadUnknown) }
        var reaped = false
        defer { if !reaped { _ = kill(child, SIGKILL); var status: Int32 = 0; _ = waitpid(child, &status, 0) } }
        var observation = pollfd(fd: ready[0], events: Int16(POLLIN), revents: 0)
        guard poll(&observation, 1, 2_000) == 1 else { throw CocoaError(.fileReadUnknown) }
        var result: UInt8 = 0; XCTAssertEqual(read(ready[0], &result, 1), 1); XCTAssertEqual(result, 1)
        var query = record(Int16(F_RDLCK))
        XCTAssertEqual(fcntl(updateFD, F_GETLK, &query), 0)
        XCTAssertEqual(query.l_type, Int16(F_WRLCK)); XCTAssertEqual(query.l_pid, child)
        XCTAssertThrowsError(try GlobalControllerGuard(directory: directory, expectedUID: getuid()))
        var signal: UInt8 = 1; XCTAssertEqual(write(release[1], &signal, 1), 1)
        var status: Int32 = 0; XCTAssertEqual(waitpid(child, &status, 0), child); reaped = true; XCTAssertEqual(status, 0)
        let guardAfterUpdate = try GlobalControllerGuard(directory: directory, expectedUID: getuid())
        withExtendedLifetime(guardAfterUpdate) {}
    }
}
