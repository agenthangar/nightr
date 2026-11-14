import Foundation
import NightrCore
import NightrController
#if os(macOS)
import NightrPlatform
import Darwin
import MachO
#else
import Glibc
#endif

@main struct NightrCLI {
    static let usage = """
    Nightr · keep your Mac awake for coding-agent work
    usage: nightr [legacy options]
           nightr start [options]
           nightr stop
           nightr status [--json]
           nightr setup [--check|--cli-only]
           nightr config [--show|--edit]
           nightr update [--check]

    Without a command, Nightr runs in the foreground; Ctrl-C stops protection.
    start runs the shared background controller. status never starts it.
    config changes defaults for the next run; app Settings apply at a loop boundary.

    Protection: --checks all|agent|internet|none, --require all|none|N
                --forever, --agent/--no-agent, --internet/--no-internet
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
        case "stop":
            guard args.isEmpty else { throw SettingsError.invalid("usage: nightr stop") }
            let client = ControllerClient()
            do { try printResponse(client.request(ControllerRequest(command: .stop))) }
            catch {
                try OfflineController.stop(); print("Nightr Off · stopped")
            }
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
            guard args.isEmpty || args == ["--check"] || args == ["--cli-only"] else { throw SettingsError.invalid("usage: nightr setup [--check|--cli-only]") }
#if os(macOS)
            if args == ["--check"] {
                let sample = await MacControllerPlatform().sample()
                print(sample.setupReady ? "Nightr setup is ready." : "Nightr setup needs attention. Run `nightr setup` to authorize the power helper.")
                if !sample.setupReady { exit(1) }
            } else { try launchApp(arguments: args == ["--cli-only"] ? ["--setup-helper-only"] : ["--setup"], wait: args == ["--cli-only"]) }
#else
            throw IPCError.invalid("setup is available on macOS 13 or later")
#endif
        case "hotspot":
#if os(macOS)
            if args == ["setup"] { try launchApp(arguments: ["--hotspot-setup"]) }
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
    static func printResponse(_ response: ControllerResponse, json: Bool = false) throws {
        if let error = response.error { throw IPCError.invalid(error) }
        if json { let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]; print(String(decoding: try encoder.encode(response), as: UTF8.self)); return }
        guard let status = response.status else { throw IPCError.invalid("controller returned no status") }
        let label = status.holding ? "On" : status.state.desiredEnabled ? "Paused" : "Off"
        print("Nightr \(label)" + (status.state.pause.map { " · \($0.rawValue)" } ?? ""))
        print("Internet: \(status.state.internet.rawValue)")
        if let outage = status.state.outage {
            print("Hotspot: \(outage.consumed) of \(outage.capturedLimit) total attempts used · " + (status.verificationEligible ? "still checking internet" : "checks paused"))
        }
        if let message = status.message { print(message) }
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
        let service: ControllerService?
        if (try? ControllerClient().request(ControllerRequest(command: .status))) != nil { service = nil }
        else {
            let owner = try ControllerService(platform: MacControllerPlatform())
            try await owner.start(); service = owner
        }
        do { try printResponse(ControllerClient().request(ControllerRequest(command: .start, settings: settings))) }
        catch { await service?.shutdown(preserveIntent: true); throw error }
        let events: MacSystemEvents?
        if let service {
            events = await MainActor.run { MacSystemEvents { event in Task { await service.send(event) } } }
        } else { events = nil }
        print("Ctrl-C stops protection.")
        signal(SIGINT, SIG_IGN); signal(SIGTERM, SIG_IGN)
        let stream = AsyncStream<Void> { continuation in
            let interrupt = DispatchSource.makeSignalSource(signal: SIGINT, queue: .global())
            let terminate = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .global())
            interrupt.setEventHandler { continuation.yield(()) }; terminate.setEventHandler { continuation.yield(()) }
            interrupt.resume(); terminate.resume()
            continuation.onTermination = { _ in interrupt.cancel(); terminate.cancel() }
        }
        for await _ in stream { break }
        withExtendedLifetime(events) {}
        if let service { await service.shutdown() }
        else { _ = try ControllerClient().request(ControllerRequest(command: .stop)) }
    }
#endif
}
