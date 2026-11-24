import AppKit

/// Deliver the outside-click callback to an isolated popover. Other apps receive no input.
@main enum CheckDismissal {
    @MainActor static func main() {
        _ = NSApplication.shared
        let anchor = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: 120, height: 80),
                              styleMask: .borderless, backing: .buffered, defer: false)
        anchor.orderBack(nil)
        defer { anchor.orderOut(nil) }
        let view = anchor.contentView!
        let popover = NSPopover()
        let controller = NSViewController()
        controller.view = NSView(frame: NSRect(x: 0, y: 0, width: 120, height: 90))
        popover.contentViewController = controller
        popover.animates = false
        let dismissal = MenuPopoverDismissal()
        popover.delegate = dismissal
        for _ in 0..<2 {
            popover.show(relativeTo: view.bounds, of: view, preferredEdge: .minY)
            precondition(popover.isShown)
            let parent = controller.view.window!
            let sheet = NSPanel(contentRect: controller.view.bounds, styleMask: .titled,
                                backing: .buffered, defer: false)
            parent.beginSheet(sheet)
            MenuPopoverDismissal.dismissOnOutsideClick(popover)
            precondition(popover.isShown && parent.attachedSheet === sheet)
            parent.endSheet(sheet)
            RunLoop.main.run(until: Date().addingTimeInterval(0.25))
            MenuPopoverDismissal.dismissOnOutsideClick(popover)
            precondition(!popover.isShown)
        }
        print("Outside-click dismissal preserves a child sheet and works again after reopening.")
    }
}
