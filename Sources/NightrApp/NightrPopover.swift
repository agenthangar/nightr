#if os(macOS)
import SwiftUI
import NightrCore

/// Presentation accepts observations and actions only. Offscreen fixtures use
/// this same view without constructing an app, controller or settings store.
struct NightrPopover: View {
    let status: ControllerStatus?
    let error: String?
    var helperStatus: DesktopServiceStatus? = nil
    var setupError: String? = nil
    var command: (ControllerCommand) -> Void = { _ in }
    var settings: () -> Void = {}
    var setup: () -> Void = {}
    var quit: () -> Void = {}
    var wifiSettings: () -> Void = {}
    private var state: GUIProtectionSummary { GUIProtectionSummary(status: status, error: error) }
    private var forced: Bool { status?.forceMode == true }
    private var enabled: Bool { status?.state.desiredEnabled == true }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                NightrAppIcon().frame(width: 23, height: 23)
                Text("Nightr").font(.system(size: 16, weight: .semibold))
                Spacer()
            }
            VStack(alignment: .leading, spacing: 5) {
                Text(state.label)
                    .font(.system(size: 26, weight: .semibold))
                    .accessibilityAddTraits(.isHeader)
                    .padding(.leading, 31)
                    .overlay(alignment: .leading) {
                        Image(systemName: state.symbol).font(.system(size: 21))
                            .frame(width: 23).accessibilityHidden(true)
                    }
                Text(state.detail).font(.system(size: 13)).foregroundStyle(Color.nightrMuted)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(minHeight: 32, alignment: .topLeading)
                    .padding(.leading, 31)
            }
            .foregroundStyle(forced && state.activelyProtecting ? Color.nightrAmber : Color.nightrInk)
            .padding(.top, 22).padding(.bottom, 14)
            HStack(spacing: 8) {
                Button { command(enabled ? .stop : .start) } label: {
                    Text(enabled ? "Stop protection" : "Start protection").frame(maxWidth: .infinity)
                }.buttonStyle(SettingsActionStyle(primary: !enabled))
                Button { command(forced ? .endForce : .beginForce) } label: {
                    Group {
                        if forced { Text("End force mode") }
                        else { Label("Force mode", systemImage: "bolt.fill") }
                    }.frame(maxWidth: .infinity)
                }.buttonStyle(SettingsActionStyle(primary: forced))
                    .help(forced ? "Return to your previous protection state" : "Keep awake until stopped")
                    .disabled(!forced && (status?.state.pause == .ownership || status?.state.pause == .crashLimit))
            }.disabled(status == nil && error == nil)
            Divider().padding(.vertical, 20)
            LocalModelsView(observation: status?.sample.activity)
            Divider().padding(.top, 20)
            VStack(spacing: 14) {
                diagnostic("Internet", state.internet == "Verified" ? "Connected" : state.internet,
                           verified: state.internet == "Verified", pending: state.internet == "Checking…")
                if state.showsActiveAgent { diagnostic("Agent", "Active", verified: true) }
                diagnostic("Battery", status?.sample.batteryPercent.map { "\($0)%, \(status?.sample.onBattery == true ? "Battery" : "Power adapter")" } ?? "Not checked")
                diagnostic("Lid", status.map { $0.sample.lidClosed ? "Closed" : "Open" } ?? "Not checked")
                HardwareMeters(observation: status?.sample.activity)
            }.padding(.top, 20)
            if let outage = status?.state.outage {
                Divider().padding(.vertical, 20)
                Text("Hotspot: \(outage.consumed) of \(outage.capturedLimit) attempts used").font(.system(size: 13, weight: .medium))
                Text(status?.verificationEligible == true ? "Internet checks continue." : "Internet checks are paused.")
                    .font(.system(size: 13)).foregroundStyle(Color.nightrMuted).padding(.top, 4)
                Text("Turn on Personal Hotspot on your phone if the saved network is not broadcasting.")
                    .font(.system(size: 13)).foregroundStyle(Color.nightrMuted).fixedSize(horizontal: false, vertical: true).padding(.top, 6)
                HStack {
                    Button(outage.consumed >= outage.capturedLimit ? "Try again" : "Retry now") {
                        command(outage.consumed >= outage.capturedLimit ? .tryAgain : .retryNow)
                    }
                    Button("Skip fallback") { command(.skipFallback) }
                }.controlSize(.small).padding(.top, 12)
                Button("Wi-Fi settings…", action: wifiSettings).controlSize(.small).padding(.top, 6)
            }
            if let message = error ?? status?.message {
                Text(message).font(.system(size: 13)).foregroundStyle(.red).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true).padding(.top, 12)
            }
            if let setupError {
                Text("Power helper setup: " + setupError).font(.system(size: 13)).foregroundStyle(.red).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true).padding(.top, 12)
            }
            if helperStatus == nil {
                Text("Checking setup…").font(.system(size: 13)).foregroundStyle(Color.nightrMuted).padding(.top, 12)
            } else if helperStatus == .notRegistered || helperStatus == .requiresApproval {
                Button(helperStatus == .requiresApproval ? "Review helper approval…" : "Set up Nightr…", action: setup)
                    .controlSize(.small).padding(.top, 12)
            } else if helperStatus == .missingBundleFiles {
                Text("Required helper files are missing. Reinstall Nightr using your installation manager.")
                    .font(.system(size: 13)).foregroundStyle(Color.nightrMuted).fixedSize(horizontal: false, vertical: true).padding(.top, 12)
            } else if helperStatus == .unavailable || (helperStatus == .notFound && status?.sample.setupReady != true) {
                Text("Helper registration could not be checked. For explicit setup, run nightr setup.")
                    .font(.system(size: 13)).foregroundStyle(Color.nightrMuted).fixedSize(horizontal: false, vertical: true).padding(.top, 12)
            }
            Divider().padding(.vertical, 20)
            HStack {
                Button("Settings…", action: settings).keyboardShortcut(",")
                Spacer()
                Button("Stop and Quit", action: quit).keyboardShortcut("q")
            }.buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(Color.nightrMuted)
        }.padding(.horizontal, 18).padding(.vertical, 22).frame(width: 318).background(Color.nightrSurface)
    }
    private func diagnostic(_ name: String, _ value: String, verified: Bool = false, pending: Bool = false) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(name).foregroundStyle(Color.nightrMuted)
            Spacer(minLength: 6)
            NightrStatusLabel(text: value, tone: verified ? .confirmed : pending ? .checking : .neutral)
                .multilineTextAlignment(.trailing).fixedSize(horizontal: false, vertical: true)
        }.font(.system(size: 14))
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
#endif
