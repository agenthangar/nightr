import Foundation
import NightrCore

/// A latest-intent mailbox serializes lease transitions across actor suspension.
/// Stop remains durable immediately while an in-flight bounded acquire is drained.
actor ProtectionExecutor {
    private let platform: any ControllerPlatform
    private var desired: Settings?
    private var revision = 0
    private var epoch = 0
    private var draining = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private let report: @Sendable (Int, Bool, String?) async -> Void
    init(platform: any ControllerPlatform, report: @escaping @Sendable (Int, Bool, String?) async -> Void) {
        self.platform = platform; self.report = report
    }
    func submit(_ settings: Settings?, epoch: Int) {
        desired = settings; self.epoch = epoch; revision += 1
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
