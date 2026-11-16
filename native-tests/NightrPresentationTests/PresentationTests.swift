#if os(macOS)
import XCTest
import AppKit
import NightrCore
@testable import NightrApp

/// Offscreen only: no windows, AppModel, user store, controller, credentials or
/// services. The interactive macOS desktop test gate remains unchanged.
final class PresentationTests: XCTestCase {
    @MainActor func testApprovedArtworkIsIntrinsicTemplate() {
        XCTAssertEqual(MoonSparkArtwork.menuImage.size, NSSize(width: 19, height: 19))
        XCTAssertTrue(MoonSparkArtwork.menuImage.isTemplate)
    }
    #if DEBUG
    @MainActor func testActualNativeViewsRenderWithSyntheticData() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("nightr-presentations-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try NativePresentationRenderer.run(output: directory)
        let files = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        XCTAssertEqual(files.filter { $0.hasSuffix(".png") }.count, 18)
    }
    #endif
}
#endif
