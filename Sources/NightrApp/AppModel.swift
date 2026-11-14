#if os(macOS)
import AppKit
import SwiftUI
import Network
import ServiceManagement
import UserNotifications
import NightrCore
import NightrController
import NightrPlatform

@MainActor final class AppModel: NSObject, ObservableObject, NSWindowDelegate {
    @Published var status: ControllerStatus?
    @Published var error: String?
    private var settingsWindow: NSWindow?
    private var discoveryPermission: DiscoveryPermission?
    private var service: ControllerService?
    private var events: MacSystemEvents?
    private var poll: Task<Void, Never>?
    let store = SettingsStore()
    override init() {
        super.init()
        if CommandLine.arguments.contains("--enable-discovery") {
            let permission = DiscoveryPermission(); discoveryPermission = permission
            Task { NSApp.activate(ignoringOtherApps: true); permission.request(); openSettings(connectivity: true) }
            return
        }
        if CommandLine.arguments.contains("--setup-helper-only") {
            do {
                try DesktopSetup.helper()
                let status = SMAppService.daemon(plistName: "ai.nightr.powerhelper.plist").status
                if status == .enabled { exit(0) }
                FileHandle.standardError.write(Data("Complete Nightr helper approval in System Settings → Login Items.\n".utf8)); exit(2)
            } catch { FileHandle.standardError.write(Data("Nightr helper authorization failed. Open Nightr setup to repair.\n".utf8)); exit(1) }
        }
        Task {
            await boot()
            if CommandLine.arguments.contains("--setup") { openSettings() }
            if CommandLine.arguments.contains("--hotspot-setup") { openSettings(connectivity: true) }
        }
    }
    func openSettings(connectivity: Bool = false) {
        if let settingsWindow { settingsWindow.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true); return }
        let view = SettingsView(model: self, initialConnectivity: connectivity) { [weak self] in self?.settingsWindow?.close(); self?.settingsWindow = nil }
        let window = NSWindow(contentViewController: NSHostingController(rootView: view))
        window.title = "Nightr Settings"; window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false; window.delegate = self
        settingsWindow = window; window.center(); window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    }
    func windowWillClose(_ notification: Notification) { settingsWindow = nil }

    func boot() async {
        do {
            let owner = try ControllerService(platform: MacControllerPlatform())
            try await owner.start()
            service = owner
            events = MacSystemEvents { event in Task { await owner.send(event) } }
        } catch {
            // A second app instance attaches to the per-user controller, never starts another hold.
            do { let response = try ControllerClient().request(.init(command: .status)); status = response.status; self.error = response.error }
            catch { self.error = error.localizedDescription }
            if CommandLine.arguments.contains("--controller-only") {
                // An existing owner needs no second headless app; a failed owner
                // must exit unsuccessfully so launchd's bounded recovery can act.
                exit(status != nil ? 0 : 1)
            }
        }
        poll = Task { [weak self] in
            while !Task.isCancelled {
                if let service = self?.service, !(await service.isRunning()) { NSApplication.shared.terminate(nil); return }
                await self?.refresh()
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
    }
    func refresh() async {
        if let service { status = await service.status() }
        else {
            let result = await Task.detached { try? ControllerClient().request(.init(command: .status)) }.value
            if let result { status = result.status; error = result.error }
        }
    }
    func command(_ command: ControllerCommand, settings: NightrCore.Settings? = nil) {
        Task {
            do {
                let response = try await Task.detached { try ControllerClient().request(.init(command: command, settings: settings)) }.value
                error = response.error; status = response.status
            } catch { self.error = error.localizedDescription }
        }
    }
    var label: String {
        guard let status else { return "Unavailable" }
        if status.holding { return "On" }
        if !status.state.desiredEnabled { return "Off" }
        if status.state.internet == .checking { return "Recovering" }
        if status.state.pause.map({ [PauseReason.setup, .ownership, .crashLimit].contains($0) }) == true { return "Error" }
        return "Paused"
    }
    func quit() {
        Task {
            if let service { await service.shutdown(preserveIntent: false) }
            else {
                _ = await Task.detached { try? ControllerClient().request(.init(command: .stop)) }.value
            }
            NSApplication.shared.terminate(nil)
        }
    }
}


enum DesktopSetup {
    static func notifications() async throws {
        _ = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
    }
    static func complete() throws {
        try helper()
        try login(enabled: SettingsStore().load().launchAtLogin)
    }
    static func helper() throws { try SMAppService.daemon(plistName: "ai.nightr.powerhelper.plist").register() }
    static func login(enabled: Bool) throws {
        if enabled { try SMAppService.agent(plistName: "ai.nightr.agent.plist").register() }
        else { try SMAppService.agent(plistName: "ai.nightr.agent.plist").unregister() }
    }
    static func systemWiFi() { NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.wifi-settings-extension")!) }
}
#endif
