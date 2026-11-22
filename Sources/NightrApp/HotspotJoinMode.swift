#if os(macOS)
import Foundation
import SystemConfiguration

enum HotspotJoinMode: String {
    case automatic = "Automatic"
    case ask = "Ask to Join"
    case never = "Never"
    case unknown = "Not checked"

    var symbol: String {
        switch self {
        case .automatic: return "checkmark.square.fill"
        case .ask, .never: return "square"
        case .unknown: return "minus.square"
        }
    }

    init(preference: Any?, supportsAutomatic: Bool) {
        switch preference as? String {
        case "Automatic" where supportsAutomatic: self = .automatic
        case "Ask", "AskToJoin", "Ask to Join": self = .ask
        case "Never": self = .never
        default: self = .unknown
        }
    }

    static func current() -> Self {
        // Open a new read-only snapshot each time the Connectivity pane becomes active.
        guard let preferences = SCPreferencesCreate(nil, "Nightr" as CFString,
                                                    "com.apple.airport.preferences.plist" as CFString) else { return .unknown }
        let value = SCPreferencesGetValue(preferences, "AutoHotspotMode" as CFString)
        if #available(macOS 26, *) { return Self(preference: value, supportsAutomatic: true) }
        return Self(preference: value, supportsAutomatic: false)
    }
}
#endif
