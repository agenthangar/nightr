#if os(macOS)
import SwiftUI
import AppKit
import NightrCore

@main struct NightrApp: App {
    @NSApplicationDelegateAdaptor(NightrApplicationDelegate.self) private var applicationDelegate
    @StateObject private var model: AppModel
    init() {
        // Controller-only launches must eagerly boot even though the menu extra
        // is not inserted and SwiftUI never evaluates its content.
        let instance = AppModel()
        _model = StateObject(wrappedValue: instance)
    }
    var body: some Scene {
        MenuBarExtra(isInserted: Binding(get: { model.presentation.menuVisible }, set: { model.menuVisibilityChanged($0) })) {
            VStack(alignment: .leading, spacing: 12) {
                HStack { MoonSpark().frame(width: 23, height: 23); Text("Nightr").font(.headline); Spacer(); Text(model.label).foregroundStyle(.secondary) }
                Button(model.status?.state.desiredEnabled == true ? "Stop" : "Start") {
                    model.command(model.status?.state.desiredEnabled == true ? .stop : .start)
                }.buttonStyle(.borderedProminent).frame(maxWidth: .infinity)
                if let status = model.status {
                    LabeledContent("Internet", value: status.state.internet.rawValue.capitalized)
                    LabeledContent("Agent", value: status.sample.agentActive ? "Active" : "No activity observed")
                    if let battery = status.sample.batteryPercent { LabeledContent("Battery", value: "\(battery)%" + (status.sample.onBattery ? " · Battery" : " · Power adapter")) }
                    if let reason = status.state.pause, status.state.desiredEnabled { Text("Paused: \(reason.rawValue)").font(.callout).foregroundStyle(.secondary) }
                    if let outage = status.state.outage {
                        Text("Hotspot: \(outage.consumed) of \(outage.capturedLimit) attempts").font(.callout)
                        Text(status.verificationEligible ? "Internet checks continue." : "Internet checks are paused.").font(.caption).foregroundStyle(.secondary)
                        HStack {
                            Button(outage.consumed >= outage.capturedLimit ? "Try again" : "Retry now") { model.command(outage.consumed >= outage.capturedLimit ? .tryAgain : .retryNow) }
                            Button("Skip fallback") { model.command(.skipFallback) }
                        }
                        Text("Turn on Personal Hotspot on your phone if the saved network is not broadcasting.").font(.caption).foregroundStyle(.secondary)
                    }
                }
                if let message = model.status?.message { Text(message).font(.callout).foregroundStyle(.red).textSelection(.enabled) }
                if let error = model.error { Text(error).font(.callout).foregroundStyle(.red).textSelection(.enabled) }
                Divider()
                Button("Settings…") { model.openSettings() }
                    .keyboardShortcut(",")
                Button("Set up Nightr…") {
                    do { try DesktopSetup.complete() } catch { model.error = error.localizedDescription }
                }
                Button("macOS Wi-Fi settings…") { DesktopSetup.systemWiFi() }
                Button("Stop and Quit Nightr") { model.quit() }.keyboardShortcut("q")
            }.padding(16).frame(width: 300)
        } label: { MoonSpark().frame(width: 19, height: 19).accessibilityLabel("Nightr, \(model.label)") }
        .menuBarExtraStyle(.window)
    }
}

struct MoonSpark: View {
    var body: some View {
        GeometryReader { g in
            ZStack {
                Image(systemName: "moon.fill").resizable().scaledToFit().frame(width: g.size.width * 0.80).rotationEffect(.degrees(-15)).offset(x: -g.size.width * 0.08, y: g.size.height * 0.05)
                Image(systemName: "sparkle").resizable().scaledToFit().frame(width: g.size.width * 0.42).offset(x: g.size.width * 0.29, y: -g.size.height * 0.28)
            }.frame(width: g.size.width, height: g.size.height)
        }.accessibilityHidden(true)
    }
}
#else
import Foundation
@main struct NightrApp { static func main() { print("Nightr requires macOS 13 or later.") } }
#endif
