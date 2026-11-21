public enum DesktopInstallLaunch {
    public static func arguments(
        commandLineInstall: Bool,
        consoleUser: () -> UInt32?,
        installerRunning: (UInt32) -> Bool,
        guiDomainAvailable: (UInt32) -> Bool
    ) -> [String]? {
        guard !commandLineInstall, let user = consoleUser(), user != 0,
              installerRunning(user), guiDomainAvailable(user), consoleUser() == user else { return nil }
        return ["asuser", String(user), "/usr/bin/sudo", "-n", "-H", "-u", "#\(user)", "--",
                "/usr/bin/open", "-g", "-a", "/Applications/Nightr.app", "--args", "--after-install"]
    }
}
