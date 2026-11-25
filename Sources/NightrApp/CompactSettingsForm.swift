#if os(macOS)
import AppKit
import SwiftUI
import NightrCore

private enum NumericColumn {
    static let field: CGFloat = 67
    static let unit: CGFloat = 50
}

func settingsRow<Control: View>(_ label: String, hint: String? = nil, status: NightrStatusLabel.Tone? = nil,
                                @ViewBuilder control: () -> Control) -> some View {
    HStack(spacing: 12) {
        VStack(alignment: .leading, spacing: 3) {
            if let status { NightrStatusLabel(text: label, tone: status).font(.system(size: 14)) }
            else { Text(label).font(.system(size: 15)) }
            if let hint {
                Text(hint).font(.system(size: 12)).foregroundStyle(Color.nightrMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }.padding(.vertical, hint == nil ? 0 : 7)
        Spacer(minLength: 6)
        control().font(.system(size: 14))
    }.frame(minHeight: 37)
}

struct CompactSettingsForm<NetworkControl: View>: View {
    @Binding var draft: NightrCore.Settings
    let section: NightrSettingsSection
    @Binding var notifications: Bool
    let notificationsReady: Bool
    @EnvironmentObject private var numbers: NumericDrafts
    let condition: (WritableKeyPath<NightrCore.Settings, Bool>) -> Binding<Bool>
    let internet: String
    let mode: HotspotJoinMode
    let forceMode: Bool
    let setForceMode: (Bool) -> Void
    var outage: String? = nil
    var repair: (() -> Void)? = nil
    var updates = DesktopUpdatePresentation.sample
    var automaticUpdates: Binding<Bool> = .constant(true)
    var updateAction: () -> Void = {}
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
        group("Startup & notifications") {
            settingsRow("Launch at login") { checkbox("Launch at login", $draft.launchAtLogin) }
            rule
            settingsRow("Hotspot notifications") { checkbox("Hotspot notifications", $notifications).disabled(!notificationsReady) }
        }
        group("Updates") {
            settingsRow("Version") {
                HStack(spacing: 6) {
                    Text(updates.version).monospacedDigit()
                    if let build = updates.build { Text("Build \(build)").font(.system(size: 12)).foregroundStyle(Color.nightrMuted) }
                }
            }
            rule
            settingsRow("Automatically download updates") { checkbox("Automatically download updates", automaticUpdates) }
            rule
            settingsRow(updates.phase.label, hint: updates.phase.readyVersion.map { "Version \($0)" },
                        status: updates.phase.readyVersion != nil || updates.phase == .current ? .confirmed : updates.phase.busy ? .checking : .neutral) {
                Button(updates.phase.readyVersion == nil ? "Check for Updates" : "Install Update…", action: updateAction)
                    .buttonStyle(SettingsActionStyle(primary: updates.phase.readyVersion != nil))
                    .disabled(updates.phase.busy || !updates.supported)
            }.help(updates.phase.detail ?? "")
        }
    }

    @ViewBuilder private var connectivity: some View {
        let wifiSettings = URL(string: "x-apple.systempreferences:com.apple.wifi-settings-extension")!
        group("Internet & Wi-Fi") {
            settingsRow("Internet access") {
                NightrStatusLabel(text: internet, tone: internet == "Connected" ? .confirmed : internet == "Checking…" ? .checking : .neutral,
                                  neutralSymbol: "info.circle")
            }
            if let outage { Text(outage).font(.caption).foregroundStyle(Color.nightrMuted) }
            rule
            settingsRow("Ask to join hotspots") {
                if mode == .unknown {
                    Link("Open Wi-Fi Settings…", destination: wifiSettings)
                        .help("Check the hotspot mode in macOS Wi-Fi Settings.")
                } else {
                    HStack(spacing: 6) {
                        NightrStatusLabel(text: mode.rawValue, tone: mode == .automatic ? .confirmed : .neutral)
                        Link(destination: wifiSettings) {
                            Image(systemName: "arrow.up.right.square")
                        }.accessibilityLabel("Open Wi-Fi Settings").help("Open Wi-Fi Settings")
                    }
                }
            }
        }
        group("Backup hotspot") {
            settingsRow("Use saved hotspot") { checkbox("Use saved hotspot", $draft.hotspot) }
            rule
            settingsRow("Network") {
                networkControl()
                    .buttonStyle(NetworkChoiceStyle())
            }
            rule
            settingsRow("Try after") { duration("Try after", $draft.hotspotAfter, range: 0...2147483647) }
                .disabled(!draft.hotspot)
            rule
            if let repair { Button("Authorize hotspot access…", action: repair) }
            settingsRow("Attempts") { number("Hotspot attempts", $draft.hotspotAttempts, 1...10) }.disabled(!draft.hotspot)
        }
    }

    @ViewBuilder private var advanced: some View {
        group("Automatic checks") {
            settingsRow("Check interval", hint: "How often Nightr checks your Protection rules.") {
                duration("Check interval", $draft.every, range: 1...3600)
            }
        }
        group("Before allowing sleep") {
            settingsRow("Initial wait", hint: "Time to stay awake after a rule stops passing.") {
                duration("Initial wait", $draft.grace, range: 0...86400)
            }
            rule
            settingsRow("Number of rechecks", hint: "Set to zero to allow sleep after the wait.") {
                number("Number of rechecks", $draft.retries, 0...10)
            }
            rule
            settingsRow("First retry delay", hint: "Each retry waits twice as long, up to 5 min.") {
                duration("First retry delay", $draft.backoff, range: 1...300)
                    .disabled(draft.retries == 0)
            }
            rule
            let wait = scheduledWait
            settingsRow("Scheduled wait", hint: wait.breakdown) {
                Text(wait.total).monospacedDigit()
            }.help("The next automatic check and hotspot recovery can add time.")
        }
    }

    private var scheduledWait: (total: String, breakdown: String?) {
        if numbers.invalid.contains("Initial wait") || numbers.invalid.contains("Number of rechecks")
            || (draft.retries > 0 && numbers.invalid.contains("First retry delay")) { return ("—", nil) }
        let grace = UInt64(clamping: draft.grace)
        var delays: [UInt64] = []
        var delay = min(300, max(1, draft.backoff))
        for _ in 0..<min(10, max(0, draft.retries)) {
            delays.append(UInt64(delay))
            delay = min(300, delay * 2)
        }
        let retryTime = delays.reduce(0, +)
        let breakdown: String
        switch delays.count {
        case 0: breakdown = "Initial wait only."
        case 1...3: breakdown = ([grace] + delays).map(formatTime).joined(separator: " + ")
        default: breakdown = "\(formatTime(grace)) + \(formatTime(retryTime)) in rechecks"
        }
        return (formatTime(grace + retryTime), breakdown)
    }

    private func formatTime(_ total: UInt64) -> String {
        let parts = [(total / 3600, "hr"), (total % 3600 / 60, "min"), (total % 60, "sec")]
        return total == 0 ? "0 sec" : parts.filter { $0.0 > 0 }.map { "\($0.0) \($0.1)" }.joined(separator: " ")
    }

    @ViewBuilder private var protection: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                sectionTitle("Force mode")
                Spacer()
                checkbox("Force mode", Binding(get: { forceMode }, set: setForceMode))
                    .help(forceMode ? "End force mode immediately" : "Start force mode immediately")
            }
            .foregroundStyle(forceMode ? Color.nightrAmber : Color.nightrInk)
            Text(forceMode ? "Automatic checks are paused." : "Pause automatic checks until you turn it off.")
                .font(.system(size: 12)).foregroundStyle(Color.nightrMuted)
        }
        group("Keep Mac awake") {
            if draft.forever {
                settingsRow("Stay awake until stopped") {
                    Button("Use automatic rules") {
                        draft.forever = false
                        if !draft.agent && !draft.internet {
                            let defaults = NightrCore.Settings()
                            draft.agent = defaults.agent
                            draft.internet = defaults.internet
                        }
                        if draft.requirement == .none { draft.requirement = .all }
                    }.buttonStyle(SettingsActionStyle())
                }
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    settingsRow("When an agent is active") { checkbox("Agent is active", condition(\.agent)) }
                    rule
                    settingsRow("When internet is available") { checkbox("Internet is available", condition(\.internet)) }
                    rule
                    settingsRow("When a local model is generating") { checkbox("Local model is generating", condition(\.localInference)) }
                }
                .disabled(forceMode)
                .foregroundStyle(forceMode ? Color.nightrMuted : Color.nightrInk)
            }
        }
        group("When lid closes") {
            settingsRow("Display") {
                settingsChoiceMenu("Display", selection: Binding(
                    get: { draft.dim ? 2 : draft.displayOn ? 1 : 0 },
                    set: { draft.dim = $0 == 2; draft.displayOn = $0 != 0 }
                ), options: [(0, "Off"), (2, "Dim"), (1, "On")])
            }
            rule
            settingsRow("Lock Mac") { checkbox("Lock Mac", $draft.lock) }
        }
        group("On battery") {
            HStack {
                Toggle("Allow sleep below", isOn: $draft.batteryProtection).toggleStyle(.checkbox)
                Spacer()
                settingsField(width: 136) {
                    SettingsNumber(label: "Battery cutoff", value: $draft.batteryBelow, range: 1...100)
                    Text("%").foregroundStyle(Color.nightrMuted)
                }.disabled(!draft.batteryProtection)
            }.help("Applies only while your Mac is running on battery power.")
        }
    }

    private var rule: some View { Rectangle().fill(Color.nightrLine).frame(height: 1) }
    private func group<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            sectionTitle(title)
            VStack(alignment: .leading, spacing: 0, content: content)
        }
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(title).font(.system(size: 16, weight: .semibold))
            .accessibilityAddTraits(.isHeader)
            .padding(.bottom, 2)
    }

    private func checkbox(_ label: String, _ value: Binding<Bool>) -> some View {
        Toggle(label, isOn: value).toggleStyle(.checkbox).labelsHidden().accessibilityLabel(label)
    }

    private func duration(_ label: String, _ value: Binding<Int>, range: ClosedRange<Int>) -> some View {
        SettingsDuration(label: label, value: value, range: range)
    }

    private func number(_ label: String, _ value: Binding<Int>, _ range: ClosedRange<Int>) -> some View {
        HStack(spacing: 6) {
            SettingsNumber(label: label, value: value, range: range)
                .background(Color(nsColor: .nightrSelectedFill), in: RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color(nsColor: .nightrSelectedBorder)).allowsHitTesting(false))
            Stepper(label, value: Binding(get: { value.wrappedValue }, set: { next in
                numbers.texts.removeValue(forKey: label)
                numbers.invalid.remove(label)
                value.wrappedValue = next
            }), in: range).labelsHidden().accessibilityLabel(label).fixedSize()
        }
    }
}

func settingsField<Content: View>(width: CGFloat? = nil, accented: Bool = false, @ViewBuilder content: () -> Content) -> some View {
    HStack(spacing: 4, content: content)
        .padding(.horizontal, 9).frame(width: width, height: 28, alignment: .trailing)
        .background(Color(nsColor: .nightrSelectedFill), in: RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(accented ? Color.nightrAmber.opacity(0.65) : Color(nsColor: .nightrSelectedBorder)).allowsHitTesting(false))
}

func settingsChoiceMenu<Value: Hashable>(_ label: String, selection: Binding<Value>,
                                    options: [(Value, String)], width: CGFloat? = nil) -> some View {
    let title = options.first { $0.0 == selection.wrappedValue }?.1 ?? ""
    return settingsField(width: width) {
        ZStack(alignment: .leading) {
            ForEach(options, id: \.0) { _, option in Text(option).hidden() }
            Text(title)
        }
        if width != nil { Spacer(minLength: 2) }
        Image(systemName: "chevron.up.chevron.down").font(.system(size: 10, weight: .semibold))
    }
    .fixedSize()
    .background(Color.nightrSurface)
    .allowsHitTesting(false)
    .accessibilityHidden(true)
    .background {
        NativeChoice(label: label, selection: selection, options: options)
    }
}

private struct NetworkChoiceStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 6) {
            configuration.label.lineLimit(1).truncationMode(.middle)
            Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold))
        }
        .font(.system(size: 14)).foregroundStyle(Color.nightrInk).padding(.horizontal, 9)
        .frame(minWidth: NumericColumn.field + NumericColumn.unit, minHeight: 28)
        .background(Color(nsColor: .nightrSelectedFill), in: RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color(nsColor: .nightrSelectedBorder)))
        .contentShape(Rectangle()).opacity(configuration.isPressed ? 0.7 : 1)
    }
}

// Use real menu item titles and native keyboard selection under the shared field artwork.
private struct NativeChoice<Value: Hashable>: NSViewRepresentable {
    let label: String
    @Binding var selection: Value
    let options: [(Value, String)]

    final class Coordinator: NSObject {
        var owner: NativeChoice
        init(_ owner: NativeChoice) { self.owner = owner }
        @objc func selectItem(_ sender: NSPopUpButton) {
            let index = sender.indexOfSelectedItem
            guard owner.options.indices.contains(index) else { return }
            owner.selection = owner.options[index].0
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSPopUpButton, context: Context) -> CGSize? {
        guard let width = proposal.width, let height = proposal.height else { return nil }
        return CGSize(width: width, height: height)
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSPopUpButton {
        let button = NSPopUpButton(frame: .zero, pullsDown: false)
        button.isBordered = false
        button.target = context.coordinator
        button.action = #selector(Coordinator.selectItem(_:))
        return button
    }
    func updateNSView(_ button: NSPopUpButton, context: Context) {
        context.coordinator.owner = self
        let titles = options.map { $0.1 }
        if button.itemTitles != titles {
            button.removeAllItems()
            button.addItems(withTitles: titles)
        }
        button.setAccessibilityLabel(label)
        if let index = options.firstIndex(where: { $0.0 == selection }) { button.selectItem(at: index) }
    }
}

private struct SettingsNumber: View {
    let label: String
    @Binding var value: Int
    let range: ClosedRange<Int>
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
            .overlay {
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(drafts.invalid.contains(label) ? Color.red : focused ? Color.nightrAmber : .clear)
                    .allowsHitTesting(false)
            }
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
                          range: ((range.lowerBound + scale - 1) / scale)...(range.upperBound / scale))
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
