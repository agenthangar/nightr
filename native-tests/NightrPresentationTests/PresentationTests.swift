#if os(macOS)
import XCTest
import AppKit
import NightrCore
@testable import NightrApp

/// Offscreen only: no visible windows, AppModel, user store, controller, credentials or
/// services. The interactive macOS desktop test gate remains unchanged.
final class PresentationTests: XCTestCase {
    func testHotspotModeReflectsOnlyRecognizedSystemPreferences() {
        XCTAssertEqual(HotspotJoinMode(preference: "Automatic", supportsAutomatic: true).symbol, "checkmark.square.fill")
        XCTAssertEqual(HotspotJoinMode(preference: "Automatic", supportsAutomatic: false), .unknown)
        XCTAssertEqual(HotspotJoinMode(preference: "AskToJoin", supportsAutomatic: true), .ask)
        XCTAssertEqual(HotspotJoinMode(preference: "Never", supportsAutomatic: true), .never)
        for value: Any? in [nil, 1, "Unexpected"] {
            XCTAssertEqual(HotspotJoinMode(preference: value, supportsAutomatic: true), .unknown)
        }
    }

    @MainActor func testApprovedArtworkIsIntrinsicTemplate() {
        XCTAssertEqual(MoonSparkArtwork.menuImage.size, NSSize(width: 19, height: 19))
        XCTAssertTrue(MoonSparkArtwork.menuImage.isTemplate)
        XCTAssertTrue(MoonSparkArtwork.activeMenuImage.isTemplate)
        XCTAssertEqual(MoonSparkArtwork.activeMenuImage.size, MoonSparkArtwork.menuImage.size)
        XCTAssertNotEqual(MoonSparkArtwork.activeMenuImage.tiffRepresentation, MoonSparkArtwork.menuImage.tiffRepresentation)
    }
    #if DEBUG
    @MainActor func testActualNativeViewsRenderWithSyntheticData() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("nightr-presentations-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try NativePresentationRenderer.run(output: directory)
        let files = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        XCTAssertEqual(files.filter { $0.hasSuffix(".png") }.count, 28)
    }
    #endif
}
#endif
