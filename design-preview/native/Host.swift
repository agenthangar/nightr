import AppKit
import Darwin

// Keep the actual NSWindow and its draft alive while swapping SwiftUI implementations.
@MainActor final class PreviewHost: NSObject, NSWindowDelegate, NSApplicationDelegate {
    typealias Factory = @convention(c) (UnsafeMutableRawPointer) -> UnsafeMutableRawPointer
    let window = NSWindow(contentRect: .zero, styleMask: [.titled, .closable, .fullSizeContentView],
                          backing: .buffered, defer: false)
    let draft = NSMutableDictionary()
    let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    let pane = NSPopover()
    private let dismissal = MenuPopoverDismissal()
    private let fallback = NSWindow(contentRect: .zero, styleMask: [.titled, .closable], backing: .buffered, defer: false)
    let directory: URL
    var lastLibrary = ""
    var lastActivation = ""
    var watch: DispatchSourceFileSystemObject?

    init(directory: URL) {
        self.directory = directory
        super.init()
        window.collectionBehavior.insert(.moveToActiveSpace)
        window.title = "Nightr Settings Preview"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.titlebarSeparatorStyle = .none
        window.isReleasedWhenClosed = false
        window.delegate = self
        let fd = open(directory.path, O_EVTONLY)
        precondition(fd >= 0)
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: .write, queue: .main)
        source.setEventHandler { [weak self] in self?.refresh() }
        source.setCancelHandler { close(fd) }
        watch = source
        source.resume()
        pane.delegate = dismissal
        pane.behavior = .transient
        pane.animates = false
        fallback.title = "Nightr Pane Preview"
        fallback.isReleasedWhenClosed = false
        fallback.delegate = self
        statusItem.button?.title = " Preview"
        statusItem.button?.imagePosition = .imageLeading
        statusItem.button?.target = self
        statusItem.button?.action = #selector(togglePane)
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(frontSettings), name: .previewOpenSettings, object: nil)
        center.addObserver(self, selector: #selector(closeSettings), name: .previewCloseSettings, object: nil)
        center.addObserver(self, selector: #selector(updateStatus(_:)), name: .previewStateChanged, object: nil)
        refresh()
    }

    @objc func updateStatus(_ note: Notification) {
        if let image = note.userInfo?["image"] as? NSImage { statusItem.button?.image = image }
        if let label = note.userInfo?["label"] as? String { statusItem.button?.toolTip = "Nightr preview, " + label }
    }

    func refresh() {
        let revision = try? String(contentsOf: directory.appendingPathComponent("revision"), encoding: .utf8)
        if let revision, revision != lastLibrary {
            let file = directory.appendingPathComponent(revision)
            // A SwiftUI callback from a retired view may still be in the event queue.
            // Keep loaded images resident until the preview process exits.
            guard let library = dlopen(file.path, RTLD_NOW | RTLD_LOCAL),
                  let symbol = dlsym(library, "makeNightrSettingsPreview"),
                  let paneSymbol = dlsym(library, "makeNightrPanePreview") else {
                fputs("Cannot load preview: " + String(cString: dlerror()) + "\n", stderr)
                return
            }
            let factory = unsafeBitCast(symbol, to: Factory.self)
            let pointer = factory(Unmanaged.passUnretained(draft).toOpaque())
            let view = Unmanaged<NSView>.fromOpaque(pointer).takeRetainedValue()
            let size = view.fittingSize
            let first = lastLibrary.isEmpty
            let top = window.frame.maxY
            window.contentView = view
            window.setFrame(NSRect(x: window.frame.minX, y: top - size.height, width: size.width, height: size.height), display: true)
            let paneFactory = unsafeBitCast(paneSymbol, to: Factory.self)
            let paneView = Unmanaged<NSView>.fromOpaque(paneFactory(Unmanaged.passUnretained(draft).toOpaque())).takeRetainedValue()
            let controller = NSViewController()
            controller.view = paneView
            pane.contentViewController = controller
            pane.contentSize = paneView.fittingSize
            if fallback.isVisible { fallback.contentView = paneView; fallback.setContentSize(paneView.fittingSize) }
            lastLibrary = revision
            if first { window.center() }
            print("Loaded \(revision), window \(window.windowNumber)")
            fflush(stdout)
        }
        if let activation = try? String(contentsOf: directory.appendingPathComponent("activate"), encoding: .utf8),
           activation != lastActivation { lastActivation = activation; if NSApp.isRunning { showPane() } }
    }

    @objc func frontSettings() {
        pane.close()
        hideFallback()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        DispatchQueue.main.async { self.showPane() }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        showPane()
        return false
    }

    @objc func closeSettings() { window.close() }
    @objc func togglePane() {
        if pane.isShown { pane.close() }
        else if fallback.isVisible { hideFallback() }
        else { showPane() }
    }
    func showPane() {
        guard let controller = pane.contentViewController else { return }
        window.orderOut(nil)
        NSApp.activate(ignoringOtherApps: true)
        if let button = statusItem.button, let anchor = button.window, anchor.isVisible,
           NSScreen.screens.contains(where: { $0.frame.intersects(anchor.frame) }) {
            hideFallback()
            pane.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        } else {
            if pane.isShown { pane.close() }
            fallback.contentView = controller.view
            fallback.setContentSize(controller.view.fittingSize)
            fallback.center()
            fallback.makeKeyAndOrderFront(nil)
            dismissal.watchOutsideClicks { [weak self] in
                guard let self, self.fallback.attachedSheet == nil else { return }
                self.hideFallback()
            }
        }
    }

    private func hideFallback() {
        guard fallback.isVisible else { return }
        dismissal.stopWatching()
        fallback.orderOut(nil)
    }

    func windowWillClose(_ notification: Notification) {
        if notification.object as? NSWindow === fallback { dismissal.stopWatching() }
    }

    func applicationDidResignActive(_ notification: Notification) {
        guard fallback.attachedSheet == nil else { return }
        hideFallback()
    }
}

@main enum PreviewMain {
    @MainActor static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        let menu = NSMenu()
        let appItem = NSMenuItem()
        menu.addItem(appItem)
        let appMenu = NSMenu()
        appItem.submenu = appMenu
        appMenu.addItem(withTitle: "Close Preview", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        appMenu.addItem(withTitle: "Quit Preview", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        let edit = NSMenu(title: "Edit")
        let editItem = NSMenuItem(title: "Edit", action: nil, keyEquivalent: "")
        menu.addItem(editItem)
        editItem.submenu = edit
        for (title, selector, key) in [("Cut","cut:","x"), ("Copy","copy:","c"), ("Paste","paste:","v"), ("Select All","selectAll:","a")] {
            edit.addItem(withTitle: title, action: NSSelectorFromString(selector), keyEquivalent: key)
        }
        app.mainMenu = menu
        let host = PreviewHost(directory: URL(fileURLWithPath: CommandLine.arguments[1]))
        app.delegate = host
        withExtendedLifetime(host) { app.run() }
    }
}
