// Release-build asset generation only. Renders offscreen; never opens a window.
import AppKit

guard CommandLine.arguments.count == 2 else { fatalError("usage: render_icon.swift OUTPUT.icns") }
let output = URL(fileURLWithPath: CommandLine.arguments[1])
let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Nightr-\(UUID()).iconset")
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: directory) }

func render(_ pixels: Int) throws -> Data {
    let size = CGFloat(pixels)
    guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
        let context = NSGraphicsContext(bitmapImageRep: bitmap) else { fatalError("Cannot create icon bitmap") }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    let cg = context.cgContext
    cg.scaleBy(x: size / 1024, y: size / 1024)
    NSColor(calibratedRed: 0.08, green: 0.085, blue: 0.09, alpha: 1).setFill()
    NSBezierPath(roundedRect: NSRect(x: 40, y: 40, width: 944, height: 944), xRadius: 210, yRadius: 210).fill()
    let amber = NSColor(calibratedRed: 242/255, green: 169/255, blue: 59/255, alpha: 1)
    // Same moon and awake spark composition as the native menu-bar mark.
    for (symbol, frame) in [("moon.fill", NSRect(x: 190, y: 180, width: 590, height: 640)),
                            ("sparkle", NSRect(x: 655, y: 655, width: 200, height: 200))] {
        guard let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) else { fatalError("Missing system icon") }
        let tinted = NSImage(size: image.size)
        tinted.lockFocus()
        amber.setFill(); NSRect(origin: .zero, size: image.size).fill()
        image.draw(at: .zero, from: .zero, operation: .destinationIn, fraction: 1)
        tinted.unlockFocus()
        tinted.draw(in: frame)
    }
    cg.flush()
    NSGraphicsContext.restoreGraphicsState()
    guard let png = bitmap.representation(using: .png, properties: [:]) else { fatalError("Cannot encode icon") }
    return png
}
for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let suffix = scale == 2 ? "@2x" : ""
        let url = directory.appendingPathComponent("icon_\(points)x\(points)\(suffix).png")
        try render(points * scale).write(to: url)
    }
}
let process = Process()
process.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
process.arguments = ["-c", "icns", directory.path, "-o", output.path]
try process.run(); process.waitUntilExit()
guard process.terminationStatus == 0 else { fatalError("iconutil failed") }
