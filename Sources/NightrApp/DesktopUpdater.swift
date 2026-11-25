#if os(macOS)
import AppKit
import Combine
import Foundation

@MainActor final class DesktopUpdater: ObservableObject {
    private struct Reply: Decodable, Sendable {
        let state: String
        let version: String?
        let error: String?
    }

    @Published private(set) var presentation: DesktopUpdatePresentation
    @Published private(set) var automatic: Bool
    private let defaults: UserDefaults
    private var scheduler: Task<Void, Never>?
    private let interval: TimeInterval = 24 * 60 * 60
    private static let preferenceKey = "AutomaticallyDownloadUpdates"
    private static let lastCheckKey = "LastDesktopUpdateCheck"
    private static let resources = URL(fileURLWithPath: "/Applications/Nightr.app/Contents/Resources", isDirectory: true)
    private static let command = resources.appendingPathComponent("libexec/Install Nightr Update.command")

    init(defaults: UserDefaults = .standard, bundle: Bundle = .main) {
        self.defaults = defaults
        automatic = defaults.object(forKey: Self.preferenceKey) as? Bool ?? true
        let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        let revision = bundle.object(forInfoDictionaryKey: "NightrSourceRevision") as? String
        presentation = .init(version: version ?? "Development build", build: revision.map { String($0.prefix(7)) },
                             supported: bundle.bundleURL.path == "/Applications/Nightr.app" && version != nil
                                && FileManager.default.isExecutableFile(atPath: Self.command.path))
    }

    func start() {
        guard scheduler == nil, presentation.supported else { return }
        scheduler = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            await self?.restorePending()
            while !Task.isCancelled {
                self?.checkIfDue()
                try? await Task.sleep(for: .seconds(15 * 60))
            }
        }
    }

    func saveAutomatic(_ enabled: Bool) {
        let changed = automatic != enabled
        defaults.set(enabled, forKey: Self.preferenceKey)
        automatic = enabled
        if enabled && changed { checkIfDue() }
    }

    private func checkIfDue() {
        guard automatic else { return }
        let elapsed = Date().timeIntervalSince1970 - defaults.double(forKey: Self.lastCheckKey)
        if elapsed >= interval || elapsed < 0 { check() }
    }

    private func restorePending() async {
        guard presentation.phase == .idle else { return }
        presentation.phase = .checking
        let response = await Self.run(["desktop-cached"])
        if response.state == "ready", let version = response.version {
            presentation.phase = .ready(version)
        } else { presentation.phase = .idle }
    }

    func check() {
        guard presentation.supported, !presentation.phase.busy else { return }
        presentation.phase = .checking
        defaults.set(Date().timeIntervalSince1970, forKey: Self.lastCheckKey)
        Task {
            let result = await Self.run(["desktop-check"])
            if result.state == "available", let version = result.version {
                presentation.phase = .downloading
                accept(await Self.run(["desktop-stage", "--expected-version", version]))
            } else { accept(result) }
        }
    }

    private func accept(_ result: Reply) {
        switch (result.state, result.version) {
        case ("ready", let version?): presentation.phase = .ready(version)
        case ("current", _): presentation.phase = .current
        case ("offline", _): presentation.phase = .offline
        case ("unpublished", _): presentation.phase = .unpublished
        default: presentation.phase = .failed(result.error ?? "Check for updates again.")
        }
    }

    func install() {
        guard let version = presentation.phase.readyVersion else { return }
        presentation.phase = .opening
        let terminal = URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app", isDirectory: true)
        NSWorkspace.shared.open([Self.command], withApplicationAt: terminal, configuration: .init()) { [weak self] _, error in
            let message = error?.localizedDescription
            Task { @MainActor in
                self?.presentation.phase = message.map(DesktopUpdatePresentation.Phase.failed) ?? .ready(version)
            }
        }
    }

    private static func run(_ arguments: [String]) async -> Reply {
        let resources = resources
        return await Task.detached(priority: .utility) {
            let process = Process()
            let output = Pipe()
            process.executableURL = resources.appendingPathComponent("runtime/bin/python3")
            process.arguments = ["-I", resources.appendingPathComponent("libexec/nightr_install.py").path] + arguments + ["--json"]
            var environment = ProcessInfo.processInfo.environment
            environment["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
            process.environment = environment
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = output
            process.standardError = FileHandle.nullDevice
            do {
                try process.run()
                let data = output.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                let reply = try JSONDecoder().decode(Reply.self, from: data)
                if process.terminationStatus == 0 || reply.error != nil { return reply }
            } catch { }
            return Reply(state: "error", version: nil, error: "The package updater couldn’t complete the check.")
        }.value
    }
}
#endif
