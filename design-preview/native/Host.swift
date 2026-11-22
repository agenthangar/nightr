import AppKit
import Darwin
import NightrCore
import NightrController

// Keep the actual NSWindow and its draft alive while swapping SwiftUI implementations.
final class PreviewHost: NSObject, NSWindowDelegate {
    typealias Factory = @convention(c) (UnsafeMutableRawPointer) -> UnsafeMutableRawPointer
    let window = NSWindow(contentRect: .zero, styleMask: [.titled, .closable, .fullSizeContentView],
                          backing: .buffered, defer: false)
    let draft = NSMutableDictionary()
    let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    var poll: Task<Void, Never>?
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
        refresh()
        statusItem.button?.title = " Preview"
        statusItem.button?.imagePosition = .imageLeading
        statusItem.button?.target = self
        statusItem.button?.action = #selector(front)
        poll = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                let state = await Task.detached {
                    do {
                        let response = try ControllerClient().request(.init(command: .status))
                        return GUIProtectionSummary(status: response.status, error: response.error)
                    } catch { return GUIProtectionSummary(status: nil, error: error.localizedDescription) }
                }.value
                guard let self else { return }
                self.statusItem.button?.image = state.activelyProtecting ? MoonSparkArtwork.activeMenuImage : MoonSparkArtwork.menuImage
                self.statusItem.button?.toolTip = "Nightr preview — " + state.label
                self.statusItem.button?.setAccessibilityLabel("Nightr preview, " + state.label)
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
    }

    func refresh() {
        let revision = try? String(contentsOf: directory.appendingPathComponent("revision"), encoding: .utf8)
        if let revision, revision != lastLibrary {
            let file = directory.appendingPathComponent(revision)
            // A SwiftUI callback from a retired view may still be in the event queue.
            // Keep loaded images resident until the preview process exits.
            guard let library = dlopen(file.path, RTLD_NOW | RTLD_LOCAL),
                  let symbol = dlsym(library, "makeNightrSettingsPreview") else {
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
            lastLibrary = revision
            if first { window.center(); front() }
            print("Loaded \(revision), window \(window.windowNumber)")
            fflush(stdout)
        }
        if let activation = try? String(contentsOf: directory.appendingPathComponent("activate"), encoding: .utf8),
           activation != lastActivation { lastActivation = activation; front() }
    }

    @objc func front() { window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true) }
    func windowWillClose(_ notification: Notification) { poll?.cancel(); NSApp.terminate(nil) }
}

@main enum PreviewMain {
    static func main() {
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
        withExtendedLifetime(host) { app.run() }
    }
}
