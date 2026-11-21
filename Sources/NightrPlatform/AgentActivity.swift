import Foundation

/// Mirrors the extracted detector's useful signals: Claude's child assertion,
/// known desktop assertions and per-socket growth. Process existence and CPU do
/// not count as work. All process observations remain in memory.
public struct AgentActivity {
    private var sockets: [String: Int64] = [:]
    private var timestamps: [Int: Date] = [:]
    public init() {}
    public static func isAgent(_ executable: String) -> Bool {
        let base = (executable as NSString).lastPathComponent
        if executable.contains(".app/Contents/") {
            return (executable.contains("/ChatGPT.app/Contents/") && base == "codex") ||
                (executable.contains("/Application Support/Claude/claude-code/") && base == "claude")
        }
        return ["claude", "codex", "cursor-agent"].contains(base) || base.hasPrefix("codex-aarch64-") || base.hasPrefix("codex-x86_64-")
    }
    public static func processes(_ text: String) -> [(pid: Int, parent: Int, command: String)] {
        text.split(separator: "\n").compactMap { line in
            let pieces = line.split(maxSplits: 2, omittingEmptySubsequences: true, whereSeparator: { $0 == " " || $0 == "\t" })
            guard pieces.count == 3, let pid = Int(pieces[0]), let parent = Int(pieces[1]) else { return nil }
            return (pid, parent, String(pieces[2]))
        }
    }
    static func networkSampleArguments(processes: String) -> [String]? {
        let agents = Self.processes(processes).filter { Self.isAgent($0.command) }
        guard !agents.isEmpty else { return nil }
        // nettop rejects more than 20 PID filters. With more agents, take one
        // sample and let observe filter the rows by the same agent PIDs.
        let filters = agents.count <= 20 ? agents.flatMap { ["-p", String($0.pid)] } : []
        return ["-x", "-n", "-s", "1", "-L", "1"] + filters + ["-J", "bytes_in,bytes_out"]
    }
    public mutating func observe(processes: String, assertions: String, network: String, now: Date) -> Bool {
        let rows = Self.processes(processes)
        let agents = Set(rows.filter { Self.isAgent($0.command) }.map(\.pid))
        let claude = Set(rows.filter { ($0.command as NSString).lastPathComponent == "claude" }.map(\.pid))
        var active = rows.contains { ($0.command as NSString).lastPathComponent == "caffeinate" && claude.contains($0.parent) }
        if assertions.range(of: #"pid [0-9]+\((Claude|ChatGPT)\):.*(PreventUserIdleSystemSleep|PreventSystemSleep|NoIdleSleepAssertion) named"#, options: .regularExpression) != nil { active = true }
        var current: Int?
        var nextSockets: [String: Int64] = [:]
        var moved: [Int: Int64] = [:]
        for line in network.split(separator: "\n") {
            let parts = line.split(separator: ",", omittingEmptySubsequences: false)
            guard let first = parts.first else { continue }
            if first.hasPrefix("tcp") || first.hasPrefix("udp") {
                guard let pid = current, parts.count >= 3, let incoming = Int64(parts[1]), let outgoing = Int64(parts[2]),
                      incoming >= 0, outgoing >= 0, incoming <= Int64.max - outgoing else { continue }
                let key = "\(pid) \(first)", bytes = incoming + outgoing
                nextSockets[key] = bytes
                moved[pid, default: 0] += max(0, bytes - (sockets[key] ?? 0))
            } else {
                let pid = first.split(separator: ".").last.flatMap { Int($0) }
                current = pid.flatMap { agents.contains($0) ? $0 : nil }
            }
        }
        for pid in agents {
            guard let previous = timestamps[pid] else { continue }
            let elapsed = max(1, now.timeIntervalSince(previous))
            if Double(moved[pid, default: 0]) >= max(49_152, 1_024 * elapsed) { active = true }
        }
        sockets = nextSockets; timestamps = Dictionary(uniqueKeysWithValues: agents.map { ($0, now) })
        return active
    }
}
