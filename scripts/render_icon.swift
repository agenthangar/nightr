// Release-build asset generation only. Renders offscreen; never opens a window.
import AppKit

@main struct IconRenderer {
static func main() throws {
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
    let background = NSBezierPath(roundedRect: NSRect(x: 40, y: 40, width: 944, height: 944), xRadius: 210, yRadius: 210)
    let gradient = NSGradient(starting: NSColor(calibratedRed: 1, green: 215/255, blue: 137/255, alpha: 1),
                              ending: NSColor(calibratedRed: 213/255, green: 146/255, blue: 45/255, alpha: 1))!
    gradient.draw(in: background, angle: -45)
    MoonSparkArtwork.draw(in: cg, rect: CGRect(x: 190, y: 190, width: 644, height: 644),
                          color: NSColor(calibratedRed: 51/255, green: 39/255, blue: 20/255, alpha: 1))
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

}
}
