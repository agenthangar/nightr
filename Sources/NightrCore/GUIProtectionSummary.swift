import Foundation

/// The desktop shows observed protection separately from enabled intent.
public struct GUIProtectionSummary {
    public let label: String
    public let symbol: String
    public let detail: String
    public let internet: String
    public init(status: ControllerStatus?, error: String? = nil) {
        switch status?.state.internet {
        case .verified: internet = "Verified"
        case .checking: internet = "Checking…"
        case .unavailable: internet = "Unavailable"
        case .stale: internet = "Stale observation"
        case .unknown, nil: internet = "Not checked"
        }
        guard let status else {
            label = "Error"; symbol = "exclamationmark.triangle"
            detail = "Controller status is unavailable."; return
        }
        if error != nil || status.state.pause.map({ [PauseReason.setup, .ownership, .crashLimit].contains($0) }) == true {
            label = "Error"; symbol = "exclamationmark.triangle"; detail = "Protection needs attention. Review the details below."
        } else if status.holding {
            label = "On"; symbol = "checkmark.circle.fill"
            if status.settings.localInference && !status.settings.forever && status.sample.activity?.hasActiveInference(at: Date()) == true {
                detail = "Local inference is keeping your Mac awake."
            } else if status.sample.agentObservation == .checking {
                detail = "Your Mac is being kept awake while agent activity is checked."
            } else { detail = "Your Mac is being kept awake." }
        } else if !status.state.desiredEnabled {
            label = "Off"; symbol = "minus.circle"; detail = "Protection is stopped. Start when you’re ready."
        } else if status.state.internet == .checking {
            label = "Recovering"; symbol = "arrow.clockwise"; detail = "Checking internet before protection can resume."
        } else {
            label = "Paused"; symbol = "pause.circle"
            switch status.state.pause {
            case .battery: detail = "Battery is below your cutoff. Plug in or recharge to resume."
            case .asleep, .maintenanceWake: detail = "Your Mac is asleep. Checks are paused."
            case .loginOptOut: detail = "Login resume is disabled. Start to enable protection."
            case .inactivity: detail = "No agent activity observed. Waiting for normal wake."
            case .connectivity: detail = "Waiting for verified internet."
            default: detail = "Protection is enabled and waiting for its conditions."
            }
        }
    }
}
