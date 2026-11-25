#if os(macOS)
import AppKit
import SwiftUI
import Network
import ServiceManagement
import UserNotifications
import NightrCore
import NightrController
import NightrPlatform

@MainActor final class AppModel: NSObject, ObservableObject {
    @Published var status: ControllerStatus?
    @Published var error: String?
    @Published var helperStatus: DesktopServiceStatus?
    @Published var setupError: String?
    @Published var presentation = GUIPresentationState(headless: GUILaunchConfiguration(arguments: CommandLine.arguments).headless)
    private var settingsRequests: GUISettingsNotificationReceiver?
    private var service: ControllerService?
    private var events: MacSystemEvents?
    private var poll: Task<Void, Never>?
    private var connecting: Task<Bool, Never>?
    private let startIntent = GUIStartIntent()
    private let controllerCommands = GUIControllerCommands { try ControllerClient().request($0) }
    let store = SettingsStore()
    let updater = DesktopUpdater()
    override init() {
        super.init()
        settingsRequests = GUISettingsNotificationReceiver()
        Task {
            if GUILaunchConfiguration(arguments: CommandLine.arguments).startup == .presentation {
                await refresh()
                beginPolling()
            } else { _ = await boot(initialLaunch: true) }
            if CommandLine.arguments.contains("--hotspot-setup") || CommandLine.arguments.contains("--enable-discovery") { GUIEventInbox.receive(.connectivity) }
        }
    }

    @discardableResult func boot(initialLaunch: Bool = false) async -> Bool {
        if let service, await service.isRunning() { return true }
        if let connecting { return await connecting.value }
        poll?.cancel(); poll = nil
        let launch = GUILaunchConfiguration(arguments: CommandLine.arguments)
        let connection = Task { @MainActor [weak self] in
            await self?.connectController(afterDesktopInstall: initialLaunch && launch.afterDesktopInstall) ?? false
        }
        connecting = connection
        let connected = await connection.value
        connecting = nil
        if initialLaunch && launch.exitsAfterConnectingToExistingOwner && service == nil {
            exit(connected ? 0 : 1)
        }
        beginPolling()
        return connected
    }
    private func connectController(afterDesktopInstall: Bool) async -> Bool {
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
            try await owner.start(afterDesktopInstall: afterDesktopInstall)
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
        if presentation.menuVisible {
            let observedHelper = DesktopSetup.helperStatus
            if helperStatus != .enabled && observedHelper == .enabled { setupError = nil }
            helperStatus = observedHelper
        }
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
        if command == .stop || command == .endForce { startIntent.cancel() }
        let startToken = (command == .start || command == .beginForce) ? startIntent.begin() : nil
        Task {
            if command == .stop, let connecting { _ = await connecting.value }
            do {
                if let startToken, !startIntent.isCurrent(startToken) { return }
                guard let response = try await controllerCommands.request(.init(command: command, settings: settings), intent: startIntent, token: startToken) else { return }
                // An application rejection is a completed response, never a retry signal.
                error = response.error; status = response.status
            } catch is ControllerUnavailableError {
                if let startToken {
                    guard startIntent.isCurrent(startToken), await boot(), startIntent.isCurrent(startToken) else { return }
                    do {
                        guard let response = try await controllerCommands.request(.init(command: command, settings: settings), intent: startIntent, token: startToken) else { return }
                        error = response.error; status = response.status
                    } catch { self.error = error.localizedDescription }
                } else if command == .stop {
                    do { try OfflineController.stop(); status = nil; error = nil }
                    catch { self.error = error.localizedDescription }
                } else { self.error = ControllerUnavailableError().localizedDescription }
            } catch { self.error = error.localizedDescription }
        }
    }
    /// Settings reconciliation must finish before removing a login agent that
    /// may be this process. This path never bootstraps an absent controller.
    func applySettingsForSave(_ settings: NightrCore.Settings) async throws {
        do {
            guard let response = try await controllerCommands.request(.init(command: .applySettings, settings: settings)) else {
                throw IPCError.invalid("Controller returned no settings response.")
            }
            if let message = response.error { throw IPCError.invalid(message) }
            guard response.status != nil else { throw IPCError.invalid("Controller returned no settings status.") }
            status = response.status; error = nil
        } catch is ControllerUnavailableError {
            // Durable settings are sufficient when no owner exists.
        }
    }
    func setupHelper() {
        if DesktopSetup.helperStatus == .requiresApproval {
            SMAppService.openSystemSettingsLoginItems()
            return
        }
        do { try DesktopSetup.helper(); setupError = nil }
        catch { setupError = error.localizedDescription }
        helperStatus = DesktopSetup.helperStatus
        Task { await refresh() }
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


@MainActor enum DesktopSetup {
    /// Only the explicit CLI desktop-setup process presents this confirmation.
    /// It exits before AppModel exists, so setup cannot create a controller.
    static func runDesktopCommand() -> Never {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        app.activate(ignoringOtherApps: true)
        let confirmation = NSAlert()
        confirmation.messageText = "Set up Nightr?"
        confirmation.informativeText = "Authorize the power helper and apply your saved “Launch Nightr at login” preference. Previously enabled protection may resume at login. Your saved preferences are preserved."
        confirmation.addButton(withTitle: "Set Up Nightr")
        confirmation.addButton(withTitle: "Cancel")
        guard confirmation.runModal() == .alertFirstButtonReturn else {
            report("Nightr setup cancelled. No setup changes were made."); exit(3)
        }
        do { try complete(); exit(0) }
        catch {
            let pending = helperStatus == .requiresApproval || loginServices().contains { $0.status == .requiresApproval }
            if pending { SMAppService.openSystemSettingsLoginItems() }
            report(error.localizedDescription); exit(pending ? 2 : 1)
        }
    }
    private static func report(_ message: String) {
        FileHandle.standardError.write(Data((message + "\n").utf8))
    }
    static func runHelperCommand() -> Never {
        let service = SMAppService.daemon(plistName: "ai.nightr.powerhelper.plist")
        do {
            try helper()
            if service.status == .enabled { exit(0) }
            report("Complete Nightr power helper approval in System Settings → General → Login Items.")
            exit(2)
        } catch {
            report(error.localizedDescription)
            exit(service.status == .requiresApproval ? 2 : 1)
        }
    }
    static func notifications() async throws {
        _ = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
    }
    static func complete() throws {
        let launchAtLogin: Bool
        do { launchAtLogin = try SettingsStore().load().launchAtLogin }
        catch { throw DesktopServiceError("Could not read the saved “Launch Nightr at login” preference. " + error.localizedDescription) }
        try helper()
        let receipt = try login(enabled: launchAtLogin)
        if !receipt.pending.isEmpty { throw DesktopServiceError(approvalGuidance) }
    }
    static let approvalGuidance = "“Launch Nightr at login” is saved and waiting for approval. Review System Settings → General → Login Items."
    static var helperStatus: DesktopServiceStatus { helperService().status }
    private static func helperService() -> MacDesktopService {
        MacDesktopService(name: "Power helper", service: .daemon(plistName: "ai.nightr.powerhelper.plist"),
                          requiredPaths: ["Contents/Library/LaunchDaemons/ai.nightr.powerhelper.plist", "Contents/MacOS/nightr-powerhelper"])
    }
    static func helper() throws {
        let receipt = try DesktopRegistrationReceipt.enable([helperService()])
        if !receipt.pending.isEmpty { throw DesktopServiceError("Complete Nightr power helper approval in System Settings → General → Login Items.") }
    }
    private static func loginServices() -> [MacDesktopService] {
        [MacDesktopService(name: "Nightr menu bar app", service: .mainApp, requiredPaths: ["Contents/MacOS/NightrApp"]),
                        MacDesktopService(name: "Nightr background controller", service: .agent(plistName: "ai.nightr.agent.plist"),
                                          requiredPaths: ["Contents/Library/LaunchAgents/ai.nightr.agent.plist", "Contents/MacOS/NightrApp"])]
    }
    static func login(enabled: Bool) throws -> DesktopRegistrationReceipt {
        do {
            let services = loginServices()
            if enabled { return try DesktopRegistrationReceipt.enable(services) }
            try DesktopRegistrationReceipt.disable(services)
            return DesktopRegistrationReceipt()
        } catch {
            throw DesktopServiceError("Could not \(enabled ? "enable" : "disable") “Launch Nightr at login”. " + error.localizedDescription)
        }
    }
    static func systemWiFi() { NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.wifi-settings-extension")!) }
}
@MainActor private final class MacDesktopService: DesktopServiceRegistration {
    let name: String
    let service: SMAppService
    let requiredPaths: [String]
    init(name: String, service: SMAppService, requiredPaths: [String]) {
        self.name = name; self.service = service; self.requiredPaths = requiredPaths
    }
    var status: DesktopServiceStatus {
        guard requiredPaths.allSatisfy({ FileManager.default.fileExists(atPath: Bundle.main.bundleURL.appendingPathComponent($0).path) }) else { return .missingBundleFiles }
        switch service.status {
        case .notRegistered: return .notRegistered
        case .enabled: return .enabled
        case .requiresApproval: return .requiresApproval
        // A lookup error alone is not evidence of missing app files or successful
        // registration/removal. The receipt handles the requested operation.
        case .notFound: return .notFound
        @unknown default: return .unavailable
        }
    }
    func register() throws { try service.register() }
    func unregister() throws { try service.unregister() }
}
#endif
