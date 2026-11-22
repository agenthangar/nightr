#if os(macOS)
import SwiftUI
import AppKit
import UserNotifications
import NightrCore
import NightrController
import NightrPlatform

struct SettingsView: View {
    @Binding var section: NightrSettingsSection
    let status: ControllerStatus?
    let store: SettingsStore?
    let initialDraft: NightrCore.Settings?
    let apply: (NightrCore.Settings) async throws -> Void
    let close: () -> Void
    @State private var draft = NightrCore.Settings()
    @State private var original = NightrCore.Settings()
    @State private var expected: Data?
    @State private var loaded = false
    @State private var chooser = false
    @State private var credential: CredentialEdit = .unchanged
    @State private var networkSecurity: NetworkSecurity?
    @State private var error: String?
    @State private var conditionsEdited = false
    let readHotspotMode: () -> HotspotJoinMode
    @State private var hotspotMode = HotspotJoinMode.unknown
    @State private var guidance = false
    @State private var saving = false
    @State private var pendingLoginRemoval = false
    @State private var savedApprovalNotice = false
    @State private var notificationStatus: UNAuthorizationStatus?
    @Environment(\.controlActiveState) private var activeState
    @StateObject private var numbers = NumericDrafts()
    @FocusState private var saveFocused: Bool
    init(section: Binding<NightrSettingsSection>, status: ControllerStatus?, store: SettingsStore? = nil,
         initialDraft: NightrCore.Settings? = nil, notificationStatus: UNAuthorizationStatus? = nil,
         readHotspotMode: @escaping () -> HotspotJoinMode = HotspotJoinMode.current, apply: @escaping (NightrCore.Settings) async throws -> Void = { _ in }, close: @escaping () -> Void = {}) {
        self.readHotspotMode = readHotspotMode
        _section = section; self.status = status; self.store = store; self.initialDraft = initialDraft
        self.apply = apply; self.close = close
        _notificationStatus = State(initialValue: notificationStatus)
        if let initialDraft { _draft = State(initialValue: initialDraft); _original = State(initialValue: initialDraft); _loaded = State(initialValue: true) }
    }
    var body: some View {
        VStack(spacing: 0) {
            SettingsWindowTitle().frame(height: 21).padding(.top, 14)
            SettingsToolbar(selection: $section).disabled(saving)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    switch section {
                    case .general: general
                    case .protection: protection
                    case .connectivity: connectivity
                    case .advanced: advanced
                    }
                }.font(.system(size: 15)).padding(.horizontal, SettingsLayout.contentInset).padding(.vertical, 20).frame(maxWidth: .infinity, alignment: .leading)
            }
            .disabled(saving)
            Divider()
            if let error { Text(error).font(.system(size: 13)).foregroundStyle(.red).textSelection(.enabled).padding(.horizontal, 18).padding(.top, 10) }
            HStack {
                Button("Reset") { draft = NightrCore.Settings(); credential = .unchanged; conditionsEdited = false; networkSecurity = nil; error = nil; numbers.reset() }.buttonStyle(SettingsActionStyle()).disabled(saving)
                Text("Changes stay pending until Save.").font(.system(size: 11)).foregroundStyle(Color.nightrMuted)
                    .frame(maxWidth: .infinity)
                Button("Cancel") { credential = .unchanged; close() }.buttonStyle(SettingsActionStyle()).disabled(saving).keyboardShortcut(.cancelAction)
                Button { Task { await save() } } label: {
                    Text(error == nil ? "Save" : "Retry Save")
                }.buttonStyle(SettingsActionStyle(primary: true)).keyboardShortcut(.defaultAction).focused($saveFocused).disabled(saving || !loaded || !numbers.invalid.isEmpty)
            }.padding(.horizontal, SettingsLayout.contentInset).padding(.vertical, 13)
        }.frame(width: SettingsLayout.width, height: SettingsLayout.bodyHeight)
        .background(Color.nightrSurface)
        .ignoresSafeArea(.container, edges: .top)
        .foregroundStyle(Color.nightrInk)
        .toggleStyle(.checkbox)
        .tint(.nightrAmber)
        .environmentObject(numbers)
        .onAppear(perform: load)
        .sheet(isPresented: $chooser) {
            NetworkChooser(configured: draft.hotspotSSID, pending: credential, pendingSecurity: networkSecurity) { ssid, edit, security in
                draft.hotspotSSID = ssid; credential = edit; networkSecurity = security
            }
        }
        .alert("Login setting saved", isPresented: $savedApprovalNotice) {
            Button("OK") { close() }
        } message: { Text(DesktopSetup.approvalGuidance) }
        .alert("Auto-join iPhone hotspot: \(hotspotMode.rawValue)", isPresented: $guidance) {
            Button("Open Wi-Fi settings") { DesktopSetup.systemWiFi() }
            Button("Close", role: .cancel) {}
        } message: {
            Text("Auto-join controls how your Mac joins an eligible iPhone hotspot. Review it in System Settings → Wi-Fi → Ask to join hotspots.")
        }
    }
    private var general: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("General").font(.system(size: 16, weight: .semibold))
            Text("A quiet companion in your menu bar.")
                .font(.system(size: 13)).foregroundStyle(Color.nightrMuted)
                .padding(.top, 5).padding(.bottom, 17)
            HStack {
                Text("Launch app at login")
                Spacer()
                Toggle("Launch app at login", isOn: $draft.launchAtLogin).labelsHidden()
            }.frame(minHeight: 35)
            Divider()
            HStack {
                Text("Desktop notification prompt")
                Spacer()
                Toggle("Desktop notification prompt", isOn: Binding(
                    get: { notificationsAllowed },
                    set: { _ in manageNotifications() }
                ))
                .labelsHidden()
                .disabled(notificationStatus == nil)
                .accessibilityValue(notificationStatus == nil ? "Checking" : (notificationsAllowed ? "Allowed" : "Off"))
                .help(notificationStatus == .notDetermined ? "Allow hotspot notifications" : "Manage notifications in System Settings")
            }.frame(minHeight: 35)
            Divider()
            Text("Launch at login opens Nightr. Protection only resumes if you enabled it; Stop stays stopped.")
                .font(.system(size: 12)).foregroundStyle(Color.nightrMuted)
                .fixedSize(horizontal: false, vertical: true).padding(.top, 14)
        }.task(id: activeState) { await refreshNotifications() }
    }
    private var notificationsAllowed: Bool {
        notificationStatus == .authorized || notificationStatus == .provisional
    }

    private func manageNotifications() {
        guard let notificationStatus else { return }
        if notificationStatus == .notDetermined {
            Task {
                do { try await DesktopSetup.notifications() } catch { self.error = error.localizedDescription }
                await refreshNotifications()
            }
        } else {
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension")!)
        }
    }

    private func refreshNotifications() async {
        guard store != nil else { return }
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        if !Task.isCancelled { notificationStatus = settings.authorizationStatus }
    }
    private var protection: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Keep Mac awake").fontWeight(.semibold)
            Picker("Keep Mac awake", selection: $draft.forever) {
                Text("Automatically").tag(false)
                Text("Until I stop").tag(true)
            }.pickerStyle(.radioGroup).horizontalRadioGroupLayout().labelsHidden()
                .padding(.top, 16)
            if !draft.forever {
                VStack(alignment: .leading, spacing: 0) {
                    Toggle("Agent is active", isOn: condition(\.agent)).frame(minHeight: 32)
                    Toggle("Internet is available", isOn: condition(\.internet)).frame(minHeight: 32)
                    Group {
                        if draft.requirement != .all { hint("Custom CLI policy retained") }
                        else if draft.agent && draft.internet { hint("Both must apply.") }
                    }.padding(.leading, 26).padding(.top, 6)
                    Toggle("Keep awake while a local model is generating", isOn: $draft.localInference)
                        .frame(minHeight: 32).padding(.top, 12)
                    hint("Works without internet.").padding(.leading, 26).padding(.top, 3)
                    if conditionsEdited && !draft.agent && !draft.internet {
                        Text("Select one, or choose Until I stop.").font(.system(size: 13)).foregroundStyle(.red)
                    }
                }.padding(.leading, 26).padding(.top, 14)
            }
            sectionDivider
            Text("When lid closes").fontWeight(.semibold).padding(.bottom, 12)
            HStack(spacing: 8) {
                Text("Display").frame(width: 136, alignment: .leading)
                Picker("Display", selection: display) { Text("Off").tag(0); Text("On").tag(1); Text("Dim").tag(2) }
                    .labelsHidden().frame(width: 116, alignment: .leading)
            }.frame(minHeight: 40)
            HStack(spacing: 8) {
                Text("Lock Mac").frame(width: 136, alignment: .leading)
                Toggle("Lock Mac", isOn: $draft.lock).labelsHidden()
            }.frame(minHeight: 40)
            sectionDivider
            Text("On battery").fontWeight(.semibold).padding(.bottom, 14)
            HStack(spacing: 8) {
                Toggle("Allow sleep below", isOn: $draft.batteryProtection).fixedSize()
                NumericInput(key: "batteryBelow", value: $draft.batteryBelow, range: 1...100).frame(width: 78).disabled(!draft.batteryProtection)
                Text("%")
            }
            hint("Plug in or recharge to resume.").padding(.top, 8)
        }
    }
    private var connectivity: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Connection").fontWeight(.semibold).padding(.bottom, 14)
            HStack(alignment: .top, spacing: 12) {
                let connected = status?.state.internet == .verified
                Image(systemName: "wifi").font(.system(size: 20))
                    .foregroundStyle(connected ? Color.nightrStatusGreen : Color.nightrMuted)
                    .accessibilityHidden(true).padding(.top, 2)
                VStack(alignment: .leading, spacing: 3) {
                    Text(connected ? "Connected" : GUIProtectionSummary(status: status).internet)
                        .font(.system(size: 14, weight: .semibold))
                    hint(connected ? "Internet verified." : "Independent internet verification.")
                }
                Spacer(minLength: 8)
                Text("Observed").font(.system(size: 11)).foregroundStyle(Color.nightrMuted).padding(.top, 2)
            }.padding(14).frame(maxWidth: .infinity, minHeight: 64, alignment: .leading)
                .background(Color.primary.opacity(0.018), in: RoundedRectangle(cornerRadius: 7))
                .overlay(RoundedRectangle(cornerRadius: 7).stroke(Color.nightrLine))
            if let outage = status?.state.outage {
                hint(status?.verificationEligible == true ? "\(outage.consumed) of \(outage.capturedLimit) attempts used, still checking internet" : "Internet checks are paused.")
                    .padding(.top, 8)
            }
            sectionDivider
            Text("Hotspot fallback").fontWeight(.semibold).padding(.bottom, 14)
            Toggle("Use saved hotspot", isOn: $draft.hotspot).frame(minHeight: 26)
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Text("Hotspot").frame(width: 136, alignment: .leading)
                    Text(draft.hotspotSSID.isEmpty ? "None selected" : draft.hotspotSSID)
                        .font(.system(size: 14)).lineLimit(1).help(draft.hotspotSSID)
                        .padding(.horizontal, 8).frame(maxWidth: .infinity, minHeight: 28, alignment: .leading)
                        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 5))
                        .overlay(RoundedRectangle(cornerRadius: 5).stroke(Color.nightrLine))
                    Button("Choose…") { chooser = true }.frame(width: 76)
                }
                HStack(spacing: 8) {
                    Text("Try after").frame(width: 136, alignment: .leading)
                    NumericInput(key: "hotspotAfter", value: $draft.hotspotAfter, range: 0...2147483647).frame(width: 78)
                    Text("seconds").font(.system(size: 13)).foregroundStyle(Color.nightrMuted)
                }
                HStack(spacing: 8) {
                    Text("Attempts").frame(width: 136, alignment: .leading)
                    NumericInput(key: "hotspotAttempts", value: $draft.hotspotAttempts, range: 1...10).frame(width: 78)
                }
            }.padding(.top, 10).disabled(!draft.hotspot)
            hint("\(draft.hotspotAttempts) total attempts. Internet checks keep running.").padding(.leading, 26).padding(.top, 12)
            if status?.state.outage?.repairRequired == .missingCredential, !draft.hotspotSSID.isEmpty {
                Button("Authorize hotspot access…") {
                    do { try KeychainCredentials().repairAccess(ssid: draft.hotspotSSID); error = nil }
                    catch { self.error = "Hotspot access was not authorized. Unlock Keychain and retry." }
                }.padding(.top, 10)
            }
            sectionDivider
            Text("macOS settings").fontWeight(.semibold).padding(.bottom, 8)
            hint("Status only, change in System Settings.").padding(.bottom, 9)
            HStack {
                Image(systemName: hotspotMode.symbol).font(.system(size: 20))
                    .foregroundStyle(hotspotMode == .automatic ? Color.nightrStatusGreen : Color.nightrMuted)
                    .accessibilityHidden(true)
                Text("Auto-join iPhone hotspot")
                Spacer(); Button("\(hotspotMode.rawValue)…") { guidance = true }
            }.frame(minHeight: 38)
        }
        .task(id: activeState) { hotspotMode = readHotspotMode() }
    }
    private var advanced: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Automatic checks").fontWeight(.semibold).padding(.bottom, 13)
            duration("Check every", help: "How often to check the conditions selected in Protection.", value: $draft.every, slider: 1...300, full: 1...3600)
            Divider().padding(.top, 14).padding(.bottom, 17)
            Text("Before allowing sleep").fontWeight(.semibold).padding(.bottom, 13)
            duration("Wait before retrying", help: "Keep awake through pauses or lost internet before retrying.", value: $draft.grace, slider: 0...3600, full: 0...86400)
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Extra attempts")
                    hint(draft.retries == 0 ? "No extra attempts" : "Retry failed conditions before allowing sleep.")
                }.frame(maxWidth: .infinity, alignment: .leading)
                NumericInput(key: "retries", value: $draft.retries, range: 0...10).frame(width: 83)
                Color.clear.frame(width: 58, height: 1).accessibilityHidden(true)
            }.padding(.vertical, 13)
            duration("First retry delay", help: "Later waits double, up to 5 minutes.", value: $draft.backoff, slider: 1...300, full: 1...300)
                .disabled(draft.retries == 0)
            hint("These limits apply with the lid open or closed.").padding(.top, 16)
        }
    }
    private var sectionDivider: some View { Divider().padding(.top, 23).padding(.bottom, 20) }
    private func hint(_ text: String) -> some View { Text(text).font(.system(size: 13)).foregroundStyle(Color.nightrMuted).fixedSize(horizontal: false, vertical: true) }
    private func duration(_ title: String, help: String, value: Binding<Int>, slider: ClosedRange<Double>, full: ClosedRange<Int>) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                hint(help)
            }
            HStack(spacing: 12) {
                Slider(value: Binding(get: { min(slider.upperBound, max(slider.lowerBound, Double(value.wrappedValue))) }, set: { value.wrappedValue = Int($0) }), in: slider, step: 1)
                    .accessibilityLabel(title)
                NumericInput(key: title, value: value, range: full).frame(width: 83)
                Text("seconds").font(.system(size: 12)).foregroundStyle(Color.nightrMuted).frame(width: 58, alignment: .leading)
            }
            if value.wrappedValue >= 60 {
                Text(durationHint(value.wrappedValue)).font(.system(size: 12)).foregroundStyle(Color.nightrMuted)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            if Double(value.wrappedValue) < slider.lowerBound || Double(value.wrappedValue) > slider.upperBound {
                hint("Outside the slider range. Exact value retained.")
            }
        }.padding(.vertical, 13)
    }
    private func durationHint(_ seconds: Int) -> String {
        let minutes = seconds / 60, remainder = seconds % 60
        return "\(minutes) \(minutes == 1 ? "minute" : "minutes")" + (remainder == 0 ? "" : " \(remainder) seconds")
    }
    private var display: Binding<Int> {
        Binding(get: { draft.dim ? 2 : (draft.displayOn ? 1 : 0) }, set: { draft.dim = $0 == 2; draft.displayOn = $0 != 0 })
    }
    private func condition(_ key: WritableKeyPath<NightrCore.Settings, Bool>) -> Binding<Bool> {
        Binding(get: { draft[keyPath: key] }, set: { draft[keyPath: key] = $0; draft.requirement = .all; conditionsEdited = true })
    }
    private func load() {
        guard !loaded else { return }
        do {
            if let initialDraft { draft = initialDraft }
            else if let store { expected = try? Data(contentsOf: store.url); draft = try store.load() }
            original = draft; loaded = true
        } catch { self.error = error.localizedDescription }
    }
    private func save() async {
        guard let store, !saving else { return }
        saving = true
        defer { saving = false }
        var registration: DesktopRegistrationReceipt?
        var committed = false
        do {
            guard numbers.invalid.isEmpty else { throw SettingsError.invalid("Correct the highlighted integer fields before saving.") }
            try draft.validate()
            guard draft.forever || !conditionsEdited || draft.agent || draft.internet else { throw SettingsError.invalid("Select one, or choose Until I stop.") }
            let enabling = draft.launchAtLogin && !original.launchAtLogin
            let disabling = !draft.launchAtLogin && (original.launchAtLogin || pendingLoginRemoval)
            if enabling {
                do { registration = try DesktopSetup.login(enabled: true) }
                catch {
                    throw DesktopServiceError(error.localizedDescription + " Your preferences remain pending. Resolve the login setting, then retry Save.")
                }
            }
            var committedBytes: Data?
            do {
                try CredentialTransaction(store: KeychainCredentials()).commit(edit: credential) {
                    if let networkSecurity {
                        try NetworkSecurityStore().replacing(ssid: draft.hotspotSSID, security: networkSecurity) {
                            committedBytes = try store.save(draft, expected: expected)
                        }
                    } else { committedBytes = try store.save(draft, expected: expected) }
                }
            } catch {
                let originalError = error
                if let registration {
                    do { try registration.rollback() }
                    catch { throw DesktopServiceError(originalError.localizedDescription + " " + error.localizedDescription) }
                }
                throw originalError
            }
            committed = true
            pendingLoginRemoval = disabling
            credential = .unchanged; networkSecurity = nil
            original = draft; expected = committedBytes
            try await apply(draft)
            if pendingLoginRemoval {
                _ = try DesktopSetup.login(enabled: false)
                pendingLoginRemoval = false
            }
            error = nil
            if registration?.pending.isEmpty == false { savedApprovalNotice = true }
            else { close() }
        } catch {
            if committed || pendingLoginRemoval {
                self.error = "Settings saved; " + (pendingLoginRemoval ? "login removal incomplete. " : "controller update incomplete. ") + error.localizedDescription
            } else { self.error = error.localizedDescription }
            saveFocused = true
        }
    }

}

@MainActor final class NumericDrafts: ObservableObject {
    @Published var invalid: Set<String> = []
    var texts: [String: String] = [:]
    @Published var revision = 0
    func reset() { texts = [:]; invalid = []; revision += 1 }
}
struct NumericInput: View {
    let key: String
    @Binding var value: Int
    let range: ClosedRange<Int>
    @EnvironmentObject private var drafts: NumericDrafts
    @State private var text = ""
    private var invalid: Bool { drafts.invalid.contains(key) }
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            TextField("", text: $text).textFieldStyle(.roundedBorder)
                .accessibilityLabel(key)
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(invalid ? Color.red : Color.clear))
            if invalid { Text("Whole number required").font(.system(size: 10)).foregroundStyle(.red).fixedSize() }
        }
        .onAppear { text = drafts.texts[key] ?? String(value) }
        .onChange(of: drafts.revision) { _ in text = String(value) }
        .onChange(of: value) { new in
            if Int(text) != new { text = String(new); drafts.texts[key] = text; drafts.invalid.remove(key) }
        }
        .onChange(of: text) { new in
            drafts.texts[key] = new
            // Imported values outside the convenient UI range survive untouched.
            if new == String(value) { drafts.invalid.remove(key); return }
            guard !new.isEmpty, new.utf8.allSatisfy({ (48...57).contains($0) }), let integer = Int(new), range.contains(integer) else { drafts.invalid.insert(key); return }
            drafts.invalid.remove(key); value = integer
        }
    }
}
#endif
