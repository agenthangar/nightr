#if os(macOS)
import Foundation
import AppKit
import Network
import NightrCore

@MainActor public final class MacSystemEvents {
    private let monitor = NWPathMonitor()
    private var tokens: [NSObjectProtocol] = []
    public init(send: @escaping @Sendable (MonitorEvent) -> Void) {
        monitor.pathUpdateHandler = { _ in send(.pathChanged) }
        monitor.start(queue: DispatchQueue(label: "ai.nightr.path"))
        let center = NSWorkspace.shared.notificationCenter
        tokens.append(center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { _ in send(.sleep) })
        // Workspace didWake is the user-visible wake source. Dark/maintenance power
        // notifications are deliberately never translated into a normal wake.
        tokens.append(center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { _ in send(.normalWake) })
    }
    deinit { monitor.cancel(); for token in tokens { NSWorkspace.shared.notificationCenter.removeObserver(token) } }
}

#endif
