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

// Locate the row by its label so changes in height or spacing don't invalidate the check.
func verify(_ view: NSView) throws {
    let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
    view.cacheDisplay(in: view.bounds, to: bitmap)
    let recognition = VNRecognizeTextRequest()
    recognition.recognitionLanguages = ["en-US"]
    try VNImageRequestHandler(cgImage: bitmap.cgImage!).perform([recognition])
    let scale = CGFloat(bitmap.pixelsWide) / view.bounds.width
    let labels = ["Mode", "Display", "Allow sleep below", "Lock Mac"]
    var fieldStart: Int?
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
        if label != "Lock Mac" {
            if let fieldStart { precondition(CGFloat(abs(left - fieldStart)) <= scale, label + " left edge moved") }
            fieldStart = left
        }
    }
}

for enabled in [false, true] {
    session["draft"] = try JSONSerialization.data(withJSONObject: ["battery_protection": enabled])
    let view = Unmanaged<NSView>.fromOpaque(factory(Unmanaged.passUnretained(session).toOpaque())).takeRetainedValue()
    let size = view.fittingSize
    window.contentView = view
    window.setContentSize(size)
    for name in [NSAppearance.Name.aqua, .darkAqua] {
        window.appearance = NSAppearance(named: name)
        RunLoop.main.run(until: Date().addingTimeInterval(0.15))
        view.layoutSubtreeIfNeeded()
        try verify(view)
    }
}
print("Protection control edges match in both appearances with the battery cutoff on and off.")
