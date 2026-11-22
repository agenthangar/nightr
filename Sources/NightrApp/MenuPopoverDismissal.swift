#if os(macOS)
import AppKit

@MainActor final class MenuPopoverDismissal: NSObject, NSPopoverDelegate {
    private var outsideClickMonitor: Any?

    func popoverDidShow(_ notification: Notification) {
        guard let popover = notification.object as? NSPopover else { return }
        // Transient popovers can stay open when another app's menu starts tracking.
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        ) { [weak popover] _ in
            if let popover, popover.isShown { popover.close() }
        }
    }

    func popoverDidClose(_ notification: Notification) {
        guard let outsideClickMonitor else { return }
        NSEvent.removeMonitor(outsideClickMonitor)
        self.outsideClickMonitor = nil
    }
}
#endif
