import XCTest
import NightrInstallProtocol

final class DesktopInstallLaunchTests: XCTestCase {
    func testLaunchUsesTheVerifiedDesktopUsersBootstrapAndCredentials() {
        let user: UInt32 = 501
        let command = DesktopInstallLaunch.arguments(
            commandLineInstall: false,
            consoleUser: { user },
            installerRunning: { $0 == user },
            guiDomainAvailable: { $0 == user }
        )
        XCTAssertEqual(command, [
            "asuser", "501", "/usr/bin/sudo", "-n", "-H", "-u", "#501", "--",
            "/usr/bin/open", "-g", "-a", "/Applications/Nightr.app", "--args", "--after-install"
        ])
    }

    func testCommandLineInstallsSkipDesktopProbes() {
        XCTAssertNil(DesktopInstallLaunch.arguments(
            commandLineInstall: true,
            consoleUser: { XCTFail("unexpected console query"); return 501 },
            installerRunning: { _ in XCTFail("unexpected Installer lookup"); return true },
            guiDomainAvailable: { _ in XCTFail("unexpected launchd query"); return true }
        ))
    }

    func testLaunchRequiresAStableNonRootConsoleSessionWithInstallerAndGUI() {
        for (user, nextUser, installer, gui): (UInt32?, UInt32?, Bool, Bool) in [
            (nil, nil, true, true), (0, 0, true, true), (501, 502, true, true), (501, nil, true, true),
            (501, 501, false, true), (501, 501, true, false)
        ] {
            var checkedConsole = false
            XCTAssertNil(DesktopInstallLaunch.arguments(
                commandLineInstall: false,
                consoleUser: {
                    defer { checkedConsole = true }
                    return checkedConsole ? nextUser : user
                },
                installerRunning: { _ in installer },
                guiDomainAvailable: { _ in gui }
            ))
        }
    }
}
