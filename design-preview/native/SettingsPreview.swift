import AppKit
import SwiftUI
import NightrCore

// The host owns this dictionary across view replacements. It lives only in memory.
private enum NumericColumn {
    static let field: CGFloat = 67
    static let unit: CGFloat = 50
}

private struct PreviewSettings: View {
    let session: NSMutableDictionary
    @State private var tab: NightrSettingsSection
    @State private var draft: NightrCore.Settings
    @State private var notifications: Bool
    @State private var force: Bool
    @State private var mode = HotspotJoinMode.current()
    @State private var saved = false
    @Environment(\.controlActiveState) private var active

    init(session: NSMutableDictionary) {
        self.session = session
        _tab = State(initialValue: NightrSettingsSection(rawValue: session["tab"] as? String ?? "") ?? .connectivity)
        _draft = State(initialValue: Self.settings(session["draft"]))
        _force = State(initialValue: session["force"] as? Bool ?? false)
        _notifications = State(initialValue: session["notifications"] as? Bool ?? true)
    }

    private static func settings(_ data: Any?) -> NightrCore.Settings {
        if let data = data as? Data, let value = try? JSONDecoder().decode(NightrCore.Settings.self, from: data) { return value }
        return NightrCore.Settings()
    }

    var body: some View {
        VStack(spacing: 0) {
            SettingsWindowTitle().frame(height: 21).padding(.top, 14)
            SettingsToolbar(selection: $tab)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    switch tab {
                    case .general: general
                    case .protection: protection
                    case .connectivity: connectivity
                    case .advanced: advanced
                    }
                }.padding(.horizontal, 22).padding(.vertical, 20)
                 .frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider()
            HStack(spacing: 9) {
                Button("Reset") { draft = NightrCore.Settings(); notifications = true }.buttonStyle(SettingsActionStyle())
                Spacer()
                Text(saved ? "Saved in preview" : "Local preview").font(.system(size: 11)).foregroundStyle(Color.nightrMuted)
                Button("Cancel") {
                    draft = Self.settings(session["savedDraft"])
                    notifications = session["savedNotifications"] as? Bool ?? true
                }.buttonStyle(SettingsActionStyle())
                Button("Save") {
                    session["savedDraft"] = try? JSONEncoder().encode(draft)
                    session["savedNotifications"] = notifications
                    saved = true
                }.buttonStyle(SettingsActionStyle(primary: true)).keyboardShortcut(.defaultAction)
            }.padding(.horizontal, 22).padding(.vertical, 12)
        }
        .font(.system(size: 15)).foregroundStyle(Color.nightrInk).tint(.nightrAmber)
        .background(Color.nightrSurface).frame(width: 470, height: min(630, NSScreen.main?.visibleFrame.height ?? 630))
        .ignoresSafeArea(.container, edges: .top)
        .onChange(of: tab) { session["tab"] = $0.rawValue }
        .onChange(of: draft) { session["draft"] = try? JSONEncoder().encode($0); saved = false }
        .onChange(of: notifications) { session["notifications"] = $0; saved = false }
        .onChange(of: force) { session["force"] = $0 }
        .task(id: active) { mode = .current() }
    }

    @ViewBuilder private var general: some View {
        group("General") {
            setting("Launch at login") { checkbox("Launch at login", $draft.launchAtLogin) }
            rule
            setting("Hotspot notifications") { checkbox("Hotspot notifications", $notifications) }
        }
        group("Protection") {
            setting("Keep awake until stopped") {
                Button(force ? "End force mode" : "Enable force mode") { force.toggle() }
                    .buttonStyle(SettingsActionStyle(primary: !force))
            }
        }
    }

    @ViewBuilder private var connectivity: some View {
        group("Connection status") {
            setting("Internet") {
                Label(force ? "Checks paused" : "Connected", systemImage: force ? "pause.circle" : "checkmark.circle")
                    .foregroundStyle(force ? Color.nightrMuted : Color.nightrStatusGreen)
            }
            rule
            setting("Ask to join hotspots") {
                Link(destination: URL(string: "x-apple.systempreferences:com.apple.wifi-settings-extension")!) {
                    if mode == .unknown {
                        Label("Wi-Fi Settings", systemImage: "arrow.up.right.square")
                    } else {
                        Label(mode.rawValue, systemImage: mode.symbol)
                            .foregroundStyle(mode == .automatic ? Color.nightrStatusGreen : Color.nightrInk)
                    }
                }.help("View Ask to join hotspots in macOS Wi-Fi settings")
            }
        }
        group("Hotspot fallback") {
            setting("Use saved hotspot") { checkbox("Use saved hotspot", $draft.hotspot) }
            rule
            setting("Network") {
                Menu {
                    ForEach(["Travel hotspot", "Sample iPhone"], id: \.self) { name in
                        Button(name) { draft.hotspotSSID = name; draft.hotspot = true }
                    }
                } label: { Text(draft.hotspotSSID.isEmpty ? "Choose network…" : draft.hotspotSSID) }
                .frame(width: 154).accessibilityLabel("Choose hotspot")
            }
            rule
            setting("Try after") { duration("Try after", $draft.hotspotAfter, range: 0...2147483647) }
                .disabled(!draft.hotspot)
            rule
            setting("Attempts") { number("Hotspot attempts", $draft.hotspotAttempts, 1...10) }.disabled(!draft.hotspot)
        }
    }

    @ViewBuilder private var advanced: some View {
        group("Automatic checks") {
            setting("Check interval", hint: "How often Nightr checks your Protection rules.") {
                duration("Check interval", $draft.every, range: 1...3600)
            }
        }
        group("When a keep-awake check fails") {
            setting("Keep Mac awake for", hint: "Time to wait before rechecking or allowing sleep.") {
                duration("Keep Mac awake for", $draft.grace, range: 0...86400)
            }
            rule
            setting("Number of rechecks", hint: "Set to zero to allow sleep after the wait.") {
                number("Number of rechecks", $draft.retries, 0...10)
            }
            rule
            setting("Wait before first recheck", hint: "Later waits double, up to 5 minutes.") {
                duration("Wait before first recheck", $draft.backoff, range: 1...300)
                    .disabled(draft.retries == 0)
            }
        }
    }

    @ViewBuilder private var protection: some View {
        group("Keep Mac awake") {
            setting("Mode") {
                protectionMenu("Mode", selection: $draft.forever, options: [
                    (false, "Automatically"), (true, "Until I stop")
                ])
            }
            if !draft.forever {
                rule
                setting("Agent is active") { checkbox("Agent is active", $draft.agent) }
                rule
                setting("Internet is available") { checkbox("Internet is available", $draft.internet) }
                Button("Connectivity settings") { tab = .connectivity }.buttonStyle(.link)
                    .font(.system(size: 12)).padding(.bottom, 5)
                rule
                setting("Local model is generating") { checkbox("Local model is generating", $draft.localInference) }
            }
        }
        group("When lid closes") {
            setting("Display") {
                protectionMenu("Display", selection: Binding(
                    get: { draft.dim ? 2 : draft.displayOn ? 1 : 0 },
                    set: { draft.dim = $0 == 2; draft.displayOn = $0 != 0 }
                ), options: [(0, "Off"), (2, "Dim"), (1, "On")])
            }
            rule
            setting("Lock Mac") { checkbox("Lock Mac", $draft.lock) }
        }
        group("On battery") {
            HStack {
                Toggle("Allow sleep below", isOn: $draft.batteryProtection).toggleStyle(.checkbox)
                Spacer()
                protectionField {
                    PreviewNumber(label: "Battery cutoff", value: $draft.batteryBelow, range: 1...100, integrated: true)
                    Text("%").foregroundStyle(Color.nightrMuted)
                }.disabled(!draft.batteryProtection)
            }
        }
    }

    private func protectionField<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 4, content: content)
            .padding(.horizontal, 9).frame(width: 136, height: 28, alignment: .trailing)
            .background(Color(nsColor: .nightrSelectedFill), in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color(nsColor: .nightrSelectedBorder)).allowsHitTesting(false))
    }

    private func protectionMenu<Value: Hashable>(_ label: String, selection: Binding<Value>,
                                                  options: [(Value, String)]) -> some View {
        Menu {
            Picker(label, selection: selection) {
                ForEach(options, id: \.0) { value, title in Text(title).tag(value) }
            }.pickerStyle(.inline).labelsHidden()
        } label: {
            protectionField {
                Text(options.first { $0.0 == selection.wrappedValue }?.1 ?? "")
                Spacer(minLength: 4)
                Image(systemName: "chevron.up.chevron.down").font(.system(size: 10, weight: .semibold))
            }.contentShape(Rectangle())
        }.menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
            .accessibilityLabel(label)
            .accessibilityValue(options.first { $0.0 == selection.wrappedValue }?.1 ?? "")
    }

    private var rule: some View { Rectangle().fill(Color.nightrLine).frame(height: 1) }
    private func group<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.system(size: 16, weight: .semibold)).padding(.bottom, 2)
            VStack(alignment: .leading, spacing: 0, content: content)
        }
    }

    private func setting<Control: View>(_ label: String, hint: String? = nil, @ViewBuilder control: () -> Control) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(label)
                if let hint {
                    Text(hint).font(.system(size: 12)).foregroundStyle(Color.nightrMuted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }.padding(.vertical, hint == nil ? 0 : 7)
            Spacer(minLength: 6)
            control().font(.system(size: 14))
        }.frame(minHeight: 37)
    }

    private func checkbox(_ label: String, _ value: Binding<Bool>) -> some View {
        Toggle(label, isOn: value).toggleStyle(.checkbox).labelsHidden().accessibilityLabel(label)
    }

    private func duration(_ label: String, _ value: Binding<Int>, range: ClosedRange<Int>) -> some View {
        PreviewDuration(label: label, value: value, range: range)
    }

    private func number(_ label: String, _ value: Binding<Int>, _ range: ClosedRange<Int>, unit: String = "") -> some View {
        HStack(spacing: 0) {
            PreviewNumber(label: label, value: value, range: range)
            Text(unit).font(.system(size: 13)).foregroundStyle(Color.nightrMuted).frame(width: NumericColumn.unit)
        }
    }
}

private struct PreviewNumber: View {
    let label: String
    @Binding var value: Int
    let range: ClosedRange<Int>
    var integrated = false
    @FocusState private var focused: Bool
    var body: some View {
        TextField(label, value: $value, formatter: formatter)
            .textFieldStyle(.plain).focused($focused).multilineTextAlignment(.trailing)
            .font(.system(size: 15, weight: .semibold)).monospacedDigit()
            .padding(.horizontal, 9).frame(width: NumericColumn.field, height: 28)
            .background {
                if !integrated {
                    RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .nightrSelectedFill))
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(focused ? Color.nightrAmber : Color(nsColor: .nightrSelectedBorder)))
                }
            }
            .accessibilityLabel(label)
    }
    private var formatter: NumberFormatter {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.allowsFloats = false
        formatter.minimum = NSNumber(value: range.lowerBound)
        formatter.maximum = NSNumber(value: range.upperBound)
        return formatter
    }
}

private struct PreviewDuration: View {
    let label: String
    @Binding var value: Int
    let range: ClosedRange<Int>
    @State private var minutes: Bool
    init(label: String, value: Binding<Int>, range: ClosedRange<Int>) {
        self.label = label; _value = value; self.range = range
        _minutes = State(initialValue: value.wrappedValue >= 60 && value.wrappedValue.isMultiple(of: 60))
    }
    var body: some View {
        let scale = minutes ? 60 : 1
        HStack(spacing: 0) {
            PreviewNumber(label: label, value: Binding(get: { value / scale }, set: { value = $0 * scale }),
                          range: ((range.lowerBound + scale - 1) / scale)...(range.upperBound / scale), integrated: true)
            Menu {
                Button("Seconds") { minutes = false }
                Button("Minutes") { minutes = true }.disabled(!value.isMultiple(of: 60))
            } label: {
                HStack(spacing: 4) {
                    Text(minutes ? "min" : "sec").font(.system(size: 12, weight: .semibold))
                    Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold))
                }.foregroundStyle(Color.nightrAmber).frame(height: 28)
                    .contentShape(Rectangle())
            }
                .menuStyle(.borderlessButton).menuIndicator(.hidden)
                .frame(width: NumericColumn.unit, height: 28)
                .accessibilityLabel("\(label) units")
        }
        .background(Color(nsColor: .nightrSelectedFill), in: RoundedRectangle(cornerRadius: 7))
        .overlay(alignment: .trailing) {
            Rectangle().fill(Color.nightrAmber.opacity(0.09)).frame(width: NumericColumn.unit).allowsHitTesting(false)
        }
        .clipShape(RoundedRectangle(cornerRadius: 7))
        .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Color.nightrAmber.opacity(0.42)).allowsHitTesting(false))
        .onChange(of: value) { if !$0.isMultiple(of: 60) { minutes = false } }
    }
}

@MainActor @_cdecl("makeNightrSettingsPreview")
public func makeNightrSettingsPreview(_ state: UnsafeMutableRawPointer) -> UnsafeMutableRawPointer {
    let session = Unmanaged<NSMutableDictionary>.fromOpaque(state).takeUnretainedValue()
    let view = NSHostingView(rootView: PreviewSettings(session: session))
    if #available(macOS 14, *) { view.safeAreaRegions = [] }
    return Unmanaged.passRetained(view as NSView).toOpaque()
}
