import AppKit
import Vision

// Exercise the same view factory as the live host, in an offscreen window.
typealias ViewFactory = @convention(c) (UnsafeMutableRawPointer) -> UnsafeMutableRawPointer
_ = NSApplication.shared
guard let library = dlopen(CommandLine.arguments[1], RTLD_NOW | RTLD_LOCAL),
      let symbol = dlsym(library, "makeNightrSettingsPreview") else { fatalError("Cannot load preview view") }
let factory = unsafeBitCast(symbol, to: ViewFactory.self)
let session: NSMutableDictionary = ["tab": "Protection"]
let window = NSWindow(contentRect: .zero, styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: false)

// A hot reload retains the current tab. Opening Settings selects its destination anew.
do {
    let draft = try JSONSerialization.data(withJSONObject: ["every": 47])
    let state: NSMutableDictionary = ["tab": "Advanced", "draft": draft]
    let view = Unmanaged<NSView>.fromOpaque(factory(Unmanaged.passUnretained(state).toOpaque())).takeRetainedValue()
    window.contentView = view
    window.setContentSize(view.fittingSize)
    func selectedTab(in node: NSView) -> String? {
        if let button = node as? NSButton, button.accessibilityRole() == .radioButton,
           button.accessibilityValue() as? Int == 1 { return button.title }
        return node.subviews.lazy.compactMap(selectedTab).first
    }
    RunLoop.main.run(until: Date().addingTimeInterval(0.15))
    precondition(selectedTab(in: view) == "Advanced")
    for destination in [nil, "Connectivity", nil] as [String?] {
        NotificationCenter.default.post(name: .init("NightrPreview.OpenSettings"), object: nil,
                                        userInfo: destination.map { ["section": $0] })
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        precondition(selectedTab(in: view) == (destination ?? "General"))
        precondition(state["draft"] as? Data == draft)
    }
}
print("Settings opens on General, honors explicit routes and retains the pending draft.")

// Sample ink inside the word and in the checkmark immediately preceding it.
// Keeping the two regions separate catches an icon-only foreground style.
func checkStatusInk(in bitmap: NSBitmapImageRep, viewWidth: CGFloat, label: String, confirmed: Bool) throws {
    let recognition = VNRecognizeTextRequest()
    try VNImageRequestHandler(cgImage: bitmap.cgImage!).perform([recognition])
    let width = CGFloat(bitmap.pixelsWide), height = CGFloat(bitmap.pixelsHigh)
    let scale = width / viewWidth
    for observation in recognition.results ?? [] {
        guard let candidate = observation.topCandidates(1).first,
              let range = candidate.string.range(of: label),
              let bounds = try candidate.boundingBox(for: range)?.boundingBox else { continue }
        let x = bounds.minX * width
        let y = Int((1 - bounds.midY) * height)
        func greenPixels(from left: CGFloat, to right: CGFloat) -> Int {
            var count = 0
            for column in max(0, Int(left))..<min(bitmap.pixelsWide, Int(right)) {
                for row in (y - Int(8 * scale))...(y + Int(8 * scale)) {
                    let c = bitmap.colorAt(x: column, y: row)!.usingColorSpace(.sRGB)!
                    if c.greenComponent - max(c.redComponent, c.blueComponent) > 0.08 { count += 1 }
                }
            }
            return count
        }
        let textInk = greenPixels(from: x + 3 * scale, to: bounds.maxX * width - 2 * scale)
        let iconInk = greenPixels(from: x - 27 * scale, to: x - 2 * scale)
        precondition((textInk > 4) == confirmed, "\(label) text has the wrong status color")
        precondition((iconInk > 4) == confirmed, "\(label) icon has the wrong status color")
        return
    }
    fatalError("Missing rendered status " + label)
}

for appearance in [NSAppearance.Name.aqua, .darkAqua] {
    for mode in ["Automatic", "Ask to Join", "Never", "Unknown"] {
        let state: NSMutableDictionary = ["tab": "Connectivity", "force": false, "joinMode": mode]
        let view = Unmanaged<NSView>.fromOpaque(factory(Unmanaged.passUnretained(state).toOpaque())).takeRetainedValue()
        window.contentView = view
        window.setContentSize(view.fittingSize)
        window.appearance = NSAppearance(named: appearance)
        RunLoop.main.run(until: Date().addingTimeInterval(0.15))
        view.layoutSubtreeIfNeeded()
        let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
        view.cacheDisplay(in: view.bounds, to: bitmap)
        try checkStatusInk(in: bitmap, viewWidth: view.bounds.width, label: "Connected", confirmed: true)
        try checkStatusInk(in: bitmap, viewWidth: view.bounds.width, label: mode, confirmed: mode == "Automatic")
    }
}
print("Connectivity status icons and labels passed in both appearances.")

// Locate the row by its label so changes in height or spacing don't invalidate the check.
func verify(_ view: NSView, forced: Bool) throws {
    func descendants(_ node: NSView) -> [NSView] { [node] + node.subviews.flatMap(descendants) }
    let menus = descendants(view).compactMap { $0 as? NSPopUpButton }
    precondition(!menus.contains { $0.itemTitles.contains("Until I stop") })
    for (label, titles) in [("Display", ["Off", "Dim", "On"])] {
        guard let menu = menus.first(where: { $0.accessibilityLabel() == label }) else { fatalError("Missing menu: " + label) }
        precondition(menu.menu?.items.map(\.title) == titles, "Missing native menu choices: " + label)
    }
    let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
    view.cacheDisplay(in: view.bounds, to: bitmap)
    let recognition = VNRecognizeTextRequest()
    recognition.recognitionLanguages = ["en-US"]
    try VNImageRequestHandler(cgImage: bitmap.cgImage!).perform([recognition])
    let scale = CGFloat(bitmap.pixelsWide) / view.bounds.width
    let visibleText = (recognition.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ")
    precondition(visibleText.contains("Force mode"))
    precondition(visibleText.contains("When a local model is generating"))
    precondition(visibleText.contains("Automatic checks are paused") == forced)
    precondition(visibleText.contains("Keep Mac awake"))
    let buttons = descendants(view).compactMap { $0 as? NSButton }
    for label in ["When an agent is active", "When internet is available", "When a local model is generating"] {
        guard let row = recognition.results?.first(where: { $0.topCandidates(1).first?.string == label }) else {
            fatalError("Missing automatic rule: " + label)
        }
        let y = (view.isFlipped ? 1 - row.boundingBox.midY : row.boundingBox.midY) * view.bounds.height
        let toggle = buttons.first { button in
            let frame = button.convert(button.bounds, to: view)
            return abs(frame.midY - y) < 5 && abs(frame.maxX - (view.bounds.maxX - 22)) < 2
        }
        precondition(toggle?.isEnabled == !forced, label + " must follow Force mode")
    }
    let labels = ["When an agent is active", "Display", "Allow sleep below", "Lock Mac"]
    for label in labels {
        guard let row = recognition.results?.first(where: {
            guard let text = $0.topCandidates(1).first?.string else { return false }
            return label == "Allow sleep below" ? text.hasSuffix(label) : text == label
        }) else { fatalError("Missing Protection row: " + label) }
        let y = Int((1 - row.boundingBox.midY) * CGFloat(bitmap.pixelsHigh))
        func color(_ x: Int) -> NSColor { bitmap.colorAt(x: x, y: y)!.usingColorSpace(.sRGB)! }
        let middle = bitmap.pixelsWide * 3 / 5
        let background = color(middle)
        let ink = (middle..<bitmap.pixelsWide).filter { x in
            let c = color(x)
            return max(abs(c.redComponent - background.redComponent), abs(c.greenComponent - background.greenComponent),
                       abs(c.blueComponent - background.blueComponent)) > 0.015
        }
        guard let left = ink.first, let right = ink.last else { fatalError("Missing control: " + label) }
        let inset = CGFloat(bitmap.pixelsWide - right - 1) / scale
        precondition(abs(inset - 22) <= 1, "\(label) trailing inset: \(inset) pt")
        if label == "Display" {
            let width = CGFloat(right - left + 1) / scale
            let menu = menus.first { $0.accessibilityLabel() == label }!
            let font = NSFont.systemFont(ofSize: 14)
            let titleWidth = menu.itemTitles.map { ($0 as NSString).size(withAttributes: [.font: font]).width }.max()!
            // Horizontal insets, gap and chevrons add about 32 pt beyond the widest title.
            precondition((25...38).contains(width - titleWidth), "\(label) width \(width), longest title \(titleWidth)")
            let bounds = menu.convert(menu.bounds, to: view)
            for x in [CGFloat(left) / scale + 2, CGFloat(right) / scale - 2] {
                let point = view.convert(NSPoint(x: x, y: bounds.midY), to: view.superview)
                let hit = view.hitTest(point)
                precondition(hit?.isDescendant(of: menu) == true, "\(label) misses the visible control at \(x)")
            }
        }
    }
}

for enabled in [false, true] {
    session["force"] = enabled
    session["draft"] = try JSONSerialization.data(withJSONObject: ["battery_protection": enabled, "dim": enabled])
    let view = Unmanaged<NSView>.fromOpaque(factory(Unmanaged.passUnretained(session).toOpaque())).takeRetainedValue()
    let size = view.fittingSize
    window.contentView = view
    window.setContentSize(size)
    for name in [NSAppearance.Name.aqua, .darkAqua] {
        window.appearance = NSAppearance(named: name)
        RunLoop.main.run(until: Date().addingTimeInterval(0.15))
        view.layoutSubtreeIfNeeded()
        try verify(view, forced: enabled)
        if let directory = ProcessInfo.processInfo.environment["NIGHTR_PREVIEW_CAPTURES"] {
            let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
            view.cacheDisplay(in: view.bounds, to: bitmap)
            let file = "protection-" + (enabled ? "force" : "usual") + (name == .aqua ? "-light.png" : "-dark.png")
            try bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: directory).appendingPathComponent(file))
        }
    }
    do {
        let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let request = VNRecognizeTextRequest()
        try VNImageRequestHandler(cgImage: bitmap.cgImage!).perform([request])
        guard let heading = request.results?.first(where: {
            $0.topCandidates(1).first?.string.contains("Force mode") == true
        }) else { fatalError("Missing Force mode heading") }
        let rowY = (view.isFlipped ? 1 - heading.boundingBox.midY : heading.boundingBox.midY) * view.bounds.height
        func checkboxOnHeading(in node: NSView) -> NSButton? {
            if let button = node as? NSButton {
                let bounds = button.convert(button.bounds, to: view)
                if abs(bounds.midY - rowY) < 14 && abs(bounds.maxX - (view.bounds.maxX - 22)) < 2 { return button }
            }
            return node.subviews.lazy.compactMap(checkboxOnHeading).first
        }
        let pending = session["draft"] as? Data
        guard let checkbox = checkboxOnHeading(in: view), checkbox.state == (enabled ? .on : .off) else { fatalError("Missing Force mode control") }
        window.setFrameOrigin(NSPoint(x: -10000, y: -10000))
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil) }
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        let point = checkbox.convert(NSPoint(x: checkbox.bounds.midX, y: checkbox.bounds.midY), to: nil)
        let down = NSEvent.mouseEvent(with: .leftMouseDown, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1)!
        let up = NSEvent.mouseEvent(with: .leftMouseUp, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil, eventNumber: 2, clickCount: 1, pressure: 0)!
        NSApp.postEvent(up, atStart: true)
        window.sendEvent(down)
        if let next = NSApp.nextEvent(matching: .leftMouseUp, until: Date(), inMode: .default, dequeue: true) {
            window.sendEvent(next)
        }
        RunLoop.main.run(until: Date().addingTimeInterval(0.15))
        precondition(session["force"] as? Bool == !enabled)
        precondition(session["draft"] as? Data == pending
                     && checkboxOnHeading(in: view)?.state == (enabled ? .off : .on))
    }

}
print("Protection control edges match in both appearances with the battery cutoff on and off.")


guard let paneSymbol = dlsym(library, "makeNightrPanePreview") else { fatalError("Missing main pane") }
let paneFactory = unsafeBitCast(paneSymbol, to: ViewFactory.self)
var paneAnchors: [CGFloat]?
for (forced, enabled) in [(true, true), (false, true), (false, false)] {
    let paneSession: NSMutableDictionary = ["force": forced, "baseEnabled": enabled]
    let view = Unmanaged<NSView>.fromOpaque(paneFactory(Unmanaged.passUnretained(paneSession).toOpaque())).takeRetainedValue()
    window.contentView = view
    window.setContentSize(view.fittingSize)
    RunLoop.main.run(until: Date().addingTimeInterval(0.15))
    view.layoutSubtreeIfNeeded()
    let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
    view.cacheDisplay(in: view.bounds, to: bitmap)
    let request = VNRecognizeTextRequest()
    try VNImageRequestHandler(cgImage: bitmap.cgImage!).perform([request])
    let text = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ").lowercased()
    precondition(text.contains(forced ? "end force mode" : "force mode") && text.contains(enabled ? "stop protection" : "start protection"), text)
    if forced { precondition(text.components(separatedBy: "checks paused").count == 3, text) }
    else { precondition(text.contains("active"), text) }
    // Compare the same landmarks in points, independent of Retina scale.
    let landmarks = ["Nightr", enabled ? "Stop protection" : "Start protection", "Local models"]
    let anchors = landmarks.map { label -> CGFloat in
        guard let match = request.results?.first(where: {
            $0.topCandidates(1).first?.string.localizedCaseInsensitiveContains(label) == true
        }) else { fatalError("Missing pane landmark: " + label) }
        return (1 - match.boundingBox.midY) * view.bounds.height
    }
    if let paneAnchors {
        precondition(zip(anchors, paneAnchors).allSatisfy { abs($0 - $1) <= 1.5 },
                     "Pane landmarks moved after toggling: " + String(describing: anchors))
    } else { paneAnchors = anchors }
    if forced {
        func leadingEdge(of phrase: String) throws -> CGFloat {
            for observation in request.results ?? [] {
                guard let candidate = observation.topCandidates(1).first,
                      let range = candidate.string.range(of: phrase),
                      let box = try candidate.boundingBox(for: range) else { continue }
                // Vision may include the gap after the bolt. Measure actual glyph ink.
                let scale = CGFloat(bitmap.pixelsWide) / view.bounds.width
                let bounds = box.boundingBox
                let top = max(0, Int((1 - bounds.maxY) * CGFloat(bitmap.pixelsHigh)))
                let bottom = min(bitmap.pixelsHigh, Int((1 - bounds.minY) * CGFloat(bitmap.pixelsHigh)))
                let start = max(0, Int(bounds.minX * CGFloat(bitmap.pixelsWide) - 2 * scale))
                let end = min(bitmap.pixelsWide, Int(bounds.maxX * CGFloat(bitmap.pixelsWide)))
                for x in start..<end {
                    for y in top..<bottom {
                        guard let ink = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB),
                              let background = bitmap.colorAt(x: 1, y: y)?.usingColorSpace(.sRGB) else { continue }
                        if abs(ink.redComponent - background.redComponent) > 0.2 { return CGFloat(x) / scale }
                    }
                }
            }
            fatalError("Missing status text: " + phrase)
        }
        let titleEdge = try leadingEdge(of: "Force mode")
        let detailEdge = try leadingEdge(of: "Automatic checks are paused")
        precondition(abs(titleEdge - detailEdge) <= 3, "Force mode title and description must align")
    }
    if let directory = ProcessInfo.processInfo.environment["NIGHTR_PREVIEW_CAPTURES"],
       let data = bitmap.representation(using: .png, properties: [:]) {
        try data.write(to: URL(fileURLWithPath: directory).appendingPathComponent(forced ? "force.png" : enabled ? "automatic.png" : "stopped.png"))
    }
}
print("Native choices and main pane actions passed.")

func stepper(in view: NSView) -> NSStepper? {
    if let stepper = view as? NSStepper { return stepper }
    return view.subviews.lazy.compactMap { stepper(in: $0) }.first
}
for (section, key) in [("Advanced", "retries"), ("Connectivity", "hotspot_attempts")] {
    let draft = try JSONSerialization.data(withJSONObject: ["hotspot": true, "hotspot_ssid": "Sample hotspot"])
    let session: NSMutableDictionary = ["tab": section, "draft": draft]
    let view = Unmanaged<NSView>.fromOpaque(factory(Unmanaged.passUnretained(session).toOpaque())).takeRetainedValue()
    window.contentView = view
    window.setContentSize(view.fittingSize)
    RunLoop.main.run(until: Date().addingTimeInterval(0.15))
    guard let control = stepper(in: view), control.isEnabled else { fatalError("Missing active stepper in " + section) }
    let edge = control.convert(control.bounds, to: view).maxX
    precondition(abs(view.bounds.maxX - edge - 22) <= 2, "Stepper must align with the other controls in " + section)
    if let directory = ProcessInfo.processInfo.environment["NIGHTR_PREVIEW_CAPTURES"] {
        let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
        view.cacheDisplay(in: view.bounds, to: bitmap)
        try bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: directory).appendingPathComponent(section + "-stepper.png"))
    }
    for (direction, expected) in [(1, 4), (-1, 3)] {
        control.doubleValue += Double(direction) * control.increment
        precondition(control.sendAction(control.action, to: control.target))
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        let values = try JSONSerialization.jsonObject(with: session["draft"] as! Data) as! [String: Any]
        precondition(values[key] as? Int == expected, "Stepper failed to update " + key)
        if section == "Advanced" {
            let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
            view.cacheDisplay(in: view.bounds, to: bitmap)
            let request = VNRecognizeTextRequest()
            try VNImageRequestHandler(cgImage: bitmap.cgImage!).perform([request])
            let labels = request.results?.compactMap { $0.topCandidates(1).first?.string } ?? []
            let displayedWait = expected == 4 ? "22 min 30 sec" : "18 min 30 sec"
            precondition(labels.contains { $0.contains(displayedWait) }, "Missing scheduled wait: " + displayedWait)
        }
    }
}
print("Both count fields increment and decrement the Settings draft.")


// Select each Nearby fixture through the real native list, including transitions
// away from the protected network so a stale password field is caught as well.
for appearance in [NSAppearance.Name.aqua, .darkAqua] {
    window.appearance = NSAppearance(named: appearance)
    guard let symbol = dlsym(library, "makeNightrNetworkChooserPreview") else { fatalError("Missing network chooser") }
    let factory = unsafeBitCast(symbol, to: ViewFactory.self)
    let view = Unmanaged<NSView>.fromOpaque(factory(Unmanaged.passUnretained(session).toOpaque())).takeRetainedValue()
    window.contentView = view
    window.setContentSize(view.fittingSize)
    func settle() {
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        view.layoutSubtreeIfNeeded()
    }
    func first<T: NSView>(_ type: T.Type, in node: NSView) -> T? {
        (node as? T) ?? node.subviews.lazy.compactMap { first(type, in: $0) }.first
    }
    settle()
    guard let tabs = first(NSSegmentedControl.self, in: view),
          let nearby = (0..<tabs.segmentCount).first(where: { tabs.label(forSegment: $0) == "Nearby" }) else {
        fatalError("Missing Nearby tab")
    }
    // The section headings, source selector and footer stay on the same grid.
    var baseline: [CGPoint]?
    for (tab, heading) in [("Saved", "Saved networks"), ("Nearby", "Nearby networks"), ("Manual", "Network details")] {
        guard let index = (0..<tabs.segmentCount).first(where: { tabs.label(forSegment: $0) == tab }) else { fatalError(tab) }
        tabs.selectedSegment = index
        precondition(tabs.sendAction(tabs.action, to: tabs.target))
        settle()
        let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let request = VNRecognizeTextRequest()
        try VNImageRequestHandler(cgImage: bitmap.cgImage!).perform([request])
        let anchors = try [heading, "Cancel"].map { label -> CGPoint in
            guard let row = request.results?.first(where: { $0.topCandidates(1).first?.string == label }) else {
                throw NSError(domain: "Chooser layout: missing " + label, code: 1)
            }
            return CGPoint(x: row.boundingBox.minX * view.bounds.width, y: row.boundingBox.midY * view.bounds.height)
        }
        if tab == "Manual" {
            guard let field = first(NSSecureTextField.self, in: view) else { fatalError("Missing Manual password input") }
            precondition(field.accessibilityLabel() == "Password for Sample guest")
        }
        if let dir = ProcessInfo.processInfo.environment["NIGHTR_PREVIEW_CAPTURES"] {
            let suffix = appearance == .aqua ? "light" : "dark"
            let file = URL(fileURLWithPath: dir).appendingPathComponent("chooser-\(tab.lowercased())-\(suffix).png")
            try bitmap.representation(using: .png, properties: [:])?.write(to: file)
        }
        let tabFrame = tabs.convert(tabs.bounds, to: view)
        let positions = anchors + [CGPoint(x: tabFrame.minX, y: tabFrame.minY)]
        if let baseline {
            for (a, b) in zip(baseline, positions) {
                precondition(abs(a.x - b.x) <= 2 && abs(a.y - b.y) <= 2, "Chooser alignment changed on " + tab)
            }
        } else { baseline = positions }
    }
    // Real edits to the AppKit field editor must not replace or populate the masked field.
    func nameField(in node: NSView) -> NSTextField? {
        if let field = node as? NSTextField, field.placeholderString == "Exact Wi-Fi name" { return field }
        return node.subviews.lazy.compactMap(nameField).first
    }
    guard let name = nameField(in: view), let password = first(NSSecureTextField.self, in: view),
          window.makeFirstResponder(name), let editor = name.currentEditor() as? NSTextView else {
        fatalError("Missing editable Manual network fields")
    }
    password.stringValue = "fixture-only"
    for digit in ["1", "2", "3"] {
        editor.insertText(digit, replacementRange: NSRange(location: (editor.string as NSString).length, length: 0))
        RunLoop.main.run(until: Date().addingTimeInterval(0.04))
        precondition(first(NSSecureTextField.self, in: view) === password, "Password field flickered during SSID entry")
        precondition(password.stringValue.isEmpty, "Password survived a network name change")
    }
    settle()
    precondition(password.accessibilityLabel() == "Password for Sample guest123")
    precondition(first(NSSecureTextField.self, in: view) === password)
    window.makeFirstResponder(nil)
    tabs.selectedSegment = nearby
    precondition(tabs.sendAction(tabs.action, to: tabs.target))
    settle()
    guard let table = first(NSTableView.self, in: view), table.numberOfRows == 3 else { fatalError("Missing nearby samples") }
    // Sample records have equal signal and are sorted by exact SSID.
    for row in [1, 2, 0, 1] {
        table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        settle()
        let field = first(NSSecureTextField.self, in: view)
        if row == 1 { precondition(field?.accessibilityLabel() == "Password for Sample guest") }
        else { precondition(field == nil) }
    }
}
print("Nearby prompts for the unsaved secured network and skips saved and open networks.")

// Follow a secured Nearby selection through the simulated Settings transaction.
do {
    let state: NSMutableDictionary = ["draft": try JSONSerialization.data(withJSONObject: ["hotspot_ssid": "Sample guest"])]
    let chooserFactory = unsafeBitCast(dlsym(library, "makeNightrNetworkChooserPreview")!, to: ViewFactory.self)
    func show(_ make: ViewFactory) -> NSView {
        let view = Unmanaged<NSView>.fromOpaque(make(Unmanaged.passUnretained(state).toOpaque())).takeRetainedValue()
        window.contentView = view
        window.setContentSize(view.fittingSize)
        RunLoop.main.run(until: Date().addingTimeInterval(0.25))
        return view
    }
    func find<T: NSView>(_ type: T.Type, in view: NSView) -> T? {
        (view as? T) ?? view.subviews.lazy.compactMap { find(type, in: $0) }.first
    }
    func textBoxes(in view: NSView) throws -> [VNRecognizedTextObservation] {
        let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let request = VNRecognizeTextRequest()
        try VNImageRequestHandler(cgImage: bitmap.cgImage!).perform([request])
        return request.results ?? []
    }
    func click(_ label: String, in view: NSView) throws {
        guard let box = try textBoxes(in: view).first(where: { $0.topCandidates(1).first?.string == label })?.boundingBox else {
            fatalError("Missing action: " + label)
        }
        let point = view.convert(NSPoint(x: box.midX * view.bounds.width, y: (view.isFlipped ? 1 - box.midY : box.midY) * view.bounds.height), to: nil)
        clickPoint(point)
    }
    func clickPoint(_ point: NSPoint) {
        func mouse(_ type: NSEvent.EventType) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                               windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1)!
        }
        NSApp.postEvent(mouse(.leftMouseUp), atStart: true)
        window.sendEvent(mouse(.leftMouseDown))
        if let up = NSApp.nextEvent(matching: .leftMouseUp, until: Date(), inMode: .default, dequeue: true) { window.sendEvent(up) }
        RunLoop.main.run(until: Date().addingTimeInterval(0.15))
    }
    window.setFrameOrigin(NSPoint(x: -10000, y: -10000))
    window.makeKeyAndOrderFront(nil)
    defer { window.orderOut(nil) }
    let chooser = show(chooserFactory)
    let tabs = find(NSSegmentedControl.self, in: chooser)!
    tabs.selectedSegment = (0..<tabs.segmentCount).first(where: { tabs.label(forSegment: $0) == "Nearby" })!
    precondition(tabs.sendAction(tabs.action, to: tabs.target))
    RunLoop.main.run(until: Date().addingTimeInterval(0.25))
    find(NSTableView.self, in: chooser)!.selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false)
    RunLoop.main.run(until: Date().addingTimeInterval(0.2))
    let password = find(NSSecureTextField.self, in: chooser)!
    func enterFixture(in field: NSSecureTextField, view: NSView) throws {
        let frame = field.convert(field.bounds, to: view)
        if let directory = ProcessInfo.processInfo.environment["NIGHTR_PREVIEW_CAPTURES"] {
            let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
            view.cacheDisplay(in: view.bounds, to: bitmap)
            try bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: directory).appendingPathComponent("nearby-empty.png"))
        }
        precondition(frame.width >= 100 && frame.height >= 14 && view.bounds.contains(frame), "Unusable password field frame: " + NSStringFromRect(frame))
        clickPoint(view.convert(NSPoint(x: frame.midX, y: frame.midY), to: nil))
        guard let editor = field.currentEditor(), window.firstResponder === editor else {
            fatalError("Clicking the Nearby password field did not focus its editor")
        }
        for character in "fixture-only" {
            let key = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                                       timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                       context: nil, characters: String(character), charactersIgnoringModifiers: String(character),
                                       isARepeat: false, keyCode: 0)!
            window.sendEvent(key)
        }
        precondition(editor.string == "fixture-only", "Nearby password field did not accept typing")
    }
    try enterFixture(in: password, view: chooser)
    RunLoop.main.run(until: Date().addingTimeInterval(0.1))
    try click("Use network", in: chooser)
    func checkSavedSelection(in view: NSView) throws {
        let labels = try textBoxes(in: view).compactMap { $0.topCandidates(1).first?.string.lowercased() }
        precondition(labels.contains { $0.contains("saved networks") } && labels.contains { $0.contains("sample guest") })
        precondition(!labels.contains { $0.contains("password") }, "An available credential should not add a notice on Saved")
        precondition(find(NSSecureTextField.self, in: view) == nil)
    }
    let pending = show(chooserFactory)
    try checkSavedSelection(in: pending)
    try click("Use network", in: pending)
    precondition(state["previewCredentialEdit"] as? String == "password")
    try click("Save", in: show(factory))
    let reopened = show(chooserFactory)
    try checkSavedSelection(in: reopened)
    if let directory = ProcessInfo.processInfo.environment["NIGHTR_PREVIEW_CAPTURES"] {
        let bitmap = reopened.bitmapImageRepForCachingDisplay(in: reopened.bounds)!
        reopened.cacheDisplay(in: reopened.bounds, to: bitmap)
        try bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: directory).appendingPathComponent("saved-selection.png"))
    }
    let source = find(NSSegmentedControl.self, in: reopened)!
    source.selectedSegment = (0..<source.segmentCount).first(where: { source.label(forSegment: $0) == "Nearby" })!
    precondition(source.sendAction(source.action, to: source.target))
    RunLoop.main.run(until: Date().addingTimeInterval(0.25))
    find(NSTableView.self, in: reopened)!.selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false)
    RunLoop.main.run(until: Date().addingTimeInterval(0.2))
    precondition(find(NSSecureTextField.self, in: reopened) == nil)
    try click("Change password", in: reopened)
    guard let replacement = find(NSSecureTextField.self, in: reopened) else { fatalError("Missing replacement password field") }
    precondition(replacement.stringValue.isEmpty)
    try enterFixture(in: replacement, view: reopened)
    if let directory = ProcessInfo.processInfo.environment["NIGHTR_PREVIEW_CAPTURES"] {
        let bitmap = reopened.bitmapImageRepForCachingDisplay(in: reopened.bounds)!
        reopened.cacheDisplay(in: reopened.bounds, to: bitmap)
        try bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: directory).appendingPathComponent("nearby-entry.png"))
    }
    try click("Use network", in: reopened)
    precondition(state["previewCredentialEdit"] as? String == "password", "Nearby replacement did not stage a password")
}
print("Nearby password remains pending on reopen and available after Settings Save.")
