#if os(macOS)
import SwiftUI
import AppKit
import UserNotifications
import NightrCore
import NightrController
import NightrPlatform

struct SettingsHost: View {
    @ObservedObject var model: AppModel
    let close: () -> Void
    var body: some View {
        SettingsView(section: $model.presentation.section, status: model.status, store: model.store,
                     setForce: { model.command($0 ? .beginForce : .endForce) }, apply: { try await model.applySettingsForSave($0) }, close: close)
    }
}

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
    let setForce: (Bool) -> Void
    @State private var saving = false
    @State private var pendingLoginRemoval = false
    @State private var savedApprovalNotice = false
    @State private var notificationStatus: UNAuthorizationStatus?
    @Environment(\.controlActiveState) private var activeState
    @StateObject private var numbers = NumericDrafts()
    @FocusState private var saveFocused: Bool
    init(section: Binding<NightrSettingsSection>, status: ControllerStatus?, store: SettingsStore? = nil,
         initialDraft: NightrCore.Settings? = nil, notificationStatus: UNAuthorizationStatus? = nil,
         setForce: @escaping (Bool) -> Void = { _ in }, readHotspotMode: @escaping () -> HotspotJoinMode = HotspotJoinMode.current, apply: @escaping (NightrCore.Settings) async throws -> Void = { _ in }, close: @escaping () -> Void = {}) {
        self.setForce = setForce
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
                CompactSettingsForm(draft: $draft, section: section,
                                    notifications: Binding(get: { notificationsAllowed }, set: { _ in manageNotifications() }),
                                    notificationsReady: notificationStatus != nil, force: status?.forceMode == true,
                                    toggleForce: { setForce(status?.forceMode != true) }, condition: condition,
                                    internet: internet, mode: hotspotMode, outage: outage,
                                    repair: needsCredential ? repairAccess : nil) {
                    Button(draft.hotspotSSID.isEmpty ? "Choose network…" : draft.hotspotSSID) { chooser = true }
                        .lineLimit(1).accessibilityLabel("Choose hotspot").help(draft.hotspotSSID)
                }
            }
            .disabled(saving)
            Divider()
            if let error { Text(error).font(.system(size: 13)).foregroundStyle(.red).textSelection(.enabled).padding(.horizontal, 18).padding(.top, 10) }
            HStack {
                Button("Reset") { draft = NightrCore.Settings(); credential = .unchanged; conditionsEdited = false; networkSecurity = nil; error = nil; numbers.reset() }.buttonStyle(SettingsActionStyle()).disabled(saving)
                Spacer()
                Button("Cancel") { credential = .unchanged; close() }.buttonStyle(SettingsActionStyle()).disabled(saving).keyboardShortcut(.cancelAction)
                Button { Task { await save() } } label: {
                    Text(error == nil ? "Save" : "Retry Save")
                }.buttonStyle(SettingsActionStyle(primary: true)).keyboardShortcut(.defaultAction).focused($saveFocused).disabled(saving || !loaded || !numbers.invalid.isEmpty)
            }.padding(.horizontal, SettingsLayout.formInset).padding(.vertical, 12)
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
                draft.hotspotSSID = ssid; draft.hotspot = !ssid.isEmpty; credential = edit; networkSecurity = security
            }
        }
        .alert("Login setting saved", isPresented: $savedApprovalNotice) {
            Button("OK") { close() }
        } message: { Text(DesktopSetup.approvalGuidance) }
        .task(id: activeState) {
            hotspotMode = readHotspotMode()
            await refreshNotifications()
        }
    }
    private var internet: String {
        if status?.forceMode == true { return "Checks paused" }
        if status?.state.internet == .verified { return "Connected" }
        return GUIProtectionSummary(status: status).internet
    }
    private var outage: String? {
        guard let outage = status?.state.outage else { return nil }
        return "\(outage.consumed) of \(outage.capturedLimit) hotspot attempts used"
    }
    private var needsCredential: Bool {
        status?.state.outage?.repairRequired == .missingCredential && !draft.hotspotSSID.isEmpty
    }
    private func repairAccess() {
        do { try KeychainCredentials().repairAccess(ssid: draft.hotspotSSID); error = nil }
        catch { self.error = "Hotspot access was not authorized. Unlock Keychain and retry." }
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

#endif
