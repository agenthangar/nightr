#if os(macOS)
import AppKit
import SwiftUI
import NightrCore

private enum NumericColumn {
    static let field: CGFloat = 67
    static let unit: CGFloat = 50
}

struct CompactSettingsForm<NetworkControl: View>: View {
    @Binding var draft: NightrCore.Settings
    let section: NightrSettingsSection
    @Binding var notifications: Bool
    let notificationsReady: Bool
    let force: Bool
    let toggleForce: () -> Void
    let condition: (WritableKeyPath<NightrCore.Settings, Bool>) -> Binding<Bool>
    let internet: String
    let mode: HotspotJoinMode
    var outage: String? = nil
    var repair: (() -> Void)? = nil
    @ViewBuilder let networkControl: () -> NetworkControl

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            switch section {
            case .general: general
            case .protection: protection
            case .connectivity: connectivity
            case .advanced: advanced
            }
        }
        .font(.system(size: 15)).padding(.horizontal, SettingsLayout.formInset).padding(.vertical, 20)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private var general: some View {
        group("General") {
            setting("Launch at login") { checkbox("Launch at login", $draft.launchAtLogin) }
            rule
            setting("Hotspot notifications") { checkbox("Hotspot notifications", $notifications).disabled(!notificationsReady) }
        }
        group("Protection") {
            setting("Keep awake until stopped") {
                Button(force ? "End force mode" : "Enable force mode") { toggleForce() }
                    .buttonStyle(SettingsActionStyle(primary: !force))
            }
        }
    }

    @ViewBuilder private var connectivity: some View {
        group("Connection status") {
            setting("Internet") {
                Label(internet, systemImage: internet == "Connected" ? "checkmark.circle" : internet == "Checking…" ? "clock" : "info.circle")
                    .foregroundStyle(internet == "Connected" ? Color.nightrStatusGreen : Color.nightrMuted)
            }
            if let outage { Text(outage).font(.caption).foregroundStyle(Color.nightrMuted) }
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
                networkControl()
            }
            rule
            setting("Try after") { duration("Try after", $draft.hotspotAfter, range: 0...2147483647) }
                .disabled(!draft.hotspot)
            rule
            if let repair { Button("Authorize hotspot access…", action: repair) }
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
                setting("Agent is active") { checkbox("Agent is active", condition(\.agent)) }
                rule
                setting("Internet is available") { checkbox("Internet is available", condition(\.internet)) }
                rule
                if draft.requirement != .all { Text("Custom CLI policy retained").font(.caption) }
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
                    SettingsNumber(label: "Battery cutoff", value: $draft.batteryBelow, range: 1...100, integrated: true)
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
        SettingsDuration(label: label, value: value, range: range)
    }

    private func number(_ label: String, _ value: Binding<Int>, _ range: ClosedRange<Int>, unit: String = "") -> some View {
        HStack(spacing: 0) {
            SettingsNumber(label: label, value: value, range: range)
            Text(unit).font(.system(size: 13)).foregroundStyle(Color.nightrMuted).frame(width: NumericColumn.unit)
        }
    }
}

private struct SettingsNumber: View {
    let label: String
    @Binding var value: Int
    let range: ClosedRange<Int>
    var integrated = false
    @FocusState private var focused: Bool
    @EnvironmentObject private var drafts: NumericDrafts
    private var input: Binding<String> {
        Binding(get: { drafts.texts[label] ?? String(value) }, set: { text in
            drafts.texts[label] = text
            guard !text.isEmpty, text.utf8.allSatisfy({ (48...57).contains($0) }),
                  let integer = Int(text), range.contains(integer) else {
                drafts.invalid.insert(label)
                return
            }
            drafts.texts.removeValue(forKey: label)
            drafts.invalid.remove(label)
            value = integer
        })
    }
    var body: some View {
        TextField(label, text: input)
            .textFieldStyle(.plain).focused($focused).multilineTextAlignment(.trailing)
            .font(.system(size: 15, weight: .semibold)).monospacedDigit()
            .padding(.horizontal, 9).frame(width: NumericColumn.field, height: 28)
            .background {
                if !integrated {
                    RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .nightrSelectedFill))
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(focused ? Color.nightrAmber : Color(nsColor: .nightrSelectedBorder)))
                }
            }
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(drafts.invalid.contains(label) ? Color.red : .clear))
            .accessibilityLabel(label)
    }
}

private struct SettingsDuration: View {
    let label: String
    @Binding var value: Int
    let range: ClosedRange<Int>
    @EnvironmentObject private var drafts: NumericDrafts
    @State private var minutes: Bool
    init(label: String, value: Binding<Int>, range: ClosedRange<Int>) {
        self.label = label; _value = value; self.range = range
        _minutes = State(initialValue: value.wrappedValue >= 60 && value.wrappedValue.isMultiple(of: 60))
    }
    var body: some View {
        let scale = minutes ? 60 : 1
        HStack(spacing: 0) {
            SettingsNumber(label: label, value: Binding(get: { value / scale }, set: { value = $0 * scale }),
                          range: ((range.lowerBound + scale - 1) / scale)...(range.upperBound / scale), integrated: true)
            Menu {
                Button("Seconds") { drafts.texts[label] = nil; minutes = false }
                Button("Minutes") { drafts.texts[label] = nil; minutes = true }.disabled(!value.isMultiple(of: 60))
            } label: {
                HStack(spacing: 4) {
                    Text(minutes ? "min" : "sec").font(.system(size: 12, weight: .semibold))
                    Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold))
                }.foregroundStyle(Color.nightrAmber).frame(height: 28)
                    .contentShape(Rectangle())
            }
                .menuStyle(.borderlessButton).menuIndicator(.hidden)
                .frame(width: NumericColumn.unit, height: 28)
                .accessibilityLabel("\(label) units").disabled(drafts.invalid.contains(label))
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

@MainActor final class NumericDrafts: ObservableObject {
    @Published var invalid: Set<String> = []
    @Published var texts: [String: String] = [:]
    func reset() { texts = [:]; invalid = [] }
}
#endif
