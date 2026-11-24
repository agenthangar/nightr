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

#else
import Foundation
@main struct NightrApp { static func main() { print("Nightr requires macOS 13 or later.") } }
#endif
