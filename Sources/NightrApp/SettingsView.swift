#if os(macOS)
import SwiftUI
import AppKit
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
    @State private var guidance = false
    @State private var saving = false
    @State private var pendingLoginRemoval = false
    @State private var savedApprovalNotice = false
    @StateObject private var numbers = NumericDrafts()
    @FocusState private var saveFocused: Bool
    init(section: Binding<NightrSettingsSection>, status: ControllerStatus?, store: SettingsStore? = nil,
         initialDraft: NightrCore.Settings? = nil, apply: @escaping (NightrCore.Settings) async throws -> Void = { _ in }, close: @escaping () -> Void = {}) {
        _section = section; self.status = status; self.store = store; self.initialDraft = initialDraft
        self.apply = apply; self.close = close
        if let initialDraft { _draft = State(initialValue: initialDraft); _original = State(initialValue: initialDraft); _loaded = State(initialValue: true) }
    }
    var body: some View {
        VStack(spacing: 0) {
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
                }.font(.system(size: 15)).padding(.horizontal, 26).padding(.vertical, 16).frame(maxWidth: .infinity, alignment: .leading)
            }
            .disabled(saving)
            Divider()
            if let error { Text(error).font(.system(size: 13)).foregroundStyle(.red).textSelection(.enabled).padding(.horizontal, 18).padding(.top, 10) }
            HStack {
                Button("Reset") { draft = NightrCore.Settings(); credential = .unchanged; conditionsEdited = false; networkSecurity = nil; error = nil; numbers.reset() }.tint(.primary).disabled(saving)
                Text("Changes stay pending until Save.").font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer(minLength: 10)
                Button("Cancel") { credential = .unchanged; close() }.tint(.primary).disabled(saving).keyboardShortcut(.cancelAction)
                Button { Task { await save() } } label: {
                    Text(error == nil ? "Save" : "Retry Save").foregroundColor(Color(red: 0.15, green: 0.11, blue: 0.04))
                }.buttonStyle(.borderedProminent).tint(.nightrButtonAmber).keyboardShortcut(.defaultAction).focused($saveFocused).disabled(saving || !loaded || !numbers.invalid.isEmpty)
            }.padding(.horizontal, 20).padding(.vertical, 14)
        }.frame(width: 600, height: 540)
        .background(Color(nsColor: .windowBackgroundColor))
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
        .alert("Auto-join iPhone hotspot: Not checked", isPresented: $guidance) {
            Button("Open Wi-Fi settings") { DesktopSetup.systemWiFi() }
            Button("Close", role: .cancel) {}
        } message: {
            Text("Not checked. Auto-join controls how your Mac joins an eligible iPhone hotspot. Review it in System Settings → Wi-Fi → Ask to join hotspots.")
        }
    }
    private var general: some View {
        VStack(alignment: .leading, spacing: 12) {
            Toggle("Launch Nightr at login", isOn: $draft.launchAtLogin)
            hint("Login opens Nightr. Protection resumes only when you previously enabled it. Stop stays stopped.")
            Button("Enable hotspot notifications…") {
                Task { do { try await DesktopSetup.notifications() } catch { self.error = error.localizedDescription } }
            }
            Divider()
            Text("Power helper").fontWeight(.semibold)
            Text(status.map { $0.sample.setupReady ? "Ready" : "Authorization required for closed-lid protection" } ?? "Not checked")
            Button("Set up Nightr…") { do { try DesktopSetup.complete() } catch { self.error = error.localizedDescription } }
            hint("Setup authorizes the signed helper and registers your saved login preference. Saving preferences does not install the helper.")
        }
    }
    private var protection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Keep Mac awake").fontWeight(.semibold)
            Picker("Keep Mac awake", selection: $draft.forever) {
                Text("Automatically").tag(false)
                Text("Until I stop").tag(true)
            }.pickerStyle(.radioGroup).labelsHidden()
            if !draft.forever {
                VStack(alignment: .leading, spacing: 8) {
                    Toggle("Agent is active", isOn: condition(\.agent))
                    Toggle("Internet is available", isOn: condition(\.internet))
                    if draft.requirement != .all { hint("Custom CLI policy retained") }
                    else if draft.agent && draft.internet { hint("Both must apply.") }
                    if conditionsEdited && !draft.agent && !draft.internet { Text("Select one, or choose Until I stop.").font(.system(size: 13)).foregroundStyle(.red) }
                }.padding(.leading, 18)
            }
            Divider()
            Text("When lid closes").fontWeight(.semibold)
            HStack {
                Text("Display").frame(width: 115, alignment: .leading)
                Picker("Display", selection: display) { Text("Off").tag(0); Text("On").tag(1); Text("Dim").tag(2) }.labelsHidden().frame(width: 145)
            }
            Toggle("Lock Mac", isOn: $draft.lock)
            Divider()
            Text("On battery").fontWeight(.semibold)
            HStack {
                Toggle("Allow sleep below", isOn: $draft.batteryProtection).fixedSize()
                NumericInput(key: "batteryBelow", value: $draft.batteryBelow, range: 1...100).frame(width: 52).disabled(!draft.batteryProtection)
                Text("%")
            }
            hint("Plug in or recharge to resume.")
        }
    }
    private var connectivity: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Connection").fontWeight(.semibold)
            HStack {
                Image(systemName: "wifi")
                Text(GUIProtectionSummary(status: status).internet)
                Spacer()
                Text("Observed").font(.system(size: 11)).foregroundStyle(.secondary)
            }.padding(10).background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 5))
            if let outage = status?.state.outage {
                hint(status?.verificationEligible == true ? "\(outage.consumed) of \(outage.capturedLimit) attempts used · still checking internet" : "Internet checks are paused.")
            }
            Divider()
            Text("Hotspot fallback").fontWeight(.semibold)
            Toggle("Use saved hotspot", isOn: $draft.hotspot)
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Hotspot").frame(width: 115, alignment: .leading)
                    Text(draft.hotspotSSID.isEmpty ? "None selected" : draft.hotspotSSID).lineLimit(1).help(draft.hotspotSSID)
                    Spacer(); Button("Choose…") { chooser = true }
                }
                HStack { Text("Try after").frame(width: 115, alignment: .leading); NumericInput(key: "hotspotAfter", value: $draft.hotspotAfter, range: 0...2147483647).frame(width: 78); Text("seconds") }
                HStack { Text("Total attempts").frame(width: 115, alignment: .leading); NumericInput(key: "hotspotAttempts", value: $draft.hotspotAttempts, range: 1...10).frame(width: 52) }
                hint("Internet checks continue after the attempt limit.")
            }.padding(.leading, 18).disabled(!draft.hotspot)
            if status?.state.outage?.repairRequired == .missingCredential, !draft.hotspotSSID.isEmpty {
                Button("Authorize hotspot access…") {
                    do { try KeychainCredentials().repairAccess(ssid: draft.hotspotSSID); error = nil }
                    catch { self.error = "Hotspot access was not authorized. Unlock Keychain and retry." }
                }
            }
            Divider()
            Text("macOS settings").fontWeight(.semibold)
            hint("Status only · change in System Settings")
            HStack {
                Image(systemName: "minus.square").font(.system(size: 20)).accessibilityLabel("Not checked")
                Text("Auto-join iPhone hotspot")
                Spacer(); Button("Not checked…") { guidance = true }
            }
        }
    }
    private var advanced: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Automatic checks").fontWeight(.semibold)
            duration("Check every", value: $draft.every, slider: 1...300, full: 1...3600)
            hint("How often to check the conditions selected in Protection.")
            Divider()
            Text("Before allowing sleep").fontWeight(.semibold)
            duration("Wait before retrying", value: $draft.grace, slider: 0...3600, full: 0...86400)
            hint("Keep awake through pauses or lost internet before retrying.")
            HStack { Text("Extra attempts").frame(width: 160, alignment: .leading); NumericInput(key: "retries", value: $draft.retries, range: 0...10).frame(width: 52) }
            hint(draft.retries == 0 ? "No extra attempts" : "Retry failed conditions before allowing sleep.")
            duration("First retry delay", value: $draft.backoff, slider: 1...300, full: 1...300).disabled(draft.retries == 0)
            hint("Later waits double, up to 5 minutes.")
            Divider(); hint("These limits apply when the lid is closed.")
        }
    }
    private func hint(_ text: String) -> some View { Text(text).font(.system(size: 13)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
    private func duration(_ title: String, value: Binding<Int>, slider: ClosedRange<Double>, full: ClosedRange<Int>) -> some View {
        HStack {
            Text(title).frame(width: 160, alignment: .leading)
            Slider(value: Binding(get: { min(slider.upperBound, max(slider.lowerBound, Double(value.wrappedValue))) }, set: { value.wrappedValue = Int($0) }), in: slider, step: 1).frame(width: 135).accessibilityLabel(title)
            NumericInput(key: title, value: value, range: full).frame(width: 67)
            Text("seconds").font(.system(size: 13))
        }
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
            if enabling { registration = try DesktopSetup.login(enabled: true) }
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
