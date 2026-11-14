#if os(macOS)
import XCTest
import Darwin
@testable import NightrPowerProtocol
final class JournalTests: XCTestCase {
    func temporary() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
    func testDurableJournalRoundTripAndExclusiveLock() throws {
        let path = try temporary()
        let first = try SecureJournal(directoryPath: path.path, expectedOwner: getuid())
        let lock = try first.lock(); defer { close(lock) }
        let second = try SecureJournal(directoryPath: path.path, expectedOwner: getuid())
        XCTAssertThrowsError(try second.lock())
        let record = PowerJournal(generation: UUID())
        try first.save(record); XCTAssertEqual(try first.load(), record)
        let attributes = try FileManager.default.attributesOfItem(atPath: path.appendingPathComponent("lease.json").path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        try first.clear(); XCTAssertNil(try first.load())
    }
    func testRejectDirectorySymlinkWrongOwnerAndPermissiveMode() throws {
        let path = try temporary(), link = path.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: path)
        XCTAssertThrowsError(try SecureJournal(directoryPath: link.path, expectedOwner: getuid()))
        XCTAssertThrowsError(try SecureJournal(directoryPath: path.path, expectedOwner: getuid() + 1))
        chmod(path.path, 0o755)
        XCTAssertThrowsError(try SecureJournal(directoryPath: path.path, expectedOwner: getuid()))
    }
    func testRejectJournalSymlinkAndHardlink() throws {
        let path = try temporary(), name = path.appendingPathComponent("lease.json"), target = path.appendingPathComponent("target")
        try Data("private".utf8).write(to: target)
        let journal = try SecureJournal(directoryPath: path.path, expectedOwner: getuid())
        try FileManager.default.createSymbolicLink(at: name, withDestinationURL: target)
        XCTAssertThrowsError(try journal.load()); XCTAssertThrowsError(try journal.save(PowerJournal(generation: UUID())))
        XCTAssertEqual(try String(contentsOf: target), "private")
        try FileManager.default.removeItem(at: name)
        try FileManager.default.linkItem(at: target, to: name)
        XCTAssertThrowsError(try journal.load())
    }
}
#endif
