import Darwin
import Foundation
import NightrInstallProtocol
import SystemConfiguration

private func consoleUser() -> UInt32? {
    var userID: uid_t = 0
    guard let name = SCDynamicStoreCopyConsoleUser(nil, &userID, nil) as String?,
          name != "loginwindow", name != "_mbsetupuser", userID != 0 else { return nil }
    return userID
}

private func installerRunning(as user: UInt32) -> Bool {
    let installer = URL(fileURLWithPath: "/System/Library/CoreServices/Installer.app/Contents/MacOS/Installer")
        .resolvingSymlinksInPath().path
    let required = proc_listpids(UInt32(PROC_UID_ONLY), user, nil, 0)
    guard required > 0, required <= 1_048_576 else { return false }
    // Leave room for processes started between sizing and reading the list.
    var pids = [pid_t](repeating: 0, count: Int(required) / MemoryLayout<pid_t>.stride + 64)
    let bytes = pids.withUnsafeMutableBytes {
        proc_listpids(UInt32(PROC_UID_ONLY), user, $0.baseAddress, Int32($0.count))
    }
    let count = Int(bytes) / MemoryLayout<pid_t>.stride
    guard count > 0, count <= pids.count else { return false }
    var path = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
    return pids.prefix(count).contains { pid in
        guard pid > 1, proc_pidpath(pid, &path, UInt32(path.count)) > 0, String(cString: path) == installer else {
            return false
        }
        return (try? processInfo(pid).pbi_uid) == user
    }
}

func reopenDesktopApp() {
    // Apple's command-line installer sets this variable. Also require positive
    // evidence of the Apple desktop installer in the current console session.
    let arguments = DesktopInstallLaunch.arguments(
        commandLineInstall: ProcessInfo.processInfo.environment["COMMAND_LINE_INSTALL"] != nil,
        consoleUser: consoleUser,
        installerRunning: installerRunning(as:),
        guiDomainAvailable: { (try? run("/bin/launchctl", ["print", "gui/\($0)"], captureOutput: false)) != nil }
    )
    guard let arguments else { return }
    do { _ = try run("/bin/launchctl", arguments, captureOutput: false) }
    catch { fputs("Nightr is installed, but could not reopen. Open Nightr from Applications.\n", stderr) }
}
