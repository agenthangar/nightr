import Foundation
import NightrCore
import NightrController
import NightrMCP

/// The production seam is explicit so protocol and adapter tests need no OS mutations.
public struct MCPControllerOperations: Sendable {
    public var request: @Sendable (ControllerRequest) throws -> ControllerResponse
    public var settings: @Sendable () throws -> Settings
    public var stop: @Sendable () async throws -> ControllerStatus?
    public var launchController: @Sendable () async throws -> Void
    public var setupStatus: @Sendable () async -> MCPToolResult
    public init(request: @escaping @Sendable (ControllerRequest) throws -> ControllerResponse = { try ControllerClient().request($0) },
                settings: @escaping @Sendable () throws -> Settings = { try SettingsStore().load() },
                stop: @escaping @Sendable () async throws -> ControllerStatus? = { try await StopRecovery.stop() },
                launchController: @escaping @Sendable () async throws -> Void,
                setupStatus: @escaping @Sendable () async -> MCPToolResult) {
        self.request = request; self.settings = settings; self.stop = stop; self.launchController = launchController; self.setupStatus = setupStatus
    }
}
public actor MCPControllerBackend: MCPBackend {
    private let operations: MCPControllerOperations
    public init(operations: MCPControllerOperations) { self.operations = operations }
    public func execute(_ tool: MCPTool) async -> MCPToolResult {
        guard !Task.isCancelled else { return cancelled }
        switch tool {
        case .setupStatus: return await operations.setupStatus()
        case .status:
            do { return try statusResult(operations.request(.init(command: .status))) }
            catch is ControllerUnavailableError { return unavailable }
            catch { return readFailed }
        case .config:
            do {
                let settings = try operations.settings(); try settings.validate()
                var data: [String: JSON] = ["scope": .string("shared_per_user"), "savedPolicy": MCPProjection.policy(settings), "savedPolicyApplies": .string("next_run")]
                do {
                    let response = try operations.request(.init(command: .status))
                    if response.error == nil, let status = response.status { data["activePolicy"] = MCPProjection.policy(status.settings); data["controllerAvailability"] = .string("available") }
                    else { data["controllerAvailability"] = .string("unavailable") }
                } catch { data["controllerAvailability"] = .string("unavailable") }
                return .init("Saved defaults apply to the next run. Active policy is separate when available.", data: data)
            } catch { return .failure("invalid_saved_config", "Saved preferences could not be read or validated.", remediation: "Review preferences with nightr config. Stop remains available.") }
        case .stop:
            do {
                // No settings read: invalid or conflicting preferences cannot defeat Stop.
                let status = try await operations.stop()
                if let status { return .init("Shared Off is durably confirmed.", data: MCPProjection.status(status)) }
                return .init("Shared Off is durably saved without a live controller.", data: ["scope": .string("shared_per_user"), "controllerAvailability": .string("unavailable"), "desiredEnabled": .bool(false), "durableStopConfirmed": .bool(true)])
            } catch { return .failure("stop_not_confirmed", "Durable Stop could not be confirmed.", remediation: "Run nightr stop and inspect status; protection may resume.") }
        case .start: return await start()
        case .retryNow, .tryAgain, .skip: return hotspot(tool)
        }
    }
    private func start() async -> MCPToolResult {
        let settings: Settings
        do { settings = try operations.settings(); try settings.validate() }
        catch { return .failure("invalid_saved_config", "Saved preferences could not be read or validated.", remediation: "Review nightr config before explicitly starting again.") }
        do {
            do { _ = try checkedStatus(operations.request(.init(command: .status))) }
            catch is ControllerUnavailableError {
                guard !Task.isCancelled else { return cancelled }
                do { try await operations.launchController() }
                catch { return .failure("mutation_outcome_unknown", "Controller bootstrap was not confirmed; saved enabled intent may have resumed.", remediation: "Read nightr_status or inspect the canonical app. Never automatically repeat Start. Disconnect does not Stop protection.") }
            }
        } catch { return .failure("controller_unavailable", "The shared controller could not be reached safely.", remediation: "Open the canonical Nightr app and run nightr setup. Inspect status before another Start.") }
        guard !Task.isCancelled else { return cancelled }
        do {
            // Exactly one mutation dispatch. Lost replies are never replayed.
            let response = try operations.request(.init(command: .start, settings: settings))
            if response.error != nil { return .failure("start_rejected", "Start was rejected or protection could not be confirmed.", remediation: "Inspect nightr_status for safety/setup state and conflicting active policy. Never assume a hold from enabled intent.") }
            return try statusResult(response, summary: "Start processed. Observed holding and safety state are reported separately from enabled intent.")
        } catch { return uncertain }
    }
    private func hotspot(_ tool: MCPTool) -> MCPToolResult {
        do {
            let status = try checkedStatus(operations.request(.init(command: .status)))
            guard let outage = status.state.outage else { return .failure("no_hotspot_cycle", "There is no captured hotspot outage cycle.", remediation: "Inspect status. Do not start protection solely to create a fallback cycle.") }
            if tool != .skip {
                guard status.verificationEligible, status.settings.hotspot, !status.settings.hotspotSSID.isEmpty else {
                    return .failure("hotspot_paused", "Hotspot recovery is disabled or paused by the running policy or safety state.", remediation: "Inspect status and repair setup, battery or preferences. Retry cannot bypass those guards.")
                }
                guard tool == .tryAgain ? outage.consumed >= outage.capturedLimit : outage.consumed < outage.capturedLimit else {
                    return .failure("hotspot_budget", "This action does not match the captured hotspot budget.", remediation: "Use Retry now only with remaining attempts; Try again requires explicit intent after exhaustion.")
                }
            }
            guard !Task.isCancelled else { return cancelled }
            let command: ControllerCommand = tool == .retryNow ? .retryNow : tool == .tryAgain ? .tryAgain : .skipFallback
            do { return try statusResult(operations.request(.init(command: command)), summary: "Hotspot request processed under the controller's captured budget and safety guards. Association is not verified internet.") }
            catch { return uncertain }
        } catch is ControllerUnavailableError { return unavailable }
        catch { return readFailed }
    }
    private func checkedStatus(_ response: ControllerResponse) throws -> ControllerStatus {
        guard response.error == nil, let status = response.status else { throw IPCError.invalid("status unavailable") }; return status
    }
    private func statusResult(_ response: ControllerResponse, summary: String = "Observed shared per-user protection. Enabled intent alone does not prove a hold.") throws -> MCPToolResult {
        .init(summary, data: MCPProjection.status(try checkedStatus(response)))
    }
    private var unavailable: MCPToolResult { .init("Controller unavailable. Enabled intent and observed holding are unknown; unavailable is not Off.", data: ["scope": .string("shared_per_user"), "controllerAvailability": .string("unavailable"), "desiredEnabled": .null, "holding": .null]) }
    private var readFailed: MCPToolResult { .failure("controller_read_failed", "Controller status could not be read safely.", remediation: "Inspect the canonical Nightr installation; no controller was launched.") }
    private var uncertain: MCPToolResult { .failure("mutation_outcome_unknown", "The mutation may have occurred, but its result could not be confirmed.", remediation: "Read nightr_status. Never automatically repeat Start or hotspot actions. Cancellation and disconnect do not Stop protection.") }
    private var cancelled: MCPToolResult { .failure("cancelled", "Request cancelled before dispatch.", remediation: "Read status if another request may already have changed shared protection.") }
}
