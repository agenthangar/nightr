#if os(macOS)
import SwiftUI
import NightrCore

/// Presentation accepts observations and actions only. Offscreen fixtures use
/// this same view without constructing an app, controller or settings store.
struct NightrPopover: View {
    let status: ControllerStatus?
    let error: String?
    var command: (ControllerCommand) -> Void = { _ in }
    var settings: () -> Void = {}
    var setup: () -> Void = {}
    var quit: () -> Void = {}
    var wifiSettings: () -> Void = {}
    private var state: GUIProtectionSummary { GUIProtectionSummary(status: status, error: error) }
    private var enabled: Bool { status?.state.desiredEnabled == true }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                MoonSpark().frame(width: 23, height: 23)
                Text("Nightr").font(.system(size: 16, weight: .semibold))
                Spacer()
                Image(systemName: "power").foregroundStyle(.secondary).accessibilityHidden(true)
            }
            HStack(spacing: 8) {
                Image(systemName: state.symbol).font(.system(size: 21))
                Text(state.label).font(.system(size: 31, weight: .medium))
            }.padding(.top, 20)
            Text(state.detail).font(.system(size: 12)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true).padding(.top, 5).padding(.bottom, 16)
            Button { command(enabled ? .stop : .start) } label: {
                Text(enabled ? "Stop protection" : "Start protection").fontWeight(.semibold)
                    .frame(maxWidth: .infinity).padding(.vertical, 9)
                    .background(enabled ? Color.primary.opacity(0.08) : Color.nightrButtonAmber, in: RoundedRectangle(cornerRadius: 7))
                    .overlay(RoundedRectangle(cornerRadius: 7).stroke(Color.primary.opacity(0.08)))
            }.buttonStyle(.plain)
                .foregroundColor(enabled ? .primary : Color(red: 0.15, green: 0.11, blue: 0.04))
            VStack(spacing: 11) {
                diagnostic("Internet", state.internet)
                diagnostic("Agent", status.map { $0.sample.agentActive ? "Active" : "No activity observed" } ?? "Not checked")
                diagnostic("Battery", status?.sample.batteryPercent.map { "\($0)% · \(status?.sample.onBattery == true ? "Battery" : "Power adapter")" } ?? "Not checked")
                diagnostic("Lid", status.map { $0.sample.lidClosed ? "Closed" : "Open" } ?? "Not checked")
            }.padding(.top, 18)
            if let outage = status?.state.outage {
                Divider().padding(.vertical, 14)
                Text("Hotspot: \(outage.consumed) of \(outage.capturedLimit) attempts used").font(.system(size: 12, weight: .medium))
                Text(status?.verificationEligible == true ? "Internet checks continue." : "Internet checks are paused.")
                    .font(.system(size: 12)).foregroundStyle(.secondary).padding(.top, 4)
                Text("Turn on Personal Hotspot on your phone if the saved network is not broadcasting.")
                    .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true).padding(.top, 6)
                HStack {
                    Button(outage.consumed >= outage.capturedLimit ? "Try again" : "Retry now") {
                        command(outage.consumed >= outage.capturedLimit ? .tryAgain : .retryNow)
                    }
                    Button("Skip fallback") { command(.skipFallback) }
                }.controlSize(.small).padding(.top, 9)
                Button("Wi-Fi settings…", action: wifiSettings).controlSize(.small).padding(.top, 6)
            }
            if let message = error ?? status?.message {
                Text(message).font(.system(size: 12)).foregroundStyle(.red).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true).padding(.top, 12)
            }
            if status?.sample.setupReady != true {
                Button("Set up Nightr…", action: setup).controlSize(.small).padding(.top, 12)
            }
            Divider().padding(.vertical, 14)
            HStack {
                Button("Settings…", action: settings).keyboardShortcut(",")
                Spacer()
                Button("Stop and Quit", action: quit).keyboardShortcut("q")
            }.buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(.secondary)
        }.padding(18).frame(width: 318).background(Color(nsColor: .windowBackgroundColor))
    }
    private func diagnostic(_ name: String, _ value: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(name).foregroundStyle(.secondary)
            Spacer(minLength: 6)
            Text(value).multilineTextAlignment(.trailing).fixedSize(horizontal: false, vertical: true)
        }.font(.system(size: 12))
    }
}
#endif
