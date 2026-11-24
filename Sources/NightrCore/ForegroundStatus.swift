import Foundation

/// Only visible observations form the snapshot. Polling timestamps never cause output.
public enum ForegroundStatus {
    public static func lines(_ status: ControllerStatus, includeMetrics: Bool = true) -> [String] {
        let label = status.holding ? "On" : status.state.desiredEnabled ? "Paused" : "Off"
        var result = ["Nightr \(label)" + (status.state.pause.map { " | \($0.rawValue)" } ?? "")]
        result.append("Agent: \(status.forceMode == true ? "checks paused" : status.sample.agentObservation?.rawValue ?? (status.sample.agentActive ? "active" : "idle")) | Internet: \(status.state.internet.rawValue)")
        let battery = status.sample.batteryPercent.map { "\($0)%" } ?? "unknown"
        result.append("Power: \(status.sample.onBattery ? "battery" : "AC") | Battery: \(battery) | Lid: \(status.sample.lidClosed ? "closed" : "open")")
        if let activity = status.sample.activity {
            if includeMetrics {
                result.append("CPU: \(activity.cpuPercent.map { "\($0)%" } ?? "unknown") | GPU: \(activity.gpuPercent.map { "\($0)%" } ?? "unknown")")
            }
            for runtime in activity.runtimes {
                let models = runtime.models.map { model in
                    let fresh = runtime.isFresh(at: Date())
                    let observedActivity = fresh ? model.observedActivity(at: Date()) : .unknown
                    var detail = "\(model.displayName) (\(fresh ? model.residency.rawValue : "unknown"), \(observedActivity.rawValue))"
                    if includeMetrics && fresh {
                        if observedActivity.isInference, let startedAt = model.startedAt { detail += " elapsed \(max(0, Int(Date().timeIntervalSince(startedAt))))s" }
                        if let context = model.contextTokens { detail += " context \(context)" }
                        if let memory = model.memoryBytes { detail += " memory \(memory) bytes" }
                        if observedActivity.isInference, let speed = model.tokensPerSecond { detail += " \(String(format: "%.1f", speed)) tokens/s" }
                    }
                    return detail
                }.joined(separator: "; ")
                result.append("\(runtime.runtime.displayName)" + (runtime.version.map { " \($0)" } ?? "") + ": " + (models.isEmpty ? "no models observed" : models))
            }
        }
        if let outage = status.state.outage {
            result.append("Hotspot: \(outage.consumed) of \(outage.capturedLimit) total attempts used | " + (status.verificationEligible ? "still checking internet" : "checks paused"))
        }
        if let message = status.message { result.append(message) }
        return result
    }
    public static func snapshot(_ response: ControllerResponse, includeMetrics: Bool = true) -> String {
        if let error = response.error { return "Nightr status unavailable: \(error)" }
        guard let status = response.status else { return "Nightr status unavailable: controller returned no status" }
        return lines(status, includeMetrics: includeMetrics).joined(separator: "\n")
    }
}

/// Start may have reached the owner even though its reply was lost or invalid.
/// Endpoint and peer preflight failures are kept separate from this uncertainty.
public struct ControllerStartUncertainError: Error, LocalizedError, Sendable {
    public let message: String
    public init(message: String) { self.message = message }
    public var errorDescription: String? { message }
}

/// A signal before acquisition or while waiting for Start is retained for cleanup.
public final class ForegroundStopSignal: @unchecked Sendable {
    private let lock = NSLock()
    private var stopped = false
    private var uncertainStart = false
    public let events: AsyncStream<Void>
    private let continuation: AsyncStream<Void>.Continuation
    public init() {
        var captured: AsyncStream<Void>.Continuation!
        events = AsyncStream(bufferingPolicy: .bufferingNewest(1)) { captured = $0 }
        continuation = captured
    }
    public var requested: Bool { lock.lock(); defer { lock.unlock() }; return stopped }
    public var requiresStopOnFailure: Bool {
        lock.lock(); defer { lock.unlock() }; return stopped || uncertainStart
    }
    private func markUncertainStart() { lock.lock(); uncertainStart = true; lock.unlock() }
    public func request() {
        lock.lock(); stopped = true; lock.unlock()
        continuation.yield(())
    }
    /// Call immediately before the synchronous Start transport, after any awaited
    /// acquisition. A buffered signal makes that delayed Start a no-op.
    public func startIfPending(_ start: () throws -> ControllerResponse) rethrows -> ControllerResponse? {
        guard !requested else { return nil }
        do {
            let response = try start()
            if response.error == nil && response.status == nil { markUncertainStart() }
            return response
        } catch let error as ControllerStartUncertainError {
            markUncertainStart()
            throw error
        }
    }
    public func finish() { continuation.finish() }
}

/// Redirected output reports only changed snapshots, including outage and recovery.
public struct ForegroundStatusOutput: Sendable {
    public let interactive: Bool
    private var previous: String?
    private var rendered = false
    public init(isTTY: Bool, noColor: Bool) { interactive = isTTY && !noColor }
    public mutating func render(_ snapshot: String) -> String? {
        guard snapshot != previous else { return nil }
        previous = snapshot
        if interactive {
            let prefix = rendered ? "\u{1B}[H\u{1B}[2J" : "\u{1B}[?25l\u{1B}[H\u{1B}[2J"
            rendered = true
            return prefix + colored(snapshot) + "\n\n\u{1B}[2mCtrl-C stops protection.\u{1B}[0m\n"
        }
        return snapshot + "\n"
    }
    private func colored(_ snapshot: String) -> String {
        let reset = "\u{1B}[0m", cyan = "\u{1B}[36m", green = "\u{1B}[32m", amber = "\u{1B}[33m", red = "\u{1B}[31m", muted = "\u{1B}[2m"
        return snapshot.split(separator: "\n", omittingEmptySubsequences: false).enumerated().map { index, value in
            let line = String(value)
            if index == 0 {
                if line.hasPrefix("Nightr status unavailable:") { return red + line + reset }
                let color = line.hasPrefix("Nightr On") ? green : line.hasPrefix("Nightr Paused") ? amber : muted
                return cyan + "Nightr" + reset + color + String(line.dropFirst("Nightr".count)) + reset
            }
            if line.hasPrefix("Agent:") || line.hasPrefix("Power:") {
                let sections = line.components(separatedBy: " | ")
                return sections.map { section in
                    guard let colon = section.firstIndex(of: ":") else { return section }
                    let heading = String(section[...colon]), detail = String(section[section.index(after: colon)...])
                    let color = detail == " verified" || detail == " active" ? green : detail == " checking" || detail == " stale" || detail == " unavailable" ? amber : reset
                    return cyan + heading + reset + color + detail + reset
                }.joined(separator: " | ")
            }
            if line.hasPrefix("Hotspot:") { return cyan + "Hotspot:" + reset + amber + String(line.dropFirst("Hotspot:".count)) + reset }
            return muted + line + reset
        }.joined(separator: "\n")
    }
    public var restoration: String { interactive && rendered ? "\u{1B}[?25h" : "" }
}
