import Foundation
import NightrCore

/// Production implementations must bound and cancel their own underlying operations.
public protocol ControllerPlatform: Sendable {
    func acquireProtection(settings: Settings) async throws
    func releaseProtection() async
    func verifyInternet(timeout: TimeInterval) async -> Bool
    func joinHotspot(ssid: String, timeout: TimeInterval) async -> JoinResult
    func sample() async -> MachineSample
    func notifyHotspot() async
    func cancelOperations() async
}
public extension ControllerPlatform {
    func notifyHotspot() async {}
    func cancelOperations() async {}
}
