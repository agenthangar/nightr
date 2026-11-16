import Foundation
#if canImport(Darwin)
import Darwin
import Security
#else
import Glibc
#endif
import NightrCore

public enum NightrPaths {
    public static var config: URL {
        let env = ProcessInfo.processInfo.environment
        return URL(fileURLWithPath: env["XDG_CONFIG_HOME"].flatMap { $0.isEmpty ? nil : $0 } ?? NSHomeDirectory() + "/.config")
            .appendingPathComponent("nosleep/config.json")
    }
    public static var globalLocks: URL? {
        // Signed distribution copies participate even if a user moves the executable.
        // Otherwise copying a legitimate signed CLI could bypass update exclusion.
        let directory = URL(fileURLWithPath: "/Library/Application Support/Nightr")
#if canImport(Darwin)
        var code: SecCode?
        var staticCode: SecStaticCode?
        var information: CFDictionary?
        if SecCodeCopySelf([], &code) == errSecSuccess, let code,
           SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode,
           SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess,
           let values = information as? [String: Any],
           let team = values[kSecCodeInfoTeamIdentifier as String] as? String, !team.isEmpty { return directory }
#endif
        // Canonical installation failures also fail closed before helper setup.
        let executable = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL.resolvingSymlinksInPath().path
        return executable.hasPrefix("/Applications/Nightr.app/Contents/MacOS/") ? directory : nil
    }
    public static var runtime: URL {
        URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support/Nightr/runtime")
    }
}
public struct SettingsStore: Sendable {
    public let url: URL
    public init(url: URL = NightrPaths.config) { self.url = url }
    public func load() throws -> Settings {
        guard FileManager.default.fileExists(atPath: url.path) else { return Settings() }
        return try JSONDecoder().decode(Settings.self, from: Data(contentsOf: url))
    }
    /// Optimistic conflict detection preserves existing linked legacy configurations.
    @discardableResult public func save(_ settings: Settings, expected: Data?) throws -> Data {
        try settings.validate()
        let target = url.resolvingSymlinksInPath()
        let current = try? Data(contentsOf: target)
        guard current == expected else { throw SettingsError.invalid("config changed while editing; reopen Settings") }
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let bytes = try encoder.encode(settings)
        let mode = (try? FileManager.default.attributesOfItem(atPath: target.path)[.posixPermissions]) ?? NSNumber(value: 0o600)
        let temporary = target.deletingLastPathComponent().appendingPathComponent(".nightr-config-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: temporary) }
        try bytes.write(to: temporary, options: .withoutOverwriting)
        try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: temporary.path)
        guard (try? Data(contentsOf: target)) == expected, url.resolvingSymlinksInPath() == target else {
            throw SettingsError.invalid("config changed while editing; reopen Settings")
        }
        guard rename(temporary.path, target.path) == 0 else { throw CocoaError(.fileWriteUnknown) }
        return bytes
    }
}
