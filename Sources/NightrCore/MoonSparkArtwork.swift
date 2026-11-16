#if os(macOS)
import AppKit

/// Approved concept 01. Cubic segments are the SVG's two circular arcs in its
/// original 24 × 24 coordinate system (y down); no system-symbol substitution.
public enum MoonSparkArtwork {
    public static func path() -> CGPath {
        let path = CGMutablePath()
        path.move(to: CGPoint(x: 15.6, y: 3.4))
        path.addCurve(to: CGPoint(x: 6.588128, y: 8.656157), control1: CGPoint(x: 11.709663, y: 2.682969), control2: CGPoint(x: 7.879385, y: 4.916971))
        path.addCurve(to: CGPoint(x: 10.436179, y: 18.353245), control1: CGPoint(x: 5.296871, y: 12.395342), control2: CGPoint(x: 6.932392, y: 16.516855))
        path.addCurve(to: CGPoint(x: 20.6, y: 16), control1: CGPoint(x: 13.939966, y: 20.189635), control2: CGPoint(x: 18.259852, y: 19.189445))
        path.addCurve(to: CGPoint(x: 14.966991, y: 10.943257), control1: CGPoint(x: 18.033981, y: 15.289683), control2: CGPoint(x: 15.949049, y: 13.418044))
        path.addCurve(to: CGPoint(x: 15.6, y: 3.4), control1: CGPoint(x: 13.984933, y: 8.468471), control2: CGPoint(x: 14.219227, y: 5.676504))
        path.closeSubpath()
        path.move(to: CGPoint(x: 19, y: 2))
        for (x, y): (CGFloat, CGFloat) in [(19.8,4.4),(22,5.2),(19.8,6),(19,8.4),(18.2,6),(16,5.2),(18.2,4.4)] { path.addLine(to: CGPoint(x: x, y: y)) }
        path.closeSubpath()
        return path
    }
    public static func draw(in context: CGContext, rect: CGRect, color: NSColor) {
        context.saveGState()
        context.translateBy(x: rect.minX, y: rect.maxY)
        context.scaleBy(x: rect.width / 24, y: -rect.height / 24)
        context.addPath(path()); context.setStrokeColor(color.cgColor)
        context.setLineWidth(1.7); context.setLineCap(.round); context.setLineJoin(.round)
        context.strokePath(); context.restoreGState()
    }
    public static let menuImage: NSImage = {
        let image = NSImage(size: NSSize(width: 19, height: 19), flipped: false) { rect in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            draw(in: context, rect: rect, color: .black); return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Nightr"
        return image
    }()
}
#endif
