import XCTest
import Foundation
import NightrInstallProtocol
final class CommandLinkTests: XCTestCase {
    func testAbsentAndCanonicalSymlinkPassWhileUnrelatedEntriesArePreserved() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("nightr")
        let target = "/Applications/Nightr.app/Contents/MacOS/nightr"
        try FixedCommandLink.validate(atPath: path.path, canonicalTarget: target)
        try FileManager.default.createSymbolicLink(atPath: path.path, withDestinationPath: target)
        try FixedCommandLink.validate(atPath: path.path, canonicalTarget: target)
        try FileManager.default.removeItem(at: path)
        try Data("unrelated executable".utf8).write(to: path)
        XCTAssertThrowsError(try FixedCommandLink.validate(atPath: path.path, canonicalTarget: target))
        XCTAssertEqual(try String(contentsOf: path), "unrelated executable")
        try FileManager.default.removeItem(at: path)
        try FileManager.default.createSymbolicLink(atPath: path.path, withDestinationPath: "/other/tool")
        XCTAssertThrowsError(try FixedCommandLink.validate(atPath: path.path, canonicalTarget: target))
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: path.path), "/other/tool")
    }
}
