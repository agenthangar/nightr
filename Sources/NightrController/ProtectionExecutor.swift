import Foundation
import NightrCore

/// A latest-intent mailbox serializes lease transitions across actor suspension.
/// Stop remains durable immediately while an in-flight bounded acquire is drained.
actor ProtectionExecutor {
    private let platform: any ControllerPlatform
    private var desired: Settings?
    private var sleepBelow: Int?
    private var sleepRequest: Task<Void, Never>?
    private var revision = 0
    private var epoch = 0
    private var draining = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private let report: @Sendable (Int, Bool, String?) async -> Void
    init(platform: any ControllerPlatform, report: @escaping @Sendable (Int, Bool, String?) async -> Void) {
        self.platform = platform; self.report = report
    }
    func submit(_ settings: Settings?, epoch: Int, sleepBelow: Int? = nil) {
        guard epoch >= self.epoch else { return }
        sleepRequest?.cancel()
        desired = settings; self.sleepBelow = sleepBelow; self.epoch = epoch; revision += 1
        guard !draining else { return }
        draining = true
        Task { await drain() }
    }
    func flush() async {
        guard draining else { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    private func drain() async {
        while true {
            let current = revision
            let currentEpoch = epoch
            let target = desired
            let cutoff = sleepBelow
            if let settings = target {
                do {
                    try await platform.acquireProtection(settings: settings)
                    if current == revision { await report(currentEpoch, true, nil) }
                } catch {
                    // Every failed acquire is followed by release in this same serial lane.
                    await platform.releaseProtection()
                    if current == revision { desired = nil; await report(currentEpoch, false, error.localizedDescription) }
                }
            } else {
                await platform.releaseProtection()
                if current == revision, let cutoff {
                    let request = Task { [platform] in await platform.requestBatterySleep(below: cutoff) }
                    sleepRequest = request
                    await request.value
                    sleepRequest = nil
                }
                if current == revision { await report(currentEpoch, false, nil) }
            }
            if current == revision {
                draining = false
                let completed = waiters; waiters.removeAll(); completed.forEach { $0.resume() }
                return
            }
        }
    }
}
