import Foundation
import NightrCore
import NightrMCP

/// Whitelists only product state. Never serialize raw IPC/journals or arbitrary errors.
public enum MCPProjection {
    public static func policy(_ s: Settings) -> JSON {
        let requirement: JSON
        switch s.requirement { case .all: requirement = .string("all"); case .none: requirement = .string("none"); case .count(let count): requirement = .integer(count) }
        return .object(["keepAwake": .string(s.forever ? "until_stopped" : "automatic"), "agentCondition": .bool(s.agent), "internetCondition": .bool(s.internet),
                        "requirement": requirement, "display": .string(s.dim ? "dim" : s.displayOn ? "on" : "off"), "lockOnClose": .bool(s.lock),
                        "checkEverySeconds": .integer(s.every), "graceSeconds": .integer(s.grace), "extraConditionRetries": .integer(s.retries), "firstRetryDelaySeconds": .integer(s.backoff),
                        "batteryProtection": .bool(s.batteryProtection), "batteryBelowPercent": .integer(s.batteryBelow), "launchAtLogin": .bool(s.launchAtLogin),
                        "savedHotspotEnabled": .bool(s.hotspot), "hotspotConfigured": .bool(!s.hotspotSSID.isEmpty), "hotspotAfterSeconds": .integer(s.hotspotAfter),
                        "hotspotAttemptTimeoutSeconds": .integer(s.hotspotTimeout), "nextCycleAttemptLimit": .integer(s.hotspotAttempts)])
    }
    public static func status(_ s: ControllerStatus) -> [String: JSON] {
        var data: [String: JSON] = ["scope": .string("shared_per_user"), "controllerAvailability": .string("available"),
                                   "desiredEnabled": .bool(s.state.desiredEnabled), "holding": .bool(s.holding), "pauseReason": s.state.pause.map { .string($0.rawValue) } ?? .null,
                                   "internet": .string(s.state.internet.rawValue), "internetChecksEligible": .bool(s.verificationEligible), "agentActive": .bool(s.sample.agentActive),
                                   "battery": .object(["onBattery": .bool(s.sample.onBattery), "percent": s.sample.batteryPercent.map(JSON.integer) ?? .null]),
                                   "setupReady": .bool(s.sample.setupReady), "activePolicy": policy(s.settings), "controllerReportedIssue": .bool(s.message != nil)]
        if let outage = s.state.outage {
            data["hotspotCycle"] = .object(["capturedAttemptLimit": .integer(outage.capturedLimit), "attemptsConsumed": .integer(outage.consumed),
                                            "attemptsRemaining": .integer(max(0, outage.capturedLimit - outage.consumed)), "skipped": .bool(outage.skipped),
                                            "exhausted": .bool(outage.consumed >= outage.capturedLimit), "repairRequired": outage.repairRequired.map { .string($0.rawValue) } ?? .null,
                                            "internetChecksEligible": .bool(s.verificationEligible)])
        } else { data["hotspotCycle"] = .null }
        return data
    }
}
