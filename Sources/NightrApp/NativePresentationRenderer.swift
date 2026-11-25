#if os(macOS) && DEBUG
import AppKit
import SwiftUI
import Vision
import NightrCore
import NightrController

/// Internal debug-only offscreen artifact path. Runs before AppModel exists;
/// captures synthetic content in an offscreen Settings window without starting system services.
@MainActor enum NativePresentationRenderer {
    static func run(output: URL) throws {
        _ = NSApplication.shared
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        try checkArtwork()
        checkMenuSizing()
        var draft = NightrCore.Settings()
        draft.hotspot = true
        draft.hotspotSSID = "Sample iPhone"
        draft.displayOn = true
        draft.lock = false
        precondition(draft.batteryProtection && draft.batteryBelow == 20)
        for dark in [false, true] {
            let scheme: ColorScheme = dark ? .dark : .light
            let suffix = dark ? "dark" : "light"
            for section in NightrSettingsSection.allCases {
                let updateFixture = DesktopUpdatePresentation(version: "0.1.0", build: "8a41c2d", phase: .ready("0.1.1"))
                let view = SettingsView(section: .constant(section), status: sample("On"), initialDraft: draft, notificationStatus: .authorized,
                                        updates: updateFixture, readHotspotMode: { .automatic })
                    .environment(\.colorScheme, scheme)
                let window = makeSettingsWindow(hosting: view)
                window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                defer { window.close() }
                window.displayIfNeeded()
                guard let frameView = window.contentView?.superview else { throw RenderError.bitmap }
                precondition(frameView.bounds.size == window.frame.size)
                let file = output.appendingPathComponent("settings-\(section.rawValue.lowercased())-\(suffix).png")
                try capture(frameView, to: file)
                try checkSettingsWindow(window, frameView: frameView, section: section, capture: file)
                try checkToolbarIconInsets(frameView, capture: file)
                if section != .general, let scroll = descendants(frameView).compactMap({ $0 as? NSScrollView }).first,
                   let document = scroll.documentView {
                    let bottom = document.isFlipped ? document.bounds.maxY - scroll.contentView.bounds.height : document.bounds.minY
                    scroll.contentView.scroll(to: NSPoint(x: 0, y: max(0, bottom)))
                    scroll.reflectScrolledClipView(scroll.contentView)
                    try capture(frameView, to: output.appendingPathComponent("settings-\(section.rawValue.lowercased())-bottom-\(suffix).png"))
                }
                try checkToolbarKeyboard(frameView)
            }
            let rows = ActivityModelRow.rows(sample("On").sample.activity, now: Date())
            for row in rows.prefix(2) {
                let state = row.inference ? "generating" : "idle"
                let view = LocalModelDetails(row: row).environment(\.colorScheme, scheme)
                try render(view, size: nil, dark: dark, to: output.appendingPathComponent("model-\(state)-\(suffix).png"))
            }
            let fixtures: [(String, ControllerStatus?, DesktopServiceStatus?)] = [
                ("Off", sample("Off"), .enabled), ("On", sample("On"), .enabled),
                ("Paused", sample("Paused"), .enabled), ("Recovering", sample("Recovering"), .enabled),
                ("Error", sample("Error"), .notRegistered), ("Checking", nil, nil),
                ("Approval", sample("Error"), .requiresApproval)
            ]
            for (label, status, helper) in fixtures {
                let view = NightrPopover(status: status, error: nil, helperStatus: helper)
                    .environment(\.colorScheme, scheme)
                try render(view, size: nil, dark: dark, to: output.appendingPathComponent("popover-\(label.lowercased())-\(suffix).png"))
            }
        }
        // Run the deterministic routing/state contracts even on Command Line
        // Tools hosts, which cannot import XCTest. Full XCTest remains in CI.
        for arguments in [[], ["--controller-only"], ["--settings-only"]] {
            let launch = GUILaunchConfiguration(arguments: arguments)
            precondition(launch.headless == arguments.contains("--controller-only"))
            precondition(launch.exitsAfterConnectingToExistingOwner == launch.headless)
            precondition((launch.startup == .presentation) == arguments.contains("--settings-only"))
        }
        var labels: Set<String> = [], symbols: Set<String> = []
        for label in ["Off", "On", "Paused", "Recovering", "Error"] {
            let summary = GUIProtectionSummary(status: sample(label))
            precondition(summary.label == label)
            labels.insert(summary.label); symbols.insert(summary.symbol)
        }
        precondition(labels.count == 5 && symbols.count == 5)
        try checkRegistration()
        try checkSettingsReceipt(in: output)
        print("Rendered full Settings windows and synthetic popover states; artwork, popover sizing, launch/state and synthetic-registration contracts passed.")
    }
    private static func checkMenuSizing() {
        let fixture = MenuFixture(status: sample("On"))
        let popover = makeMenuPopover(hosting: MenuFixtureHost(fixture: fixture))
        let initial = popover.contentSize
        precondition(popover.behavior == .transient && !popover.animates)
        precondition(initial.width == 318 && initial.height > 200)
        fixture.status = sample("Recovering")
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        popover.contentViewController?.view.layoutSubtreeIfNeeded()
        precondition(popover.contentSize.width == initial.width && popover.contentSize.height > initial.height)
        fixture.status = sample("On")
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        popover.contentViewController?.view.layoutSubtreeIfNeeded()
        precondition(popover.contentSize == initial)
    }
    private final class MenuFixture: ObservableObject {
        @Published var status: ControllerStatus
        init(status: ControllerStatus) { self.status = status }
    }
    private struct MenuFixtureHost: View {
        @ObservedObject var fixture: MenuFixture
        var body: some View { NightrPopover(status: fixture.status, error: nil, helperStatus: .enabled) }
    }
    private static func checkSettingsReceipt(in output: URL) throws {
        let directory = output.appendingPathComponent("save-contract")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SettingsStore(url: directory.appendingPathComponent("config.json"))
        var draft = NightrCore.Settings(); draft.launchAtLogin = false
        let committed = try store.save(draft, expected: nil)
        let stored = try Data(contentsOf: store.url); precondition(stored == committed)
        var external = draft; external.every = 47
        try store.save(external, expected: committed)
        do { try store.save(draft, expected: committed); preconditionFailure("Concurrent settings overwrite accepted") }
        catch { let retained = try store.load(); precondition(retained == external) }
    }
    private static func checkRegistration() throws {
        let existing = SyntheticService("existing", .enabled), pending = SyntheticService("pending", .requiresApproval)
        let retained = try DesktopRegistrationReceipt.enable([existing, pending])
        precondition(retained.pending == ["pending"] && existing.actions.isEmpty && pending.actions.isEmpty)
        try retained.rollback()
        precondition(existing.status == .enabled && pending.status == .requiresApproval)
        let fresh = SyntheticService("fresh", .notRegistered), missing = SyntheticService("missing", .unavailable)
        do { _ = try DesktopRegistrationReceipt.enable([fresh, missing]); preconditionFailure("Missing service accepted") }
        catch { precondition(fresh.actions == ["register", "unregister"] && fresh.status == .notRegistered) }
        let approval = SyntheticService("approval", .notRegistered)
        approval.pendingAfterRegister = true
        let receipt = try DesktopRegistrationReceipt.enable([approval])
        try receipt.rollback()
        precondition(receipt.pending == ["approval"] && approval.actions == ["register"] && approval.status == .requiresApproval)
        try DesktopRegistrationReceipt.disable([existing, pending])
        precondition(existing.actions == ["unregister"] && pending.actions == ["unregister"])
    }
    private final class SyntheticService: DesktopServiceRegistration {
        let name: String
        var status: DesktopServiceStatus
        var actions: [String] = []
        var pendingAfterRegister = false
        init(_ name: String, _ status: DesktopServiceStatus) { self.name = name; self.status = status }
        func register() throws {
            actions.append("register")
            status = pendingAfterRegister ? .requiresApproval : .enabled
            if pendingAfterRegister { throw DesktopServiceError("Synthetic pending approval") }
        }
        func unregister() throws { actions.append("unregister"); status = .notRegistered }
    }
    private static func render<V: View>(_ view: V, size: NSSize?, dark: Bool, to url: URL) throws {
        let host = NSHostingView(rootView: view)
        host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        host.frame.size = size ?? host.fittingSize
        try capture(host, to: url)
    }

    private static func capture(_ host: NSView, to url: URL) throws {
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        host.layoutSubtreeIfNeeded()
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { throw RenderError.bitmap }
        host.cacheDisplay(in: host.bounds, to: rep)
        guard let png = rep.representation(using: .png, properties: [:]) else { throw RenderError.bitmap }
        try png.write(to: url)
    }
    private static func descendants(_ view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants($0) }
    }

    private static func checkSettingsWindow(_ window: NSWindow, frameView: NSView, section: NightrSettingsSection, capture: URL) throws {
        let fields = descendants(frameView).compactMap { $0 as? NSTextField }
        guard let title = fields.first(where: { $0.accessibilityIdentifier() == "settings-window-title" }) else { throw RenderError.missingTitle }
        let titleFrame = frameView.convert(title.bounds, from: title)
        precondition(abs(titleFrame.midX - frameView.bounds.midX) <= 1 && title.alignment == .center)
        precondition(window.title == title.stringValue && window.titleVisibility == .hidden)
        precondition(window.frame.size == NSSize(width: 470, height: SettingsLayout.bodyHeight), "Settings window size drifted from the approved preview")
        // Read the rendered pane so unexpected SwiftUI-only rows are covered as well.
        let request = VNRecognizeTextRequest()
        request.recognitionLanguages = ["en-US"]
        try VNImageRequestHandler(url: capture).perform([request])
        let labels = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ").lowercased()
        let required: [String]
        switch section {
        case .advanced: required = ["check interval", "first retry delay", "scheduled wait"]
        case .connectivity: required = ["ask to join hotspots", "attempts"]
        case .protection: required = ["allow sleep below"]
        case .general: required = ["hotspot notifications", "automatically download updates", "update ready", "install update", "0.1.0"]
        }
        for label in required + ["reset", "cancel", "save"] where !labels.contains(label) {
            throw RenderError.generalControl("Missing visible \(section.rawValue) control: " + label)
        }
        guard section == .protection || section == .general else { return }
        if section == .protection {
            guard labels.contains("allow sleep below"), labels.contains("internet is available"),
                  !labels.contains("connectivity settings") else { throw RenderError.generalControl("Protection rows") }
            return
        }
        try checkGeneralCheckboxes(capture, width: frameView.bounds.width)
        for expected in ["launch at login", "hotspot notifications"] where !labels.contains(expected) {
            throw RenderError.generalControl(expected)
        }
        for extra in ["power helper", "set up nightr", "force mode"] where labels.contains(extra) {
            throw RenderError.generalControl(extra)
        }
    }

    /// Compare the trailing 32 × 24 pt of both General rows in the full-window
    /// capture. The fixture has both boxes on. Include the bezel, tick and the
    /// surrounding surface so a change in alignment is visible too.
    private static func checkGeneralCheckboxes(_ capture: URL, width: CGFloat) throws {
        guard let bitmap = NSBitmapImageRep(data: try Data(contentsOf: capture)) else { throw RenderError.bitmap }
        let scale = CGFloat(bitmap.pixelsWide) / width
        func pixels(_ points: CGFloat) -> Int { Int((points * scale).rounded()) }
        let trailingEdge = width - SettingsLayout.formInset
        let columns = pixels(trailingEdge - 32)..<pixels(trailingEdge)
        let rows = pixels(172)..<pixels(196)
        var ink = 0
        var different = 0
        func distance(_ a: NSColor, _ b: NSColor) -> CGFloat {
            max(abs(a.redComponent - b.redComponent), abs(a.greenComponent - b.greenComponent),
                abs(a.blueComponent - b.blueComponent))
        }
        for y in rows {
            guard let background = bitmap.colorAt(x: columns.lowerBound, y: y) else { throw RenderError.bitmap }
            for x in columns {
                guard let login = bitmap.colorAt(x: x, y: y),
                      let notifications = bitmap.colorAt(x: x, y: y + pixels(38)) else { throw RenderError.bitmap }
                if distance(login, background) > 0.04 { ink += 1 }
                if distance(login, notifications) > 0.04 { different += 1 }
            }
        }
        guard ink > pixels(8) * pixels(8), different <= max(1, ink / 50) else {
            throw RenderError.generalControl("General checkboxes differ in appearance or alignment")
        }
    }

    private static func checkToolbarIconInsets(_ host: NSView, capture: URL) throws {
        guard let bitmap = NSBitmapImageRep(data: try Data(contentsOf: capture)) else { throw RenderError.bitmap }
        let scale = CGFloat(bitmap.pixelsWide) / host.bounds.width
        let labels = NightrSettingsSection.allCases.map(\.rawValue)
        let buttons = descendants(host).compactMap { $0 as? NSButton }.filter { labels.contains($0.title) }
        precondition(buttons.count == 4)
        for button in buttons {
            let frame = host.convert(button.bounds, from: button)
            let top = host.isFlipped ? frame.minY : host.bounds.maxY - frame.maxY
            precondition(abs(top - 51) <= 1 && abs(frame.height - 56.5) <= 0.5,
                         "Toolbar tile drifted from approved header: \(button.title), top \(top), height \(frame.height)")
            precondition(button.target != nil && button.action != nil)
        }
        guard let general = buttons.first(where: { $0.title == "General" }) else { throw RenderError.bitmap }
        let frame = host.convert(general.bounds, from: general)
        // Measure actual ink in the entire captured header, rather than a local
        // button bitmap: native bezel alignment can otherwise hide a misplaced
        // tile. The approved reference has General ink at y65–77.5 and its
        // label at y88.5–97 in the Settings window.
        func ink(in rows: Range<Int>) throws -> NSRect {
            var occupied = NSRect.null
            for y in rows {
                let pixelY = Int(CGFloat(y) * scale)
                for subrow in 0..<Int(scale) {
                    guard let background = bitmap.colorAt(x: Int((frame.midX + 38) * scale), y: pixelY + subrow)?.usingColorSpace(.sRGB) else { throw RenderError.bitmap }
                    for x in Int((frame.midX - 28) * scale)..<Int((frame.midX + 28) * scale) {
                        guard let color = bitmap.colorAt(x: x, y: pixelY + subrow)?.usingColorSpace(.sRGB) else { throw RenderError.bitmap }
                        let contrast = max(abs(color.redComponent - background.redComponent),
                                           abs(color.greenComponent - background.greenComponent),
                                           abs(color.blueComponent - background.blueComponent))
                        if contrast > 0.2 {
                            occupied = occupied.union(NSRect(x: CGFloat(x) / scale, y: CGFloat(pixelY + subrow) / scale,
                                                             width: 1 / scale, height: 1 / scale))
                        }
                    }
                }
            }
            precondition(!occupied.isNull, "Missing General toolbar ink")
            return occupied
        }
        let icon = try ink(in: 58..<83), title = try ink(in: 84..<102)
        precondition(abs(icon.minY - 65) <= 1.5 && abs(icon.maxY - 78) <= 1.5
                     && (12...15).contains(icon.width) && (12...15).contains(icon.height),
                     "General symbol differs from approved header: \(icon)")
        precondition(abs(title.minY - 88.5) <= 1.5 && abs(title.maxY - 97.5) <= 1.5,
                     "General label differs from approved header: \(title)")
        let top = host.isFlipped ? frame.minY : host.bounds.maxY - frame.maxY
        precondition(abs((icon.minY - top) - 14) <= 1.5,
                     "General symbol needs the approved 14pt tile inset")
        print("General header: tile top \(top), icon \(icon), title \(title), ink inset \(icon.minY - top)pt")
    }

    private static func checkToolbarKeyboard(_ host: NSView) throws {
        let labels = NightrSettingsSection.allCases.map(\.rawValue)
        let buttons = descendants(host).compactMap { $0 as? NSButton }.filter { labels.contains($0.title) }.sorted { $0.tag < $1.tag }
        precondition(buttons.count == 4)
        guard let selected = buttons.firstIndex(where: { $0.acceptsFirstResponder }) else { preconditionFailure("Selected tab has no keyboard entry") }
        precondition(buttons.filter(\.acceptsFirstResponder).count == 1)
        let navigation: [(UInt16, Int)] = [(124, (selected + 1) % 4), (115, 0), (119, 3), (123, 2)]
        for (keyCode, expected) in navigation {
            guard let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
                                               characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: keyCode) else { throw RenderError.bitmap }
            buttons.first(where: { $0.acceptsFirstResponder })?.keyDown(with: event)
            precondition(buttons[expected].acceptsFirstResponder && buttons.filter(\.acceptsFirstResponder).count == 1)
        }
    }
    private static func checkArtwork() throws {
        precondition(MoonSparkArtwork.menuImage.size == NSSize(width: 19, height: 19) && MoonSparkArtwork.menuImage.isTemplate)
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 76, pixelsHigh: 76, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: bitmap) else { throw RenderError.bitmap }
        MoonSparkArtwork.draw(in: context.cgContext, rect: CGRect(x: 0, y: 0, width: 76, height: 76), color: .black)
        var occupied = 0
        for y in 0..<76 { for x in 0..<76 {
            if (bitmap.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.05 {
                occupied += 1; precondition(x > 0 && x < 75 && y > 0 && y < 75)
            }
        } }
        precondition(occupied > 200)
    }
    private static func sample(_ label: String) -> ControllerStatus {
        var state = ControllerState(); state.desiredEnabled = label != "Off"
        state.internet = label == "Recovering" ? .checking : label == "On" ? .verified : .unavailable
        state.pause = label == "Error" ? .setup : label == "Off" ? .stopped : .connectivity
        if label == "Recovering" {
            var outage = OutageLedger(now: Date(timeIntervalSince1970: 0), settings: NightrCore.Settings()); outage.consumed = 2; state.outage = outage
        }
        let now = Date()
        let activity = ActivityObservation(cpuPercent: 38, gpuPercent: 67, runtimes: [
            .init(runtime: .ollama, version: "Sample", observedAt: now, models: [.init(id: "qwen2.5-coder:14b", residency: .loaded, activity: .generating, contextTokens: 32768, memoryBytes: 9_600_000_000, startedAt: now.addingTimeInterval(-42), inferenceExpiresAt: now.addingTimeInterval(15))]),
            .init(runtime: .lmStudio, version: "Sample", observedAt: now, models: [.init(id: "deepseek-r1-distill-7b", residency: .loaded, activity: .idle)]),
            .init(runtime: .llamaCPP, observedAt: now, models: [.init(id: "sample-server", residency: .loaded)]),
            .init(runtime: .mlx, observedAt: now, models: [.init(id: "sample-inventory", residency: .available)])
        ])
        return ControllerStatus(engine: MonitorEngine(state: state, sample: MachineSample(batteryPercent: 100, agentActive: true, setupReady: label != "Error", agentObservation: .active, activity: activity)), holding: label == "On")
    }
    private enum RenderError: Error { case bitmap, missingTitle, generalControl(String) }
}
#endif
