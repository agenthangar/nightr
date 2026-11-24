#if os(macOS)
import AppKit

@MainActor final class MenuPopoverDismissal: NSObject, NSPopoverDelegate {
    private var outsideClickMonitor: Any?

    func popoverDidShow(_ notification: Notification) {
        guard let popover = notification.object as? NSPopover else { return }
        watchOutsideClicks { [weak popover] in
            Self.dismissOnOutsideClick(popover)
        }
    }

    static func dismissOnOutsideClick(_ popover: NSPopover?) {
        guard let popover, popover.isShown,
              popover.contentViewController?.view.window?.attachedSheet == nil else { return }
        popover.close()
    }

    func watchOutsideClicks(_ dismiss: @escaping () -> Void) {
        stopWatching()
        // Transient popovers can stay open when another app's menu starts tracking.
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        ) { _ in dismiss() }
    }

    func popoverDidClose(_ notification: Notification) {
        stopWatching()
    }

    func stopWatching() {
        guard let outsideClickMonitor else { return }
        NSEvent.removeMonitor(outsideClickMonitor)
        self.outsideClickMonitor = nil
    }
}
#endif
