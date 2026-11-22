import Foundation

public enum SettingsError: Error, LocalizedError {
    case invalid(String)
    public var errorDescription: String? { if case .invalid(let text) = self { return text }; return nil }
}

public enum Requirement: Codable, Equatable, Sendable {
    case all, none, count(Int)
    public init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer()
        if let text = try? value.decode(String.self) {
            switch text { case "all": self = .all; case "none": self = .none
            default: throw SettingsError.invalid("requirement must be all, none, or a positive integer") }
        } else {
            let count = try value.decode(Int.self)
            guard count > 0 else { throw SettingsError.invalid("requirement must be positive") }
            self = .count(count)
        }
    }
    public func encode(to encoder: Encoder) throws {
        var value = encoder.singleValueContainer()
        switch self { case .all: try value.encode("all"); case .none: try value.encode("none"); case .count(let n): try value.encode(n) }
    }
}

/// JSON keys and defaults intentionally retain the released nosleep schema.
public struct Settings: Codable, Equatable, Sendable {
    public var dim = false
    public var displayOn = false
    public var lock = true
    public var forever = false
    public var agent = true
    public var internet = true
    public var localInference = false
    public var requirement: Requirement = .all
    public var grace = 900
    public var every = 30
    public var retries = 3
    public var backoff = 30
    public var hotspot = false
    public var hotspotSSID = ""
    public var hotspotAfter = 300
    public var hotspotTimeout = 30
    public var hotspotAttempts = 3
    public var batteryProtection = false
    public var batteryBelow = 20
    // Retained if imported; the app deliberately does not invent activity-timer semantics.
    public var inactivity: Int?
    public var launchAtLogin = true
    public init() {}
    enum CodingKeys: String, CodingKey, CaseIterable {
        case localInference = "local_inference"
        case dim, displayOn = "display_on", lock, forever, agent, internet, requirement, grace, every, retries, backoff, hotspot
        case hotspotSSID = "hotspot_ssid", hotspotAfter = "hotspot_after", hotspotTimeout = "hotspot_timeout", hotspotAttempts = "hotspot_attempts"
        case batteryProtection = "battery_protection", batteryBelow = "battery_below", inactivity, launchAtLogin = "launch_at_login"
    }
    public init(from decoder: Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let all = try decoder.container(keyedBy: AnyKey.self)
        let accepted = Set(CodingKeys.allCases.map(\.rawValue))
        if let unknown = all.allKeys.first(where: { !accepted.contains($0.stringValue) }) {
            throw SettingsError.invalid("unknown setting: \(unknown.stringValue)")
        }
        dim = c.contains(.dim) ? try c.decode(Bool.self, forKey: .dim) : dim
        displayOn = c.contains(.displayOn) ? try c.decode(Bool.self, forKey: .displayOn) : displayOn
        lock = c.contains(.lock) ? try c.decode(Bool.self, forKey: .lock) : lock
        forever = c.contains(.forever) ? try c.decode(Bool.self, forKey: .forever) : forever
        agent = c.contains(.agent) ? try c.decode(Bool.self, forKey: .agent) : agent
        localInference = c.contains(.localInference) ? try c.decode(Bool.self, forKey: .localInference) : localInference
        internet = c.contains(.internet) ? try c.decode(Bool.self, forKey: .internet) : internet
        requirement = c.contains(.requirement) ? try c.decode(Requirement.self, forKey: .requirement) : requirement
        grace = c.contains(.grace) ? try c.decode(Int.self, forKey: .grace) : grace
        every = c.contains(.every) ? try c.decode(Int.self, forKey: .every) : every
        retries = c.contains(.retries) ? try c.decode(Int.self, forKey: .retries) : retries
        backoff = c.contains(.backoff) ? try c.decode(Int.self, forKey: .backoff) : backoff
        hotspot = c.contains(.hotspot) ? try c.decode(Bool.self, forKey: .hotspot) : hotspot
        hotspotSSID = c.contains(.hotspotSSID) ? try c.decode(String.self, forKey: .hotspotSSID) : hotspotSSID
        hotspotAfter = c.contains(.hotspotAfter) ? try c.decode(Int.self, forKey: .hotspotAfter) : hotspotAfter
        hotspotTimeout = c.contains(.hotspotTimeout) ? try c.decode(Int.self, forKey: .hotspotTimeout) : hotspotTimeout
        hotspotAttempts = c.contains(.hotspotAttempts) ? try c.decode(Int.self, forKey: .hotspotAttempts) : hotspotAttempts
        batteryProtection = c.contains(.batteryProtection) ? try c.decode(Bool.self, forKey: .batteryProtection) : batteryProtection
        batteryBelow = c.contains(.batteryBelow) ? try c.decode(Int.self, forKey: .batteryBelow) : batteryBelow
        inactivity = try c.decodeIfPresent(Int.self, forKey: .inactivity)
        launchAtLogin = c.contains(.launchAtLogin) ? try c.decode(Bool.self, forKey: .launchAtLogin) : launchAtLogin
        try validate()
        displayOn = displayOn || dim
    }
    public func validate() throws {
        for (name, value, low, high) in [("grace",grace,0,Int.max),("every",every,1,Int.max),
            ("retries",retries,0,10),("backoff",backoff,1,300),("hotspot_after",hotspotAfter,0,2147483647),
            ("hotspot_timeout",hotspotTimeout,1,300),("hotspot_attempts",hotspotAttempts,1,10),("battery_below",batteryBelow,1,100)] {
            guard value >= low && value <= high else { throw SettingsError.invalid("\(name) must be an integer \(low)...\(high)") }
        }
        if case .count(let n) = requirement, n < 1 { throw SettingsError.invalid("requirement must be positive") }
        if let inactivity, inactivity < 0 { throw SettingsError.invalid("inactivity must be nonnegative") }
        if hotspot || !hotspotSSID.isEmpty { try Self.validateSSID(hotspotSSID) }
    }
    public static func validateSSID(_ ssid: String) throws {
        guard (1...32).contains(ssid.utf8.count), !ssid.unicodeScalars.contains(where: { $0.properties.generalCategory == .control }) else {
            throw SettingsError.invalid("hotspot_ssid must contain 1–32 UTF-8 bytes without control characters")
        }
    }
    public static func == (lhs: Settings, rhs: Settings) -> Bool {
        // Swift String equality normalizes Unicode; SSID identity must remain exact UTF-8.
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        guard let left = try? encoder.encode(lhs), let right = try? encoder.encode(rhs) else { return false }
        return left == right
    }
    public var monitoring: Bool { !forever && requirement != .none && (agent || internet) }
    public func conditionsPass(agentActive: Bool, internetVerified: Bool) -> Bool {
        guard monitoring else { return true }
        let selected = [(agent, agentActive), (internet, internetVerified)].filter(\.0)
        let passing = selected.filter(\.1).count
        switch requirement { case .all: return passing == selected.count; case .none: return true; case .count(let n): return passing >= n }
    }
}
private struct AnyKey: CodingKey {
    var stringValue: String
    var intValue: Int? { nil }
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { return nil }
}
