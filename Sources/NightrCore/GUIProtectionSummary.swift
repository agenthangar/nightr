import Foundation

/// The desktop shows observed protection separately from enabled intent.
public struct GUIProtectionSummary {
    public private(set) var activelyProtecting = false
    public let label: String
    public let symbol: String
    public let detail: String
    public let internet: String
    public let showsActiveAgent: Bool
    public init(status: ControllerStatus?, error: String? = nil) {
        if let status, error == nil, status.forceMode != true, status.state.pause != .asleep, status.state.pause != .maintenanceWake {
            showsActiveAgent = status.sample.agentObservation.map { $0 == .active } ?? status.sample.agentActive
        } else { showsActiveAgent = false }
        if status?.forceMode == true {
            internet = "Checks paused"
        } else {
            switch status?.state.internet {
            case .verified: internet = "Verified"
            case .checking: internet = "Checking…"
            case .unavailable: internet = "Unavailable"
            case .stale: internet = "Stale observation"
            case .unknown: internet = "Not checked"
            case nil: internet = error == nil ? "Checking…" : "Not checked"
            }
        }
        guard let status else {
            if error == nil {
                label = "Checking…"
                symbol = "clock"
                detail = "Checking protection status."
            } else {
                label = "Error"
                symbol = "exclamationmark.triangle"
                detail = "Controller status is unavailable."
            }
            return
        }
        let checkingAgent = status.settings.monitoring && status.settings.agent && status.sample.agentObservation == .checking
        if error != nil || status.state.pause.map({ [PauseReason.setup, .ownership, .crashLimit].contains($0) }) == true {
            label = "Error"; symbol = "exclamationmark.triangle"; detail = "Protection needs attention. Review the details below."
        } else if status.holding {
            activelyProtecting = true
            label = status.forceMode == true ? "Force mode" : "On"
            symbol = status.forceMode == true ? "bolt.circle.fill" : "checkmark.circle.fill"
            if status.forceMode == true { detail = "Automatic checks are paused." }
            else if status.settings.localInference && !status.settings.forever && status.sample.activity?.hasActiveInference(at: Date()) == true {
                detail = "Local inference is keeping your Mac awake."
            } else if checkingAgent {
                detail = "Your Mac is being kept awake while agent activity is checked."
            } else { detail = "Your Mac is being kept awake." }
        } else if !status.state.desiredEnabled {
            label = "Off"; symbol = "minus.circle"; detail = "Protection is stopped. Start when you’re ready."
        } else if status.state.internet == .checking {
            label = "Recovering"; symbol = "arrow.clockwise"; detail = "Checking internet before protection can resume."
        } else if status.state.pause == nil && checkingAgent && status.forceMode != true {
            label = "Checking…"; symbol = "clock"; detail = "Checking for agent activity."
        } else {
            label = "Paused"; symbol = "pause.circle"
            switch status.state.pause {
            case .battery: detail = "Battery is below your cutoff. Plug in or recharge to resume."
            case .asleep, .maintenanceWake: detail = "Your Mac is asleep. Checks are paused."
            case .loginOptOut: detail = "Login resume is disabled. Start to enable protection."
            case .inactivity: detail = "No agent activity observed. Waiting for normal wake."
            case .connectivity: detail = "Waiting for verified internet."
            default: detail = status.settings.requiresLocalInference ? "Waiting for local model activity." : "Protection is enabled and waiting for its conditions."
            }
        }
    }
}

#if os(macOS)
import AppKit

extension MoonSparkArtwork {
    public static func menuImage(for summary: GUIProtectionSummary) -> NSImage {
        if summary.activelyProtecting && summary.symbol == "bolt.circle.fill" {
            return forceMenuImage
        }
        return summary.activelyProtecting ? activeMenuImage : menuImage
    }
    private static let forceMenuImage: NSImage = {
        let image = NSImage(systemSymbolName: "bolt.circle.fill", accessibilityDescription: "Nightr, Force mode")!
        image.isTemplate = true
        return image
    }()
}
#endif
