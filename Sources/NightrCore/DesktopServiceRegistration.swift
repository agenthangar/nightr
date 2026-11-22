import Foundation

public enum DesktopServiceStatus: Equatable { case notRegistered, enabled, requiresApproval, unavailable, missingBundleFiles, notFound }
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
        case .unavailable: throw Self.failure(service, operation: "enable", detail: "macOS could not determine its registration status.")
        case .missingBundleFiles: throw Self.missingFiles(service)
        case .notRegistered, .notFound: break
        }
        do { try service.register() }
        catch {
            if service.status == .requiresApproval { pending.append(service.name); return }
            if service.status == .enabled { newlyEnabled.append(service) }
            throw Self.failure(service, operation: "enable", detail: error.localizedDescription)
        }
        switch service.status {
        case .enabled: newlyEnabled.append(service)
        case .requiresApproval: pending.append(service.name)
        case .notRegistered, .notFound, .unavailable: throw Self.failure(service, operation: "enable", detail: "macOS did not confirm registration.")
        case .missingBundleFiles: throw Self.missingFiles(service)
        }
    }
    public func rollback() throws {
        var failures: [String] = []
        for service in newlyEnabled.reversed() {
            // Pending approval remains an explicit consent state. Other lookup
            // failures cannot prove that a newly created registration is gone.
            if service.status == .notRegistered || service.status == .requiresApproval { continue }
            do {
                try service.unregister()
                if service.status != .notRegistered && service.status != .notFound { failures.append(service.name) }
            }
            catch { if service.status != .notRegistered { failures.append(service.name) } }
        }
        if !failures.isEmpty { throw DesktopServiceError("Could not undo new registrations: \(failures.joined(separator: ", ")). Review System Settings → General → Login Items and turn off those Nightr entries, then retry.") }
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
            case .unavailable: throw failure(service, operation: "disable", detail: "macOS could not determine its registration status.")
            case .missingBundleFiles: throw missingFiles(service)
            case .enabled, .requiresApproval, .notFound:
                do { try service.unregister() }
                catch {
                    if service.status != .notRegistered { throw failure(service, operation: "disable", detail: error.localizedDescription) }
                }
                guard service.status == .notRegistered || service.status == .notFound else {
                    throw failure(service, operation: "disable", detail: "macOS did not confirm removal.")
                }
            }
        }
    }
    private static func missingFiles(_ service: any DesktopServiceRegistration) -> DesktopServiceError {
        DesktopServiceError("\(service.name) is missing required files from the Nightr app bundle. Reinstall Nightr using your installation manager, then retry.")
    }
    private static func failure(_ service: any DesktopServiceRegistration, operation: String, detail: String) -> DesktopServiceError {
        DesktopServiceError("Could not \(operation) \(service.name). \(detail) Review System Settings → General → Login Items, then retry.")
    }

}
