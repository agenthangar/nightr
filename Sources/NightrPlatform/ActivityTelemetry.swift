import Foundation
import CoreFoundation
import NightrCore
#if os(macOS)
import Darwin
import IOKit
#endif

struct CPUTicks: Sendable {
    var user: UInt32
    var system: UInt32
    var idle: UInt32
    var nice: UInt32
}

struct CPULoad: Sendable {
    private var previous: CPUTicks?
    mutating func observe(_ ticks: CPUTicks?) -> Int? {
        guard let ticks else { previous = nil; return nil }
        defer { previous = ticks }
        guard let previous else { return nil }
        let busy = UInt64(ticks.user &- previous.user) + UInt64(ticks.system &- previous.system) + UInt64(ticks.nice &- previous.nice)
        let total = busy + UInt64(ticks.idle &- previous.idle)
        guard total > 0 else { return nil }
        return Int((Double(busy) * 100 / Double(total)).rounded())
    }
}

enum SystemActivityMetrics {
    static func gpuPercentage(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue.isFinite, (0...100).contains(number.doubleValue) else { return nil }
        return Int(number.doubleValue.rounded())
    }
    static func read() -> (CPUTicks?, Int?) {
        #if os(macOS)
        var info = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info>.size / MemoryLayout<integer_t>.size)
        let host = mach_host_self()
        defer { if host != MACH_PORT_NULL { mach_port_deallocate(mach_task_self_, host) } }
        let status = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { host_statistics(host, HOST_CPU_LOAD_INFO, $0, &count) }
        }
        let cpu = status == KERN_SUCCESS ? CPUTicks(user: info.cpu_ticks.0, system: info.cpu_ticks.1,
                                                  idle: info.cpu_ticks.2, nice: info.cpu_ticks.3) : nil
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOAccelerator"), &iterator) == KERN_SUCCESS else { return (cpu, nil) }
        defer { IOObjectRelease(iterator) }
        var percentages: [Int] = []
        for _ in 0..<16 {
            let device = IOIteratorNext(iterator)
            guard device != 0 else { break }
            defer { IOObjectRelease(device) }
            // Some drivers publish this exact device-wide percentage in the
            // IORegistry. No fallback to renderer/tiler, clock, memory, or power:
            // these have different units and unsupported drivers stay unknown.
            let stats = IORegistryEntryCreateCFProperty(device, "PerformanceStatistics" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? [String: Any]
            if let value = gpuPercentage(stats?["Device Utilization %"]) { percentages.append(value) }
        }
        // On multiple GPUs this means the busiest measured device, never a sum.
        return (cpu, percentages.max())
        #else
        return (nil, nil)
        #endif
    }
}

/// Presentation telemetry never runs in the power/controller actor. Snapshot
/// requests return cached data immediately and coalesce a single refresh.
actor ActivityTelemetry {
    private var cache = ActivityObservation()
    private var cpu = CPULoad()
    private var lastStart = Date.distantPast
    private var refreshedAt = Date.distantPast
    private var refreshing = false
    private let runtimeObserver: LocalRuntimeObserver
    private let metrics: @Sendable () -> (CPUTicks?, Int?)
    private let mlxIdentity: @Sendable () -> Bool
    init(runtimeObserver: LocalRuntimeObserver = LocalRuntimeObserver(),
         metrics: @escaping @Sendable () -> (CPUTicks?, Int?) = { SystemActivityMetrics.read() },
         mlxIdentity: @escaping @Sendable () -> Bool = { ActivityTelemetry.verifiedMLXListener() }) {
        self.runtimeObserver = runtimeObserver; self.metrics = metrics; self.mlxIdentity = mlxIdentity
    }
    func snapshot(now: Date = Date()) -> ActivityObservation {
        if !refreshing && now.timeIntervalSince(lastStart) >= 5 {
            refreshing = true; lastStart = now
            let observer = runtimeObserver, metrics = self.metrics, identity = mlxIdentity
            Task {
                let measured = await Task.detached(priority: .utility) { (metrics(), identity()) }.value
                let runtimes = await observer.observe(now: now, mlxListenerVerified: measured.1)
                complete(metrics: measured.0, runtimes: runtimes, now: now)
            }
        }
        let age = now.timeIntervalSince(refreshedAt)
        return ActivityObservation(cpuPercent: (0..<15).contains(age) ? cache.cpuPercent : nil,
                                   gpuPercent: (0..<15).contains(age) ? cache.gpuPercent : nil,
                                   runtimes: Self.retainingRecent(runtimes: [], previous: cache.runtimes, now: now))
    }
    private func complete(metrics: (CPUTicks?, Int?), runtimes: [RuntimeObservation], now: Date) {
        cache = ActivityObservation(cpuPercent: cpu.observe(metrics.0), gpuPercent: metrics.1,
                                    runtimes: Self.retainingRecent(runtimes: runtimes, previous: cache.runtimes, now: now))
        refreshedAt = now; refreshing = false
    }
    static func retainingRecent(runtimes: [RuntimeObservation], previous: [RuntimeObservation], now: Date) -> [RuntimeObservation] {
        LocalRuntime.allCases.compactMap { runtime in
            if let fresh = runtimes.first(where: { $0.runtime == runtime }) { return fresh }
            // A failed probe may retain a brief stale roster, with its original
            // observation time. It cannot refresh inference evidence or residency.
            return previous.first { $0.runtime == runtime && (0..<60).contains(now.timeIntervalSince($0.observedAt)) }
        }
    }
    /// Only an unambiguous executable owning the standard listener permits the
    /// generic MLX model-list API. Python `-m` launches are intentionally unknown:
    /// reading arbitrary command arguments could consume secrets or prompts.
    static func verifiedMLXListener() -> Bool {
        #if os(macOS)
        guard let processes = try? BoundedProcess().run(executable: URL(fileURLWithPath: "/bin/ps"),
                    arguments: ["-Axo", "pid=,ppid=,comm="], timeout: 0.4) else { return false }
        let processText = String(decoding: processes, as: UTF8.self)
        guard AgentActivity.processes(processText).contains(where: { ($0.command as NSString).lastPathComponent == "mlx_lm.server" }),
              let data = try? BoundedProcess().run(executable: URL(fileURLWithPath: "/usr/sbin/lsof"),
                    arguments: ["-nP", "-a", "-iTCP:8080", "-sTCP:LISTEN", "-Fp"], timeout: 0.4) else { return false }
        return mlxListenerVerified(listeners: String(decoding: data, as: UTF8.self), processes: processText)
        #else
        return false
        #endif
    }
    static func mlxListenerVerified(listeners: String, processes: String) -> Bool {
        let pids = Set(listeners.split(separator: "\n").compactMap { $0.first == "p" ? Int($0.dropFirst()) : nil })
        let mlx = Set(AgentActivity.processes(processes).filter { ($0.command as NSString).lastPathComponent == "mlx_lm.server" }.map(\.pid))
        return pids.count == 1 && pids.isSubset(of: mlx)
    }
}

struct AgentProbe: Sendable {
    var processes: String
    var assertions: String
    var network: String
}

actor AgentActivityMonitor {
    typealias Probe = @Sendable () -> AgentProbe?
    private var detector = AgentActivity()
    private var observation: AgentObservation = .checking
    private var refreshedAt = Date.distantPast
    private var lastStart = Date.distantPast
    private var refreshing = false
    private var discardPending = false
    private let probe: Probe
    init(probe: @escaping Probe = { AgentActivityMonitor.read() }) { self.probe = probe }
    func snapshot(enabled: Bool = true, now: Date = Date()) -> AgentObservation {
        guard enabled else {
            // Drop pre-override observations and byte counters before monitoring resumes.
            detector = AgentActivity()
            refreshedAt = .distantPast
            lastStart = .distantPast
            observation = .checking
            discardPending = refreshing
            return .checking
        }
        if !refreshing && now.timeIntervalSince(lastStart) >= 5 {
            refreshing = true; lastStart = now
            let probe = self.probe
            Task {
                let result = await Task.detached(priority: .utility) { probe() }.value
                complete(result, now: now)
            }
        }
        return now.timeIntervalSince(refreshedAt) < 15 ? observation : .checking
    }
    private func complete(_ result: AgentProbe?, now: Date) {
        defer { refreshing = false; discardPending = false }
        guard !discardPending, let result else { return }
        observation = detector.observe(processes: result.processes, assertions: result.assertions, network: result.network, now: now) ? .active : .idle
        refreshedAt = now
    }
    static func read() -> AgentProbe? {
        #if os(macOS)
        func text(_ path: String, _ arguments: [String]) -> String? {
            guard let data = try? BoundedProcess().run(executable: URL(fileURLWithPath: path), arguments: arguments, timeout: 3) else { return nil }
            return String(decoding: data, as: UTF8.self)
        }
        guard let processes = text("/bin/ps", ["-Axo", "pid=,ppid=,comm="]),
              let assertions = text("/usr/bin/pmset", ["-g", "assertions"]) else { return nil }
        let network: String
        if let arguments = AgentActivity.networkSampleArguments(processes: processes) {
            guard let sample = text("/usr/bin/nettop", arguments) else { return nil }
            network = sample
        } else { network = "" }
        return AgentProbe(processes: processes, assertions: assertions, network: network)
        #else
        return nil
        #endif
    }
}
