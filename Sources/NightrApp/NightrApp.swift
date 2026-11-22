#if os(macOS)
import SwiftUI
import AppKit
import NightrCore

@main struct NightrApp {
    @MainActor static func main() {
        #if DEBUG
        if let index = CommandLine.arguments.firstIndex(of: "--render-presentations"), CommandLine.arguments.count > index + 1 {
            do { try NativePresentationRenderer.run(output: URL(fileURLWithPath: CommandLine.arguments[index + 1])); exit(0) }
            catch { FileHandle.standardError.write(Data("Offscreen rendering failed: \(error)\n".utf8)); exit(1) }
        }
        #endif
        if let setup = DesktopSetupInvocation(arguments: CommandLine.arguments) {
            switch setup {
            case .desktop: DesktopSetup.runDesktopCommand()
            case .helperOnly: DesktopSetup.runHelperCommand()
            }
        }

        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let delegate = NightrApplicationDelegate(model: AppModel())
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}

struct NightrAppIcon: View {
    private static let icon: NSImage = {
        if let icon = Bundle.main.image(forResource: "Nightr") { return icon }
        return NSImage(size: NSSize(width: 32, height: 32), flipped: false) { rect in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            MoonSparkArtwork.drawAppIcon(in: context, rect: rect)
            return true
        }
    }()
    var body: some View {
        Image(nsImage: Self.icon).renderingMode(.original).resizable().scaledToFit().accessibilityHidden(true)
    }
}
#else
import Foundation
@main struct NightrApp { static func main() { print("Nightr requires macOS 13 or later.") } }
#endif
