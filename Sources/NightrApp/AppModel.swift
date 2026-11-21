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
    @Published var presentation = GUIPresentationState(headless: GUILaunchConfiguration(arguments: CommandLine.arguments).headless)
    private var settingsRequests: GUISettingsNotificationReceiver?
    private var service: ControllerService?
    private var events: MacSystemEvents?
    private var poll: Task<Void, Never>?
    private var connecting: Task<Bool, Never>?
    private let startIntent = GUIStartIntent()
    private let controllerCommands = GUIControllerCommands { try ControllerClient().request($0) }
    let store = SettingsStore()
    override init() {
        super.init()
        settingsRequests = GUISettingsNotificationReceiver()
        Task {
            if GUILaunchConfiguration(arguments: CommandLine.arguments).startup == .presentation {
                await refresh()
                beginPolling()
            } else { _ = await boot(initialLaunch: true) }
            if CommandLine.arguments.contains("--setup") { GUIEventInbox.receive(.general) }
            if CommandLine.arguments.contains("--hotspot-setup") || CommandLine.arguments.contains("--enable-discovery") { GUIEventInbox.receive(.connectivity) }
        }
    }

    @discardableResult func boot(initialLaunch: Bool = false) async -> Bool {
        if let service, await service.isRunning() { return true }
        if let connecting { return await connecting.value }
        poll?.cancel(); poll = nil
        let connection = Task { @MainActor [weak self] in await self?.connectController() ?? false }
        connecting = connection
        let connected = await connection.value
        connecting = nil
        if initialLaunch && GUILaunchConfiguration(arguments: CommandLine.arguments).exitsAfterConnectingToExistingOwner && service == nil {
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
    static func runHelperCommand() -> Never {
        let service = SMAppService.daemon(plistName: "ai.nightr.powerhelper.plist")
        do {
            try helper()
            if service.status == .enabled { exit(0) }
            FileHandle.standardError.write(Data("Complete Nightr helper approval in System Settings → Login Items.\n".utf8))
            exit(2)
        } catch {
            FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8))
            exit(service.status == .requiresApproval ? 2 : 1)
        }
    }
    static func notifications() async throws {
        _ = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
    }
    static func complete() throws {
        try helper()
        let receipt = try login(enabled: SettingsStore().load().launchAtLogin)
        if !receipt.pending.isEmpty { throw DesktopServiceError(approvalGuidance) }
    }
    static let approvalGuidance = "Nightr is registered and waiting for approval. Review System Settings → General → Login Items."
    static func helper() throws {
        var receipt = DesktopRegistrationReceipt()
        try receipt.ensure(MacDesktopService(name: "Power helper", service: .daemon(plistName: "ai.nightr.powerhelper.plist")))
        if !receipt.pending.isEmpty { throw DesktopServiceError("Complete Nightr power helper approval in System Settings → General → Login Items.") }
    }
    static func login(enabled: Bool) throws -> DesktopRegistrationReceipt {
        let services = [MacDesktopService(name: "Nightr menu bar app", service: .mainApp),
                        MacDesktopService(name: "Nightr background controller", service: .agent(plistName: "ai.nightr.agent.plist"))]
        if enabled { return try DesktopRegistrationReceipt.enable(services) }
        try DesktopRegistrationReceipt.disable(services)
        return DesktopRegistrationReceipt()
    }
    static func systemWiFi() { NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.wifi-settings-extension")!) }
}
@MainActor private final class MacDesktopService: DesktopServiceRegistration {
    let name: String
    let service: SMAppService
    init(name: String, service: SMAppService) { self.name = name; self.service = service }
    var status: DesktopServiceStatus {
        switch service.status {
        case .notRegistered: return .notRegistered
        case .enabled: return .enabled
        case .requiresApproval: return .requiresApproval
        case .notFound: return .unavailable
        @unknown default: return .unavailable
        }
    }
    func register() throws { try service.register() }
    func unregister() throws { try service.unregister() }
}
#endif
