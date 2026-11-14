import Foundation

public enum NetworkSecurity: String, Codable, Sendable { case open, password, unknown }
public struct NetworkRecord: Codable, Equatable, Sendable, Identifiable {
    public var ssid: String
    public var signal: Int
    public var security: NetworkSecurity
    public var current: Bool
    public var id: Data { ssidIdentity(ssid) }
    public init(ssid: String, signal: Int = -100, security: NetworkSecurity = .unknown, current: Bool = false) {
        self.ssid = ssid; self.signal = signal; self.security = security; self.current = current
    }
}
public enum DiscoveryState: String, Codable, Sendable {
    case complete, permission, denied, disabled, off, unavailable, failed
}
public struct NetworkObservation: Codable, Sendable {
    public var state: DiscoveryState
    public var networks: [NetworkRecord]
    public var observedAt: Date
    public init(state: DiscoveryState, networks: [NetworkRecord] = [], observedAt: Date = Date()) {
        self.state = state; self.networks = Self.ordered(networks); self.observedAt = observedAt
    }
    public static func ordered(_ records: [NetworkRecord]) -> [NetworkRecord] {
        var unique: [Data: NetworkRecord] = [:]
        for record in records {
            guard validSSID(record.ssid) else { continue }
            if let old = unique[ssidIdentity(record.ssid)], old.current || (!record.current && old.signal >= record.signal) { continue }
            unique[ssidIdentity(record.ssid)] = record
        }
        return unique.values.sorted {
            if $0.current != $1.current { return $0.current }
            if $0.signal != $1.signal { return $0.signal > $1.signal }
            return $0.ssid.utf8.lexicographicallyPrecedes($1.ssid.utf8)
        }
    }
    public func availability(of ssid: String, now: Date = Date()) -> String {
        guard state == .complete, now.timeIntervalSince(observedAt) < 30 else { return "Availability unknown" }
        return networks.contains { sameSSID($0.ssid, ssid) } ? "Seen nearby" : "Not seen"
    }
}

// Swift String is well-formed Unicode; decoding invalid UTF-8 is rejected at the input boundary.
public func ssidIdentity(_ ssid: String) -> Data { Data(ssid.utf8) }
public func sameSSID(_ lhs: String, _ rhs: String) -> Bool { lhs.utf8.elementsEqual(rhs.utf8) }

public func validSSID(_ ssid: String) -> Bool {
    (1...32).contains(ssid.utf8.count) && !ssid.unicodeScalars.contains { $0.properties.generalCategory == .control }
}

public protocol CredentialStore {
    func read(ssid: String) throws -> Data?
    func write(ssid: String, password: Data) throws
    func remove(ssid: String) throws
    func savedSSIDs() throws -> [String]
}

public enum CredentialEdit {
    case unchanged
    case password(ssid: String, data: Data)
    case explicitOpen(ssid: String)
}

public enum CredentialTransactionError: Error, LocalizedError {
    case rollbackFailed
    public var errorDescription: String? { "Settings were not saved. Keychain rollback needs repair before retrying." }
}

// The caller retains an unsaved draft on any failure. Credentials never enter config or IPC.
public struct CredentialTransaction {
    public let store: any CredentialStore
    public init(store: any CredentialStore) { self.store = store }
    public func commit(edit: CredentialEdit, saveConfiguration: () throws -> Void) throws {
        let ssid: String
        switch edit {
        case .unchanged: try saveConfiguration(); return
        case .password(let name, _), .explicitOpen(let name): ssid = name
        }
        let previous = try store.read(ssid: ssid)
        switch edit {
        case .password(_, let data): try store.write(ssid: ssid, password: data)
        case .explicitOpen: try store.remove(ssid: ssid)
        case .unchanged: break
        }
        do { try saveConfiguration() }
        catch {
            do {
                if let previous { try store.write(ssid: ssid, password: previous) }
                else { try store.remove(ssid: ssid) }
            } catch { throw CredentialTransactionError.rollbackFailed }
            throw error
        }
    }
}
