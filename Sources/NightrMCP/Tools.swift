import Foundation

public enum MCPTool: String, CaseIterable, Sendable {
    case status = "nightr_status", config = "nightr_config", setupStatus = "nightr_setup_status"
    case start = "nightr_start", stop = "nightr_stop"
    case retryNow = "nightr_hotspot_retry_now", tryAgain = "nightr_hotspot_try_again", skip = "nightr_hotspot_skip"
    public var readOnly: Bool { [.status, .config, .setupStatus].contains(self) }
    public var description: String {
        switch self {
        case .status: return "Read shared per-user protection, pause, internet, battery and captured hotspot budget. Does not start Nightr. Unavailable is not Off."
        case .config: return "Read saved next-run policy and active policy when available. Does not edit preferences or expose credentials or network names."
        case .setupStatus: return "Read signed helper readiness without authorization, installation, app launch or acquiring a power lease. Unknown requires user setup."
        case .start: return "Explicitly enable shared per-user protection with saved defaults. Can affect other clients. Not idempotent: inspect status after an uncertain result; never automatically repeat. Safety and conflicting-run rules apply."
        case .stop: return "Explicitly persist shared per-user Off and release protection, including when the controller is absent. Affects every client. Does not force sleep."
        case .retryNow: return "Advance a remaining saved-hotspot attempt in the existing captured budget, if eligible. Never adds attempts or bypasses safety. Association does not prove internet."
        case .tryAgain: return "Explicitly begin a new bounded hotspot cycle after exhaustion using running settings, if eligible. Never automatically repeat."
        case .skip: return "Skip the current saved-hotspot fallback cycle. Independent eligible internet checks continue."
        }
    }
    var definition: JSON {
        .object(["name": .string(rawValue), "description": .string(description),
                 "inputSchema": .object(["type": .string("object"), "properties": .object([:]), "additionalProperties": .bool(false)]),
                 "annotations": .object(["readOnlyHint": .bool(readOnly), "destructiveHint": .bool(!readOnly),
                                          "idempotentHint": .bool(readOnly || self == .stop || self == .skip), "openWorldHint": .bool(false)])])
    }
}
public struct MCPToolResult: Sendable {
    public let summary: String
    public let data: [String: JSON]
    public let isError: Bool
    public init(_ summary: String, data: [String: JSON], isError: Bool = false) { self.summary = summary; self.data = data; self.isError = isError }
    public static func failure(_ code: String, _ summary: String, remediation: String) -> Self {
        Self(summary, data: ["code": .string(code), "remediation": .string(remediation)], isError: true)
    }
    var json: JSON { .object(["content": .array([.object(["type": .string("text"), "text": .string(summary)])]), "structuredContent": .object(data), "isError": .bool(isError)]) }
}
public protocol MCPBackend: Sendable {
    func execute(_ tool: MCPTool) async -> MCPToolResult
}
