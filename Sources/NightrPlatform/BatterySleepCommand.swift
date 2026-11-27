import Foundation

/// Shared command mapping exercised without invoking power operations in tests.
enum BatterySleepCommand {
    static func request(
        below cutoff: Int,
        restoration: () async throws -> (active: Bool, blocked: Bool),
        hasLease: () async -> Bool,
        battery: () async -> (onBattery: Bool, percent: Int?),
        execute: (URL, [String], TimeInterval) async throws -> Void
    ) async throws {
        guard !Task.isCancelled else { return }
        let restored = try await restoration()
        guard !Task.isCancelled, restorationAllowsSleep(active: restored.active, blocked: restored.blocked),
              !(await hasLease()) else { return }
        let fresh = await battery()
        guard !Task.isCancelled, shouldSleep(onBattery: fresh.onBattery, percent: fresh.percent, cutoff: cutoff) else { return }
        try await execute(URL(fileURLWithPath: "/usr/bin/pmset"), ["sleepnow"], 3)
    }

    static func restorationAllowsSleep(active: Bool, blocked: Bool) -> Bool {
        !active && !blocked
    }

    static func shouldSleep(onBattery: Bool, percent: Int?, cutoff: Int) -> Bool {
        guard onBattery, let percent, (0...100).contains(percent), (1...100).contains(cutoff) else { return false }
        return percent < cutoff
    }

}
