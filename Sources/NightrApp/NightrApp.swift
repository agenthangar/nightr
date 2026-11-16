#if os(macOS)
import SwiftUI
import AppKit
import NightrCore

@main struct NightrApp: App {
    @NSApplicationDelegateAdaptor(NightrApplicationDelegate.self) private var applicationDelegate
    @StateObject private var model: AppModel
    init() {
        #if DEBUG
        if let index = CommandLine.arguments.firstIndex(of: "--render-presentations"), CommandLine.arguments.count > index + 1 {
            do { try NativePresentationRenderer.run(output: URL(fileURLWithPath: CommandLine.arguments[index + 1])); exit(0) }
            catch { FileHandle.standardError.write(Data("Offscreen rendering failed: \(error)\n".utf8)); exit(1) }
        }
        #endif
        // Controller-only launches must eagerly boot even though the menu extra
        // is not inserted and SwiftUI never evaluates its content.
        let instance = AppModel()
        _model = StateObject(wrappedValue: instance)
    }
    var body: some Scene {
        MenuBarExtra(isInserted: Binding(get: { model.presentation.menuVisible }, set: { model.menuVisibilityChanged($0) })) {
            NightrPopover(status: model.status, error: model.error,
                command: { model.command($0) }, settings: { model.openSettings() },
                setup: { do { try DesktopSetup.complete() } catch { model.error = error.localizedDescription } },
                quit: { model.quit() }, wifiSettings: { DesktopSetup.systemWiFi() })
        } label: {
            Image(nsImage: MoonSparkArtwork.menuImage)
                .accessibilityLabel("Nightr, \(model.label)")
        }
        .menuBarExtraStyle(.window)
    }
}

struct MoonSpark: View {
    var body: some View {
        Image(nsImage: MoonSparkArtwork.menuImage).resizable().scaledToFit().accessibilityHidden(true)
    }
}
#else
import Foundation
@main struct NightrApp { static func main() { print("Nightr requires macOS 13 or later.") } }
#endif
