#if os(macOS)
import SwiftUI
import AppKit
import NightrCore
import NightrController
import NightrPlatform

private enum SettingsSection: String, CaseIterable, Identifiable {
    case general = "General", protection = "Protection", connectivity = "Connectivity", advanced = "Advanced"
    var id: String { rawValue }
    var symbol: String { switch self { case .general: return "gearshape"; case .protection: return "moon"; case .connectivity: return "wifi"; case .advanced: return "slider.horizontal.3" } }
}

struct SettingsView: View {
    @ObservedObject var model: AppModel
    var initialConnectivity = false
    let close: () -> Void
    @State private var section = SettingsSection.general
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
    @StateObject private var numbers = NumericDrafts()
    @FocusState private var saveFocused: Bool
    var body: some View {
        VStack(spacing: 0) {
            HStack { Text("Nightr Settings").font(.headline); Spacer() }.padding(18)
            Picker("Section", selection: $section) {
                ForEach(SettingsSection.allCases) { item in Label(item.rawValue, systemImage: item.symbol).tag(item) }
            }.pickerStyle(.segmented).padding(.horizontal, 18).padding(.bottom, 14)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    switch section {
                    case .general: general
                    case .protection: protection
                    case .connectivity: connectivity
                    case .advanced: advanced
                    }
                }.font(.system(size: 15)).padding(20).frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider()
            if let error { Text(error).font(.system(size: 13)).foregroundStyle(.red).textSelection(.enabled).padding(.horizontal, 18).padding(.top, 10) }
            HStack {
                Button("Reset") { draft = NightrCore.Settings(); credential = .unchanged; conditionsEdited = false; networkSecurity = nil; error = nil; numbers.reset() }
                Spacer()
                Button("Cancel") { credential = .unchanged; close() }.keyboardShortcut(.cancelAction)
                Button(error == nil ? "Save" : "Retry Save") { save() }.keyboardShortcut(.defaultAction).focused($saveFocused).disabled(saving || !loaded || !numbers.invalid.isEmpty)
            }.padding(18)
        }.frame(width: 600, height: 540)
        .environmentObject(numbers)
        .onAppear(perform: load)
        .sheet(isPresented: $chooser) {
            NetworkChooser(configured: draft.hotspotSSID, pending: credential, pendingSecurity: networkSecurity) { ssid, edit, security in
                draft.hotspotSSID = ssid; credential = edit; networkSecurity = security
            }
        }
        .alert("Auto-join iPhone hotspot: Not checked", isPresented: $guidance) {
            Button("Open Wi-Fi settings") { DesktopSetup.systemWiFi() }
            Button("Close", role: .cancel) {}
        } message: {
            Text("Nightr has not read this macOS setting. Check System Settings → Wi-Fi → Ask to join hotspots. Instant Hotspot needs eligible nearby devices on the same Apple Account or Family Sharing with Wi-Fi and Bluetooth. Automatic joining requires macOS Tahoe 26 or later. Saved Wi-Fi fallback is separate.")
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
            Text(model.status?.sample.setupReady == true ? "Ready" : "Authorization required for closed-lid protection")
            Button("Set up Nightr…") { do { try DesktopSetup.complete() } catch { self.error = error.localizedDescription } }
            hint("Setup authorizes the signed helper and registers your saved login preference. Saving preferences does not install the helper.")
        }
    }
    private var protection: some View {
        VStack(alignment: .leading, spacing: 13) {
            Picker("Keep Mac awake", selection: $draft.forever) {
                Text("Automatically").tag(false)
                Text("Until I stop").tag(true)
            }.pickerStyle(.radioGroup)
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
        VStack(alignment: .leading, spacing: 13) {
            Text("Connection").fontWeight(.semibold)
            HStack {
                Image(systemName: "wifi")
                Text(model.status?.state.internet.rawValue.capitalized ?? "Not checked")
                Spacer()
                Text("Observed").font(.system(size: 11)).foregroundStyle(.secondary)
            }.padding(10).background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 5))
            if let outage = model.status?.state.outage {
                hint(model.status?.verificationEligible == true ? "\(outage.consumed) of \(outage.capturedLimit) attempts used · still checking internet" : "Internet checks are paused.")
            }
            Divider()
            Text("Hotspot fallback").fontWeight(.semibold)
            Toggle("Use saved hotspot", isOn: $draft.hotspot)
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Hotspot").frame(width: 92, alignment: .leading)
                    Text(draft.hotspotSSID.isEmpty ? "None selected" : draft.hotspotSSID).lineLimit(1).help(draft.hotspotSSID)
                    Spacer(); Button("Choose…") { chooser = true }
                }
                HStack { Text("Try after").frame(width: 92, alignment: .leading); NumericInput(key: "hotspotAfter", value: $draft.hotspotAfter, range: 0...2147483647).frame(width: 78); Text("seconds") }
                HStack { Text("Total attempts").frame(width: 115, alignment: .leading); NumericInput(key: "hotspotAttempts", value: $draft.hotspotAttempts, range: 1...10).frame(width: 52) }
                hint("Internet checks continue after the attempt limit.")
            }.padding(.leading, 18).disabled(!draft.hotspot)
            if model.status?.state.outage?.repairRequired == .missingCredential, !draft.hotspotSSID.isEmpty {
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
        VStack(alignment: .leading, spacing: 13) {
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
        if initialConnectivity { section = .connectivity }
        do {
            expected = try? Data(contentsOf: model.store.url)
            draft = try model.store.load(); original = draft; loaded = true
        } catch { self.error = error.localizedDescription }
    }
    private func save() {
        do {
            guard numbers.invalid.isEmpty else { throw SettingsError.invalid("Correct the highlighted integer fields before saving.") }
            try draft.validate()
            guard draft.forever || !conditionsEdited || draft.agent || draft.internet else { throw SettingsError.invalid("Select one, or choose Until I stop.") }
            // Login authorization belongs to setup; a user-intended preference change may
            // register/unregister it, and a failure leaves config/credentials untouched.
            if draft.launchAtLogin != original.launchAtLogin { try DesktopSetup.login(enabled: draft.launchAtLogin) }
            do {
                try CredentialTransaction(store: KeychainCredentials()).commit(edit: credential) {
                    if let networkSecurity {
                        try NetworkSecurityStore().replacing(ssid: draft.hotspotSSID, security: networkSecurity) {
                            try model.store.save(draft, expected: expected)
                        }
                    } else { try model.store.save(draft, expected: expected) }
                }
            } catch {
                if draft.launchAtLogin != original.launchAtLogin { try? DesktopSetup.login(enabled: original.launchAtLogin) }
                throw error
            }
            credential = .unchanged
            model.command(.applySettings, settings: draft)
            close()
        } catch { self.error = error.localizedDescription; saveFocused = true }
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
