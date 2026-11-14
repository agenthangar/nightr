import Foundation

/// Only an absent/refused local endpoint permits explicit Start to bootstrap.
/// Unsafe endpoints, peer validation and application rejections use other errors.
public struct ControllerUnavailableError: Error, LocalizedError, Equatable, Sendable {
    public let message: String
    public init(message: String = "Nightr controller is not running.") { self.message = message }
    public var errorDescription: String? { message }
}

public enum NightrSettingsSection: String, CaseIterable, Identifiable, Sendable {
    case general = "General", protection = "Protection", connectivity = "Connectivity", advanced = "Advanced"
    public var id: String { rawValue }
}

/// Presentation-only destinations; these are never registered URL handlers.
public enum GUISettingsRoute: String, CaseIterable, Equatable, Sendable {
    case general, connectivity
    public var section: NightrSettingsSection { self == .general ? .general : .connectivity }
}

public enum GUIStartupMode: Equatable, Sendable {
    case presentation, controller
    public static let settingsArguments = ["--settings-only"]
    public init(arguments: [String]) {
        self = arguments.contains(where: { ["--settings-only", "--setup", "--hotspot-setup", "--enable-discovery"].contains($0) }) ? .presentation : .controller
    }
}

/// Untrusted distributed notifications accept exactly a UUID and one fixed tab.
/// Their object is the launched application's PID, scoped to this login session.
public struct GUISettingsRequest: Equatable, Sendable {
    public static let requestName = "ai.nightr.settings.request.v1"
    public static let acknowledgementName = "ai.nightr.settings.ack.v1"
    public let id: UUID
    public let route: GUISettingsRoute
    public init(id: UUID = UUID(), route: GUISettingsRoute) { self.id = id; self.route = route }
    public var userInfo: [AnyHashable: Any] { ["requestID": id.uuidString, "section": route.rawValue] }
    public init?(userInfo: [AnyHashable: Any]?) {
        guard let userInfo, Set(userInfo.keys) == Set([AnyHashable("requestID"), AnyHashable("section")]),
              let text = userInfo["requestID"] as? String, let id = UUID(uuidString: text), text == id.uuidString,
              let section = userInfo["section"] as? String, let route = GUISettingsRoute(rawValue: section) else { return nil }
        self.id = id; self.route = route
    }
    public static func acceptsReceiver(bundleID: String?, bundlePath: String) -> Bool {
        bundleID == "ai.nightr.app" && bundlePath == "/Applications/Nightr.app"
    }
}

/// Fixed retry/deadline budget: delivery and ACK loss must produce a visible
/// failure rather than claiming that Settings opened.
public struct GUISettingsDelivery: Sendable {
    public enum Action: Equatable { case post, wait, acknowledged, expired }
    public let request: GUISettingsRequest
    private let deadline: TimeInterval
    private var nextPost: TimeInterval
    private var attempts = 0
    private var acknowledged = false
    public init(request: GUISettingsRequest, now: TimeInterval) {
        self.request = request; deadline = now + 3; nextPost = now
    }
    public mutating func acknowledge(_ response: GUISettingsRequest) {
        if response == request { acknowledged = true }
    }
    public mutating func next(now: TimeInterval) -> Action {
        if acknowledged { return .acknowledged }
        if now >= deadline { return .expired }
        if attempts < 6 && now >= nextPost {
            attempts += 1; nextPost = now + 0.4; return .post
        }
        return .wait
    }
}

public struct GUIPresentationState: Equatable, Sendable {
    public var menuVisible: Bool
    public var section: NightrSettingsSection = .general
    public init(headless: Bool) { menuVisible = !headless }
    public mutating func receive(_ route: GUISettingsRoute) {
        menuVisible = true
        section = route.section
    }
    public mutating func reopen() { menuVisible = true }
}

/// A later Stop or Quit invalidates a Start that is waiting for reconnection.
public final class GUIStartIntent: @unchecked Sendable {
    private let lock = NSLock()
    private var generation = UUID()
    public init() {}
    public func begin() -> UUID { lock.lock(); defer { lock.unlock() }; generation = UUID(); return generation }
    public func cancel() { lock.lock(); generation = UUID(); lock.unlock() }
    public func isCurrent(_ token: UUID) -> Bool { lock.lock(); defer { lock.unlock() }; return generation == token }
}

/// Keep mutating GUI requests in order without blocking the UI thread. A queued
/// Start checks its shared intent immediately before transport; any Stop already
/// queued behind an in-flight request will be delivered after that request.
public actor GUIControllerCommands {
    private let send: @Sendable (ControllerRequest) throws -> ControllerResponse
    public init(send: @escaping @Sendable (ControllerRequest) throws -> ControllerResponse) { self.send = send }
    public func request(_ request: ControllerRequest, intent: GUIStartIntent? = nil, token: UUID? = nil) throws -> ControllerResponse? {
        if let intent, let token, !intent.isCurrent(token) { return nil }
        return try send(request)
    }
}

public enum GUIEvent: Equatable, Sendable { case settings(GUISettingsRoute), reopen }
public struct GUIEventQueue: Sendable {
    private var settings: GUISettingsRoute?
    private var reopening = false
    public init() {}
    public mutating func receive(_ route: GUISettingsRoute) { settings = route }
    public mutating func reopen() { reopening = true }
    public mutating func drain(ready: Bool) -> [GUIEvent] {
        guard ready else { return [] }
        defer { settings = nil; reopening = false }
        if let settings { return [.settings(settings)] }
        return reopening ? [.reopen] : []
    }
}
