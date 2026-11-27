#if os(macOS)
import AppKit
import Combine
import SwiftUI
import NightrCore

@MainActor final class NightrApplicationDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private let model: AppModel
    private var statusItem: NSStatusItem?
    private var statusLabel: AnyCancellable?
    private var setupWindow: NSWindow?
    private var settingsWindow: NSWindow?
    private let popoverDismissal = MenuPopoverDismissal()
    private lazy var popover: NSPopover = {
        let popover = makeMenuPopover(hosting: PopoverHost(model: model, setup: { [weak self] in self?.openSetup() }) { [weak self] in
            self?.openSettings()
        })
        popover.delegate = popoverDismissal
        return popover
    }()

    init(model: AppModel) {
        self.model = model
        super.init()
        GUIEventInbox.connect(self)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        installApplicationMenu()
        insertStatusItemIfNeeded()
        GUIEventInbox.didFinishLaunching()
        let launch = GUILaunchConfiguration(arguments: CommandLine.arguments)
        if launch.startup == .controller && !launch.headless && !launch.afterDesktopInstall,
           let event = notification.userInfo?["NSAppleEvent"] as? NSAppleEventDescriptor,
           event.eventID == kAEOpenApplication,
           event.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue != keyAELaunchedAsLogInItem,
           !UserDefaults.standard.bool(forKey: "guidedSetupCompleted") {
            openSetup()
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        GUIEventInbox.reopen()
        return false
    }

    func receive(_ route: GUISettingsRoute) { openSettings(route: route) }

    func reopen() {
        promotePresentation()
        NSApp.activate(ignoringOtherApps: true)
        if let button = statusItem?.button, !popover.isShown { showPane(at: button) }
    }

    private func promotePresentation(route: GUISettingsRoute? = nil) {
        var next = model.presentation
        if let route { next.receive(route) } else { next.reopen() }
        if next != model.presentation { model.presentation = next }
        insertStatusItemIfNeeded()
    }

    private func insertStatusItemIfNeeded() {
        guard model.presentation.menuVisible, statusItem == nil else { return }
        model.updater.start()
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem = item
        guard let button = item.button else { return }
        button.image = MoonSparkArtwork.menuImage
        button.target = self
        button.action = #selector(togglePopover(_:))
        statusLabel = model.$status.combineLatest(model.$error)
            .sink { [weak button] status, error in
                let state = GUIProtectionSummary(status: status, error: error)
                button?.image = MoonSparkArtwork.menuImage(for: state)
                button?.setAccessibilityLabel("Nightr, \(state.label)")
            }
    }

    @objc private func togglePopover(_ sender: NSStatusBarButton) {
        if popover.isShown {
            popover.close()
        } else {
            showPane(at: sender)
        }
    }

    private func showPane(at button: NSStatusBarButton) {
        if !UserDefaults.standard.bool(forKey: "guidedSetupCompleted") { openSetup(); return }
        settingsWindow?.orderOut(nil)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
    }

    @objc private func openSetup() {
        popover.close()
        settingsWindow?.orderOut(nil)
        if let setupWindow { front(setupWindow); return }
        let view = GuidedSetup(model: model) { [weak self] in
            UserDefaults.standard.set(true, forKey: "guidedSetupCompleted")
            self?.setupWindow?.close()
            self?.reopen()
        }
        let window = NSWindow(contentViewController: NSHostingController(rootView: view))
        window.styleMask = [.titled, .closable]
        window.title = "Set Up Nightr"
        window.isReleasedWhenClosed = false
        window.delegate = self
        setupWindow = window
        window.center()
        front(window)
    }
    @objc private func showSettings(_ sender: Any?) { openSettings() }

    private func openSettings(route: GUISettingsRoute = .general) {
        if popover.isShown { popover.close() }
        promotePresentation(route: route)
        if let settingsWindow {
            front(settingsWindow)
            return
        }
        let view = SettingsHost(model: model) { [weak self] in self?.settingsWindow?.close() }
        let window = makeSettingsWindow(hosting: view)
        window.delegate = self
        settingsWindow = window
        window.center()
        front(window)
    }

    private func front(_ window: NSWindow) {
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        if notification.object as? NSWindow === setupWindow { setupWindow = nil }
        else { settingsWindow = nil }
    }

    @objc private func stopAndQuit(_ sender: Any?) { model.quit() }

    private func installApplicationMenu() {
        let main = NSMenu()
        let appItem = main.addItem(withTitle: "Nightr", action: nil, keyEquivalent: "")
        let appMenu = NSMenu(title: "Nightr")
        appItem.submenu = appMenu
        appMenu.addItem(withTitle: "Set Up Nightr…", action: #selector(openSetup), keyEquivalent: "").target = self
        appMenu.addItem(withTitle: "Settings…", action: #selector(showSettings(_:)), keyEquivalent: ",").target = self
        appMenu.addItem(withTitle: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Stop and Quit", action: #selector(stopAndQuit(_:)), keyEquivalent: "q").target = self

        let editItem = main.addItem(withTitle: "Edit", action: nil, keyEquivalent: "")
        let edit = NSMenu(title: "Edit")
        editItem.submenu = edit
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        NSApp.mainMenu = main
    }
}

/// Shared by production presentation and full-window visual fixtures. Creating
/// this window does not activate the application or perform any system setup.
@MainActor func makeSettingsWindow<Content: View>(hosting content: Content) -> NSWindow {
    let host = NSHostingController(rootView: content)
    host.sizingOptions = []
    if #available(macOS 14.0, *) { host.safeAreaRegions = [] }
    let window = NSWindow(contentViewController: host)
    window.title = "Nightr Settings"
    window.styleMask = [.titled, .closable, .fullSizeContentView]
    window.titleVisibility = .hidden
    window.titlebarAppearsTransparent = true
    window.titlebarSeparatorStyle = .none
    window.backgroundColor = .nightrSurface
    host.view.layoutSubtreeIfNeeded()
    window.contentMinSize = .zero
    window.setFrame(NSRect(x: window.frame.minX, y: window.frame.minY,
                           width: SettingsLayout.width, height: SettingsLayout.bodyHeight), display: false)
    window.isReleasedWhenClosed = false
    return window
}

@MainActor func makeMenuPopover<Content: View>(hosting content: Content) -> NSPopover {
    let popover = NSPopover()
    popover.behavior = .transient
    // Complete a close before Settings opens, including during rapid handoffs.
    popover.animates = false

    let host = NSHostingController(rootView: content
        .fixedSize(horizontal: false, vertical: true)
        .onGeometryChange(for: CGSize.self, of: \.size) { [weak popover] size in
            let fitted = CGSize(width: ceil(size.width), height: ceil(size.height))
            guard let popover, fitted.width > 0, fitted.height > 0, fitted != popover.contentSize else { return }
            popover.contentSize = fitted
        })
    let initialSize = host.view.fittingSize
    host.view.frame.size = initialSize
    popover.contentViewController = host
    popover.contentSize = initialSize
    return popover
}

private struct PopoverHost: View {
    @ObservedObject var model: AppModel
    let setup: () -> Void
    let settings: () -> Void

    var body: some View {
        NightrPopover(status: model.status, error: model.error, helperStatus: model.helperStatus, setupError: model.setupError, command: { model.command($0) },
                      settings: settings, setup: setup, quit: { model.quit() }, wifiSettings: { DesktopSetup.systemWiFi() })
    }
}
#endif
