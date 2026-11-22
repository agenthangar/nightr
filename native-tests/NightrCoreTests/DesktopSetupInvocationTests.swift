import XCTest
@testable import NightrCore

final class DesktopSetupInvocationTests: XCTestCase {
    func testOnlyExplicitSetupArgumentsSelectRegistration() {
        XCTAssertEqual(DesktopSetupInvocation(arguments: ["NightrApp", "--setup-desktop"]), .desktop)
        XCTAssertEqual(DesktopSetupInvocation(arguments: ["NightrApp", "--setup-helper-only"]), .helperOnly)
        XCTAssertEqual(DesktopSetupInvocation(arguments: ["--setup"]), .desktop)
        for arguments in [[], ["--settings-only"], ["--controller-only"], ["--after-install"], ["--hotspot-setup"]] {
            XCTAssertNil(DesktopSetupInvocation(arguments: arguments))
        }
    }
    func testSetupCanNeverSelectControllerStartup() {
        for arguments in [DesktopSetupInvocation.desktopArguments, DesktopSetupInvocation.helperOnlyArguments, ["--setup"]] {
            for extra in [[], ["--controller-only"], ["--after-install"]] {
                let launch = GUILaunchConfiguration(arguments: arguments + extra)
                XCTAssertEqual(launch.startup, .presentation)
                XCTAssertFalse(launch.headless)
                XCTAssertFalse(launch.afterDesktopInstall)
            }
        }
    }
    func testDistributedSettingsRequestsCannotRequestSetup() {
        for section in ["setup", "setup-desktop", "--setup-desktop", "setup-helper-only"] {
            XCTAssertNil(GUISettingsRequest(userInfo: ["requestID": UUID().uuidString, "section": section]))
        }
        let request = GUISettingsRequest(route: .general)
        var payload = request.userInfo
        payload["setup"] = true
        XCTAssertNil(GUISettingsRequest(userInfo: payload))
    }
}
