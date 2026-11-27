import Foundation
import NightrCore

/// Production implementations must bound and cancel their own underlying operations.
public protocol ControllerPlatform: Sendable {
    func acquireProtection(settings: Settings) async throws
    func releaseProtection() async
    func requestBatterySleep(below cutoff: Int) async
    func verifyInternet(timeout: TimeInterval) async -> Bool
    func joinHotspot(ssid: String, timeout: TimeInterval) async -> JoinResult
    func sample() async -> MachineSample
    func sample(checkAgentActivity: Bool) async -> MachineSample
    func notifyHotspot() async
    func cancelOperations() async
}
public extension ControllerPlatform {
    func requestBatterySleep(below cutoff: Int) async {}
    func sample(checkAgentActivity: Bool) async -> MachineSample { await sample() }
    func notifyHotspot() async {}
    func cancelOperations() async {}
}
