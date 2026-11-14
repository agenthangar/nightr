import Foundation

public struct NetworkSecurityEntry: Codable, Sendable {
    public let ssid: String
    public let security: NetworkSecurity
    public init(ssid: String, security: NetworkSecurity) { self.ssid = ssid; self.security = security }
}

/// Non-secret security classification is independent of password availability.
/// Records are arrays because JSON object keys and Swift String equality must not
/// collapse canonically equivalent but byte-distinct SSIDs.
public struct NetworkSecurityStore: Sendable {
    public let url: URL
    public init(url: URL? = nil) {
        let config = ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"].flatMap { $0.isEmpty ? nil : $0 } ?? NSHomeDirectory() + "/.config"
        self.url = url ?? URL(fileURLWithPath: config).appendingPathComponent("nosleep/network-security.json")
    }
    public func load() throws -> [NetworkSecurityEntry] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        return try JSONDecoder().decode([NetworkSecurityEntry].self, from: Data(contentsOf: url))
    }
    public func security(ssid: String) throws -> NetworkSecurity {
        try load().first { sameSSID($0.ssid, ssid) }?.security ?? .unknown
    }
    public func replacing(ssid: String, security: NetworkSecurity, saveConfiguration: () throws -> Void) throws {
        guard validSSID(ssid), security != .unknown else { try saveConfiguration(); return }
        let previous = try? Data(contentsOf: url)
        var entries = try load().filter { !sameSSID($0.ssid, ssid) }
        entries.append(.init(ssid: ssid, security: security))
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        do {
            try JSONEncoder().encode(entries).write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: NSNumber(value: 0o600)], ofItemAtPath: url.path)
            try saveConfiguration()
        }
        catch {
            do {
                if let previous { try previous.write(to: url, options: .atomic) }
                else { try FileManager.default.removeItem(at: url) }
            } catch { throw CredentialTransactionError.rollbackFailed }
            throw error
        }
    }
}
