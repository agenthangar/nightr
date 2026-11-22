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
        draft.batteryProtection = true
        for dark in [false, true] {
            let scheme: ColorScheme = dark ? .dark : .light
            let suffix = dark ? "dark" : "light"
            for section in NightrSettingsSection.allCases {
                let view = SettingsView(section: .constant(section), status: sample("On"), initialDraft: draft, notificationStatus: .authorized)
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
                if section != .general, let scroll = descendants(frameView).compactMap({ $0 as? NSScrollView }).first,
                   let document = scroll.documentView {
                    let bottom = document.isFlipped ? document.bounds.maxY - scroll.contentView.bounds.height : document.bounds.minY
                    scroll.contentView.scroll(to: NSPoint(x: 0, y: max(0, bottom)))
                    scroll.reflectScrolledClipView(scroll.contentView)
                    try capture(frameView, to: output.appendingPathComponent("settings-\(section.rawValue.lowercased())-bottom-\(suffix).png"))
                }
                try checkToolbarKeyboard(frameView)
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
        precondition(window.frame.size == NSSize(width: 600, height: 590), "Settings window size drifted from the approved preview")
        guard section == .general else { return }
        // Read the rendered pane so unexpected SwiftUI-only rows are covered as well.
        let request = VNRecognizeTextRequest()
        request.recognitionLanguages = ["en-US"]
        try VNImageRequestHandler(url: capture).perform([request])
        let labels = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ").lowercased()
        for expected in ["launch app at login", "desktop notification prompt"] where !labels.contains(expected) {
            throw RenderError.generalControl(expected)
        }
        for extra in ["power helper", "set up nightr"] where labels.contains(extra) {
            throw RenderError.generalControl(extra)
        }
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
