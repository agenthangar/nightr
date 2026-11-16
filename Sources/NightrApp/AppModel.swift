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
    @Published var presentation = GUIPresentationState(headless: CommandLine.arguments.contains("--controller-only"))
    private var settingsRequests: GUISettingsNotificationReceiver?
    private var settingsWindow: NSWindow?
    private var service: ControllerService?
    private var events: MacSystemEvents?
    private var poll: Task<Void, Never>?
    private var connecting: Task<Bool, Never>?
    private lazy var menuVisibilityFeedback = GUIMenuVisibilityFeedback(
        read: { [weak self] in self?.presentation.menuVisible ?? false },
        publish: { [weak self] visible in
            guard let self else { return }
            var next = self.presentation; next.menuVisible = visible
            self.publishPresentation(next)
        })
    private let startIntent = GUIStartIntent()
    private let controllerCommands = GUIControllerCommands { try ControllerClient().request($0) }
    let store = SettingsStore()
    override init() {
        super.init()
        settingsRequests = GUISettingsNotificationReceiver()
        GUIEventInbox.connect(self)
        if CommandLine.arguments.contains("--setup-helper-only") {
            do {
                try DesktopSetup.helper()
                let status = SMAppService.daemon(plistName: "ai.nightr.powerhelper.plist").status
                if status == .enabled { exit(0) }
                FileHandle.standardError.write(Data("Complete Nightr helper approval in System Settings → Login Items.\n".utf8)); exit(2)
            } catch { FileHandle.standardError.write(Data("Nightr helper authorization failed. Open Nightr setup to repair.\n".utf8)); exit(1) }
        }
        Task {
            if GUIStartupMode(arguments: CommandLine.arguments) == .presentation {
                await refresh()
                beginPolling()
            } else { _ = await boot(initialLaunch: true) }
            if CommandLine.arguments.contains("--setup") { receive(.general) }
            if CommandLine.arguments.contains("--hotspot-setup") || CommandLine.arguments.contains("--enable-discovery") { receive(.connectivity) }
        }
    }
    func menuVisibilityChanged(_ visible: Bool) { menuVisibilityFeedback.receive(visible) }
    private func publishPresentation(_ next: GUIPresentationState) {
        if next != presentation { presentation = next }
    }
    private func promotePresentation(route: GUISettingsRoute? = nil) {
        menuVisibilityFeedback.invalidate()
        var next = presentation
        if let route { next.receive(route) } else { next.reopen() }
        publishPresentation(next)
    }
    func receive(_ route: GUISettingsRoute) {
        promotePresentation(route: route)
        openSettings()
    }
    func reopen() { promotePresentation(); NSApp.activate(ignoringOtherApps: true) }
    func openSettings() {
        promotePresentation()
        if let settingsWindow { settingsWindow.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true); return }
        let view = SettingsView(model: self) { [weak self] in self?.settingsWindow?.close(); self?.settingsWindow = nil }
        let window = NSWindow(contentViewController: NSHostingController(rootView: view))
        window.title = "Nightr Settings"; window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false; window.delegate = self
        settingsWindow = window; window.center(); window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    }
    func windowWillClose(_ notification: Notification) { settingsWindow = nil }

    @discardableResult func boot(initialLaunch: Bool = false) async -> Bool {
        if let service, await service.isRunning() { return true }
        if let connecting { return await connecting.value }
        poll?.cancel(); poll = nil
        let connection = Task { @MainActor [weak self] in await self?.connectController() ?? false }
        connecting = connection
        let connected = await connection.value
        connecting = nil
        if initialLaunch && CommandLine.arguments.contains("--controller-only") && service == nil {
            exit(connected ? 0 : 1)
        }
        beginPolling()
        return connected
    }
    private func connectController() async -> Bool {
        service = nil; events = nil
        do {
            let response = try await Task.detached { try ControllerClient().request(.init(command: .status)) }.value
            status = response.status; error = response.error
            return response.error == nil && response.status != nil
        } catch is ControllerUnavailableError {
            // Only a genuinely absent endpoint permits acquiring a new owner.
        } catch { self.error = error.localizedDescription; return false }
        do {
            let owner = try ControllerService(platform: MacControllerPlatform())
            try await owner.start()
            service = owner
            events = MacSystemEvents { event in Task { await owner.send(event) } }
            status = await owner.status(); error = nil
            return true
        } catch {
            // Another legitimate owner may have won the lock while we connected.
            do {
                let response = try await Task.detached { try ControllerClient().request(.init(command: .status)) }.value
                status = response.status; self.error = response.error
                return response.error == nil && response.status != nil
            } catch { self.error = error.localizedDescription; return false }
        }
    }
    private func beginPolling() {
        poll?.cancel()
        poll = Task { [weak self] in
            while !Task.isCancelled {
                if let service = self?.service, !(await service.isRunning()) { NSApplication.shared.terminate(nil); return }
                await self?.refresh()
                do { try await Task.sleep(nanoseconds: 1_000_000_000) } catch { return }
            }
        }
    }
    func refresh() async {
        if let service {
            let observed = await service.status()
            guard !Task.isCancelled else { return }
            status = observed
        } else {
            do {
                let response = try await Task.detached { try ControllerClient().request(.init(command: .status)) }.value
                guard !Task.isCancelled else { return }
                status = response.status; error = response.error
            } catch {
                guard !Task.isCancelled else { return }
                status = nil; self.error = error.localizedDescription
            }
            // Polling never creates a controller or changes protection intent.
        }
    }
    func command(_ command: ControllerCommand, settings: NightrCore.Settings? = nil) {
        if command == .stop { startIntent.cancel() }
        let startToken = command == .start ? startIntent.begin() : nil
        Task {
            if command == .stop, let connecting { _ = await connecting.value }
            do {
                if let startToken, !startIntent.isCurrent(startToken) { return }
                guard let response = try await controllerCommands.request(.init(command: command, settings: settings), intent: startIntent, token: startToken) else { return }
                // An application rejection is a completed response, never a retry signal.
                error = response.error; status = response.status
            } catch is ControllerUnavailableError {
                if command == .start, let startToken {
                    guard startIntent.isCurrent(startToken), await boot(), startIntent.isCurrent(startToken) else { return }
                    do {
                        guard let response = try await controllerCommands.request(.init(command: .start, settings: settings), intent: startIntent, token: startToken) else { return }
                        error = response.error; status = response.status
                    } catch { self.error = error.localizedDescription }
                } else if command == .stop {
                    do { try OfflineController.stop(); status = nil; error = nil }
                    catch { self.error = error.localizedDescription }
                } else { self.error = ControllerUnavailableError().localizedDescription }
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
        startIntent.cancel()
        Task {
            if let connecting { _ = await connecting.value }
            do {
                let response = try await controllerCommands.request(.init(command: .stop))
                if let message = response?.error { error = message; return }
            } catch is ControllerUnavailableError {
                do { try OfflineController.stop() } catch { self.error = error.localizedDescription; return }
            } catch { self.error = error.localizedDescription; return }
            if let service { await service.shutdown(preserveIntent: false) }
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
