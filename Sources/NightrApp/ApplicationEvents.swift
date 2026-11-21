#if os(macOS)
import AppKit
import NightrCore

/// Model construction and presentation delivery may arrive in either order.
/// Queue only allowlisted presentation events until both AppKit and its delegate are ready.
@MainActor private enum GUIEventInboxStorage {
    static weak var delegate: NightrApplicationDelegate?
    static var launched = false
    static var queue = GUIEventQueue()
    static func drain() {
        guard launched, let delegate else { return }
        let events = queue.drain(ready: true)
        for event in events {
            switch event { case .settings(let route): delegate.receive(route); case .reopen: delegate.reopen() }
        }
    }
}
/// Registered eagerly, before the startup task can restore controller intent.
/// This receiver only queues a fixed tab; it cannot authorize or start anything.
@MainActor final class GUISettingsNotificationReceiver: NSObject {
    private let center = DistributedNotificationCenter.default()
    private let target = String(ProcessInfo.processInfo.processIdentifier)
    override init() {
        super.init()
        guard GUISettingsRequest.acceptsReceiver(bundleID: Bundle.main.bundleIdentifier,
                                                 bundlePath: Bundle.main.bundleURL.standardizedFileURL.path) else { return }
        center.addObserver(self, selector: #selector(receive(_:)), name: Notification.Name(GUISettingsRequest.requestName),
                           object: target, suspensionBehavior: .deliverImmediately)
    }
    @objc private func receive(_ notification: Notification) {
        guard notification.object as? String == target,
              let request = GUISettingsRequest(userInfo: notification.userInfo) else { return }
        GUIEventInbox.receive(request.route)
        // ACK only after the event is enqueued or handled, with no all-session post.
        center.postNotificationName(Notification.Name(GUISettingsRequest.acknowledgementName), object: target,
                                    userInfo: request.userInfo, options: [.deliverImmediately])
    }
    deinit { center.removeObserver(self) }
}

@MainActor enum GUIEventInbox {
    static func connect(_ delegate: NightrApplicationDelegate) { GUIEventInboxStorage.delegate = delegate; GUIEventInboxStorage.drain() }
    static func didFinishLaunching() { GUIEventInboxStorage.launched = true; GUIEventInboxStorage.drain() }
    static func receive(_ route: GUISettingsRoute) {
        GUIEventInboxStorage.queue.receive(route); GUIEventInboxStorage.drain()
    }
    static func reopen() { GUIEventInboxStorage.queue.reopen(); GUIEventInboxStorage.drain() }
}
#endif
