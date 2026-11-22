import Foundation
import NightrCore
import NightrController
import NightrMCP
import NightrMCPController
#if os(macOS)
import Security
import NightrPowerClient
#endif
#if os(macOS)
import NightrPlatform
import AppKit
import Darwin
import MachO
#else
import Glibc
#endif

@main struct NightrCLI {
    static let usage = """
    Nightr | keep your Mac awake for coding-agent work
    usage: nightr [legacy options]
           nightr start [options]
           nightr stop
           nightr status [--json]
           nightr inference --runtime RUNTIME --model ID [--processing]
           nightr mcp
           nightr setup [--check|--cli-only|--direct-updates]
           nightr config [--show|--edit]
           nightr update [--check]

    Without a command, Nightr runs in the foreground; Ctrl-C stops protection.
    start runs the shared background controller. status never starts it.
    mcp serves local MCP over stdio; connecting or disconnecting never starts/stops protection.
    inference reports producer metadata until Ctrl-C; renews every 5s, expires within 15s.
    It requires enabled local inference and a running controller; it never starts protection.
    config changes defaults for the next run; app Settings apply at a loop boundary.

    Protection: --checks all|agent|internet|none, --require all|none|N
                --forever, --agent/--no-agent, --internet/--no-internet
                --local-inference on|off
    On close:   --display off|on|dim, --lock on|off
    Timing:     --every SECONDS, --grace SECONDS, --retries 0..10,
                --backoff 1..300, --hotspot on|off
    Compatibility switches: -f/-F -a/-A -i/-I -m/-M -D/-L -C, -dim
    """
    static func main() async {
        do { try await run(Array(CommandLine.arguments.dropFirst())) }
        catch { FileHandle.standardError.write(Data("nightr: \(error.localizedDescription)\n".utf8)); exit(1) }
    }
    static var executable: URL {
#if os(macOS)
        var count: UInt32 = 4096
        var bytes = [CChar](repeating: 0, count: Int(count))
        if _NSGetExecutablePath(&bytes, &count) == 0 {
            return URL(fileURLWithPath: String(cString: bytes)).standardizedFileURL.resolvingSymlinksInPath()
        }
#endif
        return URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL.resolvingSymlinksInPath()
    }
    static var contents: URL { executable.deletingLastPathComponent().deletingLastPathComponent() }
    static var resources: URL { contents.appendingPathComponent("Resources") }
    static func run(_ arguments: [String]) async throws {
        // This transport never prints ordinary command output, even for --help.
        if arguments.first == "mcp" {
            guard arguments == ["mcp"] else { throw SettingsError.invalid("usage: nightr mcp (stdio only; no options)") }
            let backend = MCPControllerBackend(operations: MCPControllerOperations(
                launchController: { try await MCPProduction.launchController() },
                setupStatus: { await MCPProduction.setupStatus() }))
            await MCPStdio.run(backend: backend, version: AppBundleVersion.read(infoPlist: contents.appendingPathComponent("Info.plist")) ?? "0.1.0-dev")
            return
        }
        if arguments.contains("--help") || arguments == ["-h"] { print(usage); return }
        if arguments == ["--version"] { print(AppBundleVersion.read(infoPlist: contents.appendingPathComponent("Info.plist")) ?? "0.1.0-dev"); return }
        var args = arguments
        let command = args.first.map { $0.hasPrefix("-") ? "foreground" : $0 } ?? "foreground"
        if command != "foreground" { args.removeFirst() }
        switch command {
        case "status":
            guard args.isEmpty || args == ["--json"] else { throw SettingsError.invalid("usage: nightr status [--json]") }
            do { try printResponse(ControllerClient().request(ControllerRequest(command: .status)), json: args == ["--json"]) }
            catch {
                let message = "Nightr status unavailable: \(error.localizedDescription)"
                if args == ["--json"] {
                    let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
                    print(String(decoding: try encoder.encode(ControllerResponse(error: message)), as: UTF8.self))
                } else { print(message) }
            }
        case "inference":
            try await inferenceProducer(args)
        case "stop":
            guard args.isEmpty else { throw SettingsError.invalid("usage: nightr stop") }
            if let status = try await StopRecovery.stop() {
                try printResponse(ControllerResponse(status: status))
            } else { print("Nightr Off | stopped") }
        case "start", "foreground":
            let settings = try CLIOptions.applying(args, to: SettingsStore().load())
#if os(macOS)
            if command == "start" {
                try await ensureController()
                try printResponse(ControllerClient().request(ControllerRequest(command: .start, settings: settings)))
            } else {
                try await foreground(settings: settings)
            }
#else
            throw IPCError.invalid("monitoring is available on macOS 13 or later")
#endif
        case "config":
            guard args.isEmpty || args == ["--show"] || args == ["--edit"] else { throw SettingsError.invalid("usage: nightr config [--show|--edit]") }
            if args == ["--show"] {
                let settings = try SettingsStore().load()
                let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                print(String(decoding: try encoder.encode(settings), as: UTF8.self)); return
            }
            try bundledPython(script: "nosleep_config.py", args: ["config"] + args)
        case "setup":
            guard args.isEmpty || args == ["--check"] || args == ["--cli-only"] || args == ["--direct-updates"] else { throw SettingsError.invalid("usage: nightr setup [--check|--cli-only|--direct-updates]") }
#if os(macOS)
            if args == ["--check"] {
                let sample = await MacControllerPlatform().sample()
                print(sample.setupReady ? "Nightr setup is ready." : "Nightr setup needs attention. Run `nightr setup` to authorize the power helper.")
                if !sample.setupReady { exit(1) }
            } else if args == ["--direct-updates"] { try bundledPython(script: "nightr_install.py", args: ["adopt-direct"]) }
            else if args == ["--cli-only"] { try launchApp(arguments: ["--setup-helper-only"], wait: true) }
            else { try await openSettings(.general) }
#else
            throw IPCError.invalid("setup is available on macOS 13 or later")
#endif
        case "hotspot":
#if os(macOS)
            if args == ["setup"] { try await openSettings(.connectivity) }
            else if args.count == 3 && args[0] == "setup" && args[1] == "--ssid" {
                try saveHotspotPassword(ssid: args[2])
            } else { throw SettingsError.invalid("usage: nightr hotspot setup [--ssid WIFI-NAME]") }
#else
            throw IPCError.invalid("hotspot setup requires macOS")
#endif
        case "update":
            guard args.isEmpty || args == ["--check"] else { throw SettingsError.invalid("usage: nightr update [--check]") }
            try bundledPython(script: "nightr_install.py", args: args.isEmpty ? ["update"] : ["check"])
        case "package":
            guard args.count == 1 else { throw IPCError.invalid("invalid internal package request") }
            switch args[0] {
            case "prepare-update":
                do {
                    let response = try ControllerClient().request(ControllerRequest(command: .prepareUpdate))
                    if let error = response.error { throw IPCError.invalid(error) }
                } catch { try OfflineController.assertQuiescent() }
                // Acquiring the same lock proves controller effects and ownership are quiescent.
                let lock = try RuntimeOwnership(directory: NightrPaths.runtime, globalLockDirectory: nil); withExtendedLifetime(lock) {}
            case "finish-update":
#if os(macOS)
                try await ensureController()
#else
                throw IPCError.invalid("macOS required")
#endif
            default: throw IPCError.invalid("invalid internal package request")
            }
        default: throw SettingsError.invalid("unknown command: \(command). Run `nightr --help`.")
        }
    }
    /// Explicit integration producer. No controller launch, power command, probe,
    /// prompt content, path, or caller-selected expiry is accepted.
    static func inferenceProducer(_ arguments: [String]) async throws {
        var arguments = arguments
        let processing = arguments.last == "--processing"
        if processing { arguments.removeLast() }
        guard arguments.count == 4, arguments[0] == "--runtime", arguments[2] == "--model",
              let runtime = LocalRuntime(rawValue: arguments[1]) else {
            throw IPCError.invalid("usage: nightr inference --runtime ollama|lm-studio|llama.cpp|mlx --model ID [--processing]")
        }
        let metadata = InferenceMetadata(runtime: runtime, model: arguments[3], activity: processing ? .processing : .generating)
        try metadata.validate()
        let producerParent = getppid()
        guard producerParent > 1 else { throw IPCError.invalid("inference producer requires a live parent process") }
        let client = ControllerClient()
        let stop = ForegroundStopSignal()
        signal(SIGINT, SIG_IGN); signal(SIGTERM, SIG_IGN)
        let sources = [SIGINT, SIGTERM].map { number -> DispatchSourceSignal in
            let source = DispatchSource.makeSignalSource(signal: number, queue: .global())
            source.setEventHandler { stop.request() }; source.resume(); return source
        }
        defer { sources.forEach { $0.cancel() }; stop.finish() }
        let begun = try client.request(.init(command: .inferenceBegin, inference: metadata))
        if let error = begun.error { throw IPCError.invalid(error) }
        guard let token = begun.inferenceToken else { throw IPCError.invalid("controller returned no inference token") }
        defer { _ = try? client.request(.init(command: .inferenceEnd, inferenceToken: token)) }
        var elapsed = 0
        while !stop.requested && getppid() == producerParent {
            try await Task.sleep(nanoseconds: 1_000_000_000)
            elapsed += 1
            if elapsed == 5 && !stop.requested && getppid() == producerParent {
                let response = try client.request(.init(command: .inferenceHeartbeat, inferenceToken: token))
                if let error = response.error { throw IPCError.invalid(error) }
                elapsed = 0
            }
        }
    }
    static func printResponse(_ response: ControllerResponse, json: Bool = false) throws {
        if let error = response.error { throw IPCError.invalid(error) }
        if json { let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]; print(String(decoding: try encoder.encode(response), as: UTF8.self)); return }
        guard let status = response.status else { throw IPCError.invalid("controller returned no status") }
        print(ForegroundStatus.lines(status).joined(separator: "\n"))
    }
    static func bundledPython(script: String, args: [String]) throws {
        let python = resources.appendingPathComponent("runtime/bin/python3")
        let source = resources.appendingPathComponent("libexec/" + script)
        guard FileManager.default.isExecutableFile(atPath: python.path), FileManager.default.fileExists(atPath: source.path) else {
            throw IPCError.invalid("bundled runtime is missing; repair the canonical Nightr installation")
        }
        let process = Process(); process.executableURL = python; process.arguments = [source.path] + args
        try process.run(); process.waitUntilExit()
        if process.terminationStatus != 0 { exit(process.terminationStatus) }
    }
#if os(macOS)
    static func saveHotspotPassword(ssid: String) throws {
        try Settings.validateSSID(ssid)
        guard isatty(STDIN_FILENO) == 1, isatty(STDOUT_FILENO) == 1 else {
            throw IPCError.invalid("open hotspot setup in an unlocked Mac terminal")
        }
        guard let secret = getpass("Hotspot password (saved privately in Keychain): ") else {
            throw IPCError.invalid("password entry was cancelled; configuration unchanged")
        }
        let count = strlen(secret)
        defer { for index in 0..<count { secret[index] = 0 } }
        guard count > 0 else { throw IPCError.invalid("password is empty; configuration unchanged") }
        var password = Data(bytes: secret, count: count)
        defer { password.resetBytes(in: 0..<password.count) }
        guard String(data: password, encoding: .utf8) != nil else { throw IPCError.invalid("password must be valid UTF-8") }
        try KeychainCredentials().write(ssid: ssid, password: password)
        print("Hotspot password saved in Keychain.")
    }
    @MainActor static func openSettings(_ route: GUISettingsRoute) async throws {
        let app = URL(fileURLWithPath: "/Applications/Nightr.app", isDirectory: true)
        guard FileManager.default.isExecutableFile(atPath: app.appendingPathComponent("Contents/MacOS/NightrApp").path) else {
            throw IPCError.invalid("Nightr app is missing; repair the canonical installation")
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.arguments = GUIStartupMode.settingsArguments
        configuration.createsNewApplicationInstance = false
        configuration.allowsRunningApplicationSubstitution = false
        let running = try await NSWorkspace.shared.openApplication(at: app, configuration: configuration)
        try await GUISettingsAcknowledgement.wait(route: route, targetPID: running.processIdentifier)
    }
    static func launchApp(arguments: [String], wait: Bool = false) throws {
        let app = executable.deletingLastPathComponent().appendingPathComponent("NightrApp")
        guard FileManager.default.isExecutableFile(atPath: app.path) else { throw IPCError.invalid("Nightr app is missing; repair the installation") }
        let process = Process(); process.executableURL = app; process.arguments = arguments
        process.standardInput = FileHandle.nullDevice; process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        try process.run()
        if wait {
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { throw IPCError.invalid("helper setup needs authorization in System Settings; reopen Nightr setup") }
        }
    }
    static func ensureController() async throws {
        if (try? ControllerClient().request(ControllerRequest(command: .status))) != nil { return }
        try launchApp(arguments: ["--controller-only"])
        for _ in 0..<50 {
            if (try? ControllerClient().request(ControllerRequest(command: .status))) != nil { return }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        throw IPCError.invalid("controller did not become ready; open Nightr and run setup")
    }
    static func foreground(settings: Settings) async throws {
        // Capture termination before acquiring ownership or sending Start. The stream
        // buffers an early signal until setup reaches its cleanup path.
        let stopSignal = ForegroundStopSignal()
        let interrupt = DispatchSource.makeSignalSource(signal: SIGINT, queue: .global())
        let terminate = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .global())
        interrupt.setEventHandler { stopSignal.request() }
        terminate.setEventHandler { stopSignal.request() }
        let oldInterrupt = signal(SIGINT, SIG_IGN)
        let oldTerminate = signal(SIGTERM, SIG_IGN)
        interrupt.resume(); terminate.resume()
        defer {
            interrupt.cancel(); terminate.cancel(); stopSignal.finish()
            signal(SIGINT, oldInterrupt); signal(SIGTERM, oldTerminate)
        }
        var service: ControllerService?
        var events: MacSystemEvents?
        var refresh: Task<Void, Never>?
        var stopAttempted = false
        let isTTY = isatty(STDOUT_FILENO) == 1
        let noColor = ProcessInfo.processInfo.environment["NO_COLOR"] != nil
        var initialOutput = ForegroundStatusOutput(isTTY: isTTY, noColor: noColor)
        // The cursor can only be hidden by a refresh; restoring it is harmless on
        // every failure path and never emits ANSI to redirected or NO_COLOR output.
        defer { if isTTY && !noColor { FileHandle.standardOutput.write(Data("\u{1B}[?25h".utf8)) } }
        do {
            if !stopSignal.requested {
                do {
                    let response = try ControllerClient().request(.init(command: .status))
                    if let error = response.error { throw IPCError.invalid(error) }
                } catch is ControllerUnavailableError {
                    if !stopSignal.requested {
                        let owner = try ControllerService(platform: MacControllerPlatform())
                        service = owner
                        try await owner.start()
                    }
                }
            }
            if let response = try stopSignal.startIfPending({
                try ControllerClient().request(.init(command: .start, settings: settings))
            }) {
                if let error = response.error { throw IPCError.invalid(error) }
                guard response.status != nil else { throw IPCError.invalid("controller returned no status") }
                if let output = initialOutput.render(ForegroundStatus.snapshot(response, includeMetrics: initialOutput.interactive)) {
                    FileHandle.standardOutput.write(Data(output.utf8))
                }
                if let service {
                    events = await MainActor.run { MacSystemEvents { event in Task { await service.send(event) } } }
                }
                if !initialOutput.interactive { print("Ctrl-C stops protection.") }
                let output = initialOutput
                refresh = Task {
                    var renderer = output
                    while !Task.isCancelled {
                        do { try await Task.sleep(nanoseconds: 1_000_000_000) } catch { return }
                        guard !Task.isCancelled else { return }
                        let snapshot: String
                        do { snapshot = ForegroundStatus.snapshot(try ControllerClient().request(.init(command: .status)), includeMetrics: renderer.interactive) }
                        catch { snapshot = "Nightr status unavailable: \(error.localizedDescription)" }
                        guard !Task.isCancelled else { return }
                        if let text = renderer.render(snapshot) { FileHandle.standardOutput.write(Data(text.utf8)) }
                    }
                }
                for await _ in stopSignal.events { break }
            }
            refresh?.cancel(); await refresh?.value; refresh = nil
            // An update may have replaced our owner. Stop the current endpoint,
            // then release only our obsolete service without rewriting its intent.
            stopAttempted = true
            let stopped = try await StopRecovery.stop()
            await service?.shutdown(preserveIntent: true)
            withExtendedLifetime(events) {}
            if let stopped { try printResponse(.init(status: stopped)) }
            else { print("Nightr Off | stopped") }
        } catch {
            refresh?.cancel(); await refresh?.value
            // Cleanup is independent from authoritative Stop and must run even if
            // the new endpoint rejects Stop or the durable journal cannot be saved.
            var failure = error
            if stopSignal.requiresStopOnFailure && !stopAttempted {
                do { _ = try await StopRecovery.stop() } catch { failure = error }
            }
            await service?.shutdown(preserveIntent: true)
            withExtendedLifetime(events) {}
            throw failure
        }
    }
#endif
}

#if os(macOS)
/// DNC delivery needs the main executor to remain available. Suspend between
/// attempts rather than synchronously pumping its run loop. Observe before posting.
@MainActor private final class GUISettingsAcknowledgement: NSObject {
    private let center = DistributedNotificationCenter.default()
    private let target: String
    private var delivery: GUISettingsDelivery
    private init(route: GUISettingsRoute, targetPID: Int32) {
        target = String(targetPID)
        delivery = GUISettingsDelivery(request: GUISettingsRequest(route: route), now: ProcessInfo.processInfo.systemUptime)
        super.init()
        center.addObserver(self, selector: #selector(receive(_:)), name: Notification.Name(GUISettingsRequest.acknowledgementName),
                           object: target, suspensionBehavior: .deliverImmediately)
    }
    @objc private func receive(_ notification: Notification) {
        guard notification.object as? String == target,
              let response = GUISettingsRequest(userInfo: notification.userInfo) else { return }
        delivery.acknowledge(response)
    }
    private func run() async throws {
        defer { center.removeObserver(self) }
        while true {
            try Task.checkCancellation()
            switch delivery.next(now: ProcessInfo.processInfo.systemUptime) {
            case .acknowledged: return
            case .expired: throw IPCError.invalid("Nightr did not acknowledge Settings; try again or open the app manually")
            case .post:
                center.postNotificationName(Notification.Name(GUISettingsRequest.requestName), object: target,
                                            userInfo: delivery.request.userInfo, options: [.deliverImmediately])
            case .wait: break
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
    }
    static func wait(route: GUISettingsRoute, targetPID: Int32) async throws {
        try await GUISettingsAcknowledgement(route: route, targetPID: targetPID).run()
    }
}
#endif

enum MCPProduction {
    static func setupStatus() async -> MCPToolResult {
#if os(macOS)
        guard let team = signedTeam(), let client = try? SignedPowerClient(teamID: team) else { return setupUnknown }
        defer { client.invalidate() }
        // status is bounded by SignedPowerClient. No sample(), activity collection,
        // display actions, authorization, helper installation or power lease.
        let reply = try? await withCheckedThrowingContinuation { continuation in client.status { continuation.resume(with: $0) } }
        guard let reply else { return setupUnknown }
        return .init(reply.restorationBlocked ? "Power helper restoration needs attention." : "Signed power helper is ready. No protection was started.",
                     data: ["scope": .string("shared_per_user"), "helperReadiness": .string(reply.restorationBlocked ? "needs_attention" : "ready"),
                            "restorationBlocked": .bool(reply.restorationBlocked), "guidance": .string("Use nightr setup for explicit machine setup and authorization.")])
#else
        return .init("Nightr protection requires macOS 13 or later.", data: ["scope": .string("shared_per_user"), "helperReadiness": .string("unsupported"), "guidance": .string("Use Nightr on a supported Mac. No setup or protection was started.")])
#endif
    }
    private static var setupUnknown: MCPToolResult {
        .init("Signed power helper readiness is unknown. No setup or protection was started.", data: ["scope": .string("shared_per_user"), "helperReadiness": .string("unknown"), "guidance": .string("Nightr requires macOS 13 or later and a signed canonical installation. Run nightr setup explicitly to repair readiness.")])
    }
    static func launchController() async throws {
#if os(macOS)
        // Only explicit Start reaches this path. Never execute adjacent worktree code.
        let app = URL(fileURLWithPath: "/Applications/Nightr.app")
        let binary = app.appendingPathComponent("Contents/MacOS/NightrApp")
        for path in [app, app.appendingPathComponent("Contents"), app.appendingPathComponent("Contents/MacOS"), binary] {
            var info = stat()
            guard lstat(path.path, &info) == 0, info.st_uid == 0, info.st_mode & 0o022 == 0,
                  info.st_mode & S_IFMT != S_IFLNK else { throw IPCError.invalid("unsafe canonical controller path") }
        }
        let team = signedTeam()
        guard let team else { throw IPCError.invalid("signed canonical controller required") }
        var code: SecStaticCode?
        let expression = try SigningPolicy.requirement(teamID: team, identifiers: ["ai.nightr.app"])
        var requirement: SecRequirement?
        guard SecStaticCodeCreateWithPath(app as CFURL, [], &code) == errSecSuccess, let code,
              SecRequirementCreateWithString(expression as CFString, [], &requirement) == errSecSuccess,
              SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSStrictValidate | kSecCSCheckAllArchitectures), requirement) == errSecSuccess,
              FileManager.default.isExecutableFile(atPath: binary.path) else { throw IPCError.invalid("canonical controller signature is invalid") }
        let process = Process(); process.executableURL = binary; process.arguments = ["--controller-only"]
        process.standardInput = FileHandle.nullDevice; process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        try process.run()
        for _ in 0..<50 {
            try Task.checkCancellation()
            do {
                let response = try ControllerClient().request(.init(command: .status))
                guard response.error == nil, response.status != nil else { throw IPCError.invalid("controller status unavailable") }
                return
            } catch is ControllerUnavailableError { /* Only absence permits waiting. */ }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        throw IPCError.invalid("controller did not become ready")
#else
        throw IPCError.invalid("monitoring requires macOS 13 or later")
#endif
    }
#if os(macOS)
    private static func signedTeam() -> String? {
        var code: SecCode?, staticCode: SecStaticCode?, info: CFDictionary?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code,
              SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode,
              SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let values = info as? [String: Any],
              let identifier = values[kSecCodeInfoIdentifier as String] as? String,
              ["ai.nightr.controller", "ai.nightr.app"].contains(identifier),
              let team = values[kSecCodeInfoTeamIdentifier as String] as? String,
              let expression = try? SigningPolicy.requirement(teamID: team, identifiers: [identifier]) else { return nil }
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(expression as CFString, [], &requirement) == errSecSuccess,
              SecCodeCheckValidity(code, [], requirement) == errSecSuccess else { return nil }
        return team
    }
#endif
}
