import XCTest
import Foundation
import NightrInstallProtocol

final class InstallerCanonicalPathTests: XCTestCase {
    private func fixture() throws -> String {
#if os(macOS)
        let root = "/private/tmp/nightr-canonical-" + UUID().uuidString
#else
        let root = "/tmp/nightr-canonical-" + UUID().uuidString
#endif
        try FileManager.default.createDirectory(atPath: root + "/Scripts", withIntermediateDirectories: true)
        try Data().write(to: URL(fileURLWithPath: root + "/Scripts/guard"))
        return root
    }
    func testCanonicalSpellingAndLexicalParentsRetainPrivateTemporaryNamespace() throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let path = try InstallerCanonicalPath(root + "/Scripts/guard")
        XCTAssertEqual(path.path, root + "/Scripts/guard")
        XCTAssertEqual(path.directory, root + "/Scripts")
#if os(macOS)
        let alias = try InstallerCanonicalPath(String(root.dropFirst("/private".count)) + "/Scripts/guard")
        XCTAssertEqual(alias.path, path.path)
        XCTAssertEqual(alias.ancestors, path.ancestors)
        XCTAssertEqual(path.ancestors, [root + "/Scripts/guard", root + "/Scripts", root, "/private/tmp", "/private"])
        XCTAssertFalse(path.ancestors.contains("/tmp"))
#endif
    }
    func testInternalSymlinkResolvesOnceBeforeLexicalWalk() throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(atPath: root) }
        try FileManager.default.createSymbolicLink(atPath: root + "/alias", withDestinationPath: "Scripts")
        let path = try InstallerCanonicalPath(root + "/alias/guard")
        XCTAssertEqual(path.path, root + "/Scripts/guard")
        XCTAssertEqual(path.directory, root + "/Scripts")
        XCTAssertFalse(path.ancestors.contains(root + "/alias"))
    }
    func testMissingPathFailsClosed() throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(atPath: root) }
        XCTAssertThrowsError(try InstallerCanonicalPath(root + "/missing"))
    }
}
