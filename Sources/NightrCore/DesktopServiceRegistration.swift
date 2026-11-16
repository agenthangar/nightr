import Foundation

public enum DesktopServiceStatus: Equatable { case notRegistered, enabled, requiresApproval, unavailable }
@MainActor public protocol DesktopServiceRegistration: AnyObject {
    var name: String { get }
    var status: DesktopServiceStatus { get }
    func register() throws
    func unregister() throws
}
public struct DesktopServiceError: LocalizedError {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

/// A token contains only newly enabled registrations. Pending approval is an
/// explicit user consent state, and is retained even when another step fails.
@MainActor public struct DesktopRegistrationReceipt {
    private var newlyEnabled: [any DesktopServiceRegistration] = []
    public private(set) var pending: [String] = []
    public init() {}
    public mutating func ensure(_ service: any DesktopServiceRegistration) throws {
        switch service.status {
        case .enabled: return
        case .requiresApproval: pending.append(service.name); return
        case .unavailable: throw DesktopServiceError("\(service.name) is unavailable. Repair the Nightr installation.")
        case .notRegistered: break
        }
        do { try service.register() }
        catch {
            if service.status == .requiresApproval { pending.append(service.name); return }
            if service.status == .enabled { newlyEnabled.append(service) }
            throw error
        }
        switch service.status {
        case .enabled: newlyEnabled.append(service)
        case .requiresApproval: pending.append(service.name)
        case .notRegistered, .unavailable: throw DesktopServiceError("\(service.name) registration did not become available.")
        }
    }
    public func rollback() throws {
        var failures: [String] = []
        for service in newlyEnabled.reversed() where service.status == .enabled {
            do { try service.unregister() }
            catch { failures.append(service.name) }
        }
        if !failures.isEmpty { throw DesktopServiceError("Could not undo new registrations: \(failures.joined(separator: ", ")). Repair login settings in System Settings → General → Login Items.") }
    }
    public static func enable(_ services: [any DesktopServiceRegistration]) throws -> Self {
        var receipt = Self()
        do { for service in services { try receipt.ensure(service) }; return receipt }
        catch {
            let original = error
            do { try receipt.rollback() }
            catch { throw DesktopServiceError(original.localizedDescription + " " + error.localizedDescription) }
            throw original
        }
    }
    public static func disable(_ services: [any DesktopServiceRegistration]) throws {
        // Caller puts mainApp first and the potentially self-terminating agent last.
        for service in services {
            switch service.status {
            case .notRegistered: continue
            case .unavailable: throw DesktopServiceError("\(service.name) is unavailable. Repair the Nightr installation.")
            case .enabled, .requiresApproval: try service.unregister()
            }
        }
    }
}
