import AppKit
import SwiftUI
import NightrCore
import NightrPlatform

private struct PreviewSettings: View {
    let session: NSMutableDictionary
    @State private var tab: NightrSettingsSection
    @State private var draft: NightrCore.Settings
    @State private var notifications: Bool
    @State private var chooser = false
    @State private var forced = false
    @StateObject private var numbers = NumericDrafts()
    @State private var saved = false
    @State private var automaticUpdates: Bool
    @State private var updates = DesktopUpdatePresentation.sample
    @State private var simulateInstall = false
    @State private var conditionsEdited = false
    @State private var protectionError: String?

    init(session: NSMutableDictionary) {
        self.session = session
        _tab = State(initialValue: NightrSettingsSection(rawValue: session["tab"] as? String ?? "") ?? .general)
        _draft = State(initialValue: Self.settings(session["draft"]))
        _forced = State(initialValue: session["force"] as? Bool ?? true)
        _notifications = State(initialValue: session["notifications"] as? Bool ?? true)
        _automaticUpdates = State(initialValue: session["automaticUpdates"] as? Bool ?? true)
    }

    private static func settings(_ data: Any?) -> NightrCore.Settings {
        if let data = data as? Data, let value = try? JSONDecoder().decode(NightrCore.Settings.self, from: data) { return value }
        return NightrCore.Settings()
    }

    private var access: PreviewNetworkAccess { PreviewNetworkAccess(session: session) }
    var body: some View {
        VStack(spacing: 0) {
            SettingsWindowTitle().frame(height: 21).padding(.top, 14)
            SettingsToolbar(selection: $tab)
            Divider()
            ScrollView {
                CompactSettingsForm(draft: $draft, section: tab, notifications: $notifications,
                                    notificationsReady: true, condition: condition,
                                    internet: forced ? "Checks paused" : "Connected", mode: HotspotJoinMode(rawValue: session["joinMode"] as? String ?? "Automatic") ?? .unknown, forceMode: forced, setForceMode: { enabled in
                    session["force"] = enabled
                    forced = enabled
                    NotificationCenter.default.post(name: .previewForceChanged, object: session)
                }, updates: updates, automaticUpdates: $automaticUpdates, updateAction: {
                    if updates.phase.readyVersion != nil { simulateInstall = true }
                    else if updates.version == "0.1.0" { updates.phase = .ready("0.1.1") }
                }) {
                    Button(draft.hotspotSSID.isEmpty ? "Choose network…" : draft.hotspotSSID) { chooser = true }
                }
            }
            Divider()
            if let protectionError { Text(protectionError).font(.system(size: 13)).foregroundStyle(.red).padding(.top, 10) }
            HStack(spacing: 9) {
                Button("Reset") {
                    draft = NightrCore.Settings(); notifications = true; automaticUpdates = true
                    numbers.reset(); access.discard(); conditionsEdited = false; protectionError = nil
                }.buttonStyle(SettingsActionStyle())
                Spacer()
                Text(saved ? "Saved in preview" : "Local preview").font(.system(size: 11)).foregroundStyle(Color.nightrMuted)
                Button("Cancel") {
                    access.discard()
                    numbers.reset()
                    conditionsEdited = false; protectionError = nil
                    draft = Self.settings(session["savedDraft"])
                    notifications = session["savedNotifications"] as? Bool ?? true
                    automaticUpdates = session["savedAutomaticUpdates"] as? Bool ?? true
                    NotificationCenter.default.post(name: .previewCloseSettings, object: nil)
                }.buttonStyle(SettingsActionStyle())
                Button("Save") {
                    do { try draft.validateProtectionSelection(edited: conditionsEdited) }
                    catch { protectionError = error.localizedDescription; return }
                    access.save()
                    session["savedDraft"] = try? JSONEncoder().encode(draft)
                    session["savedNotifications"] = notifications
                    session["savedAutomaticUpdates"] = automaticUpdates
                    saved = true
                    conditionsEdited = false; protectionError = nil
                    NotificationCenter.default.post(name: .previewSettingsSaved, object: nil)
                    NotificationCenter.default.post(name: .previewCloseSettings, object: nil)
                }.buttonStyle(SettingsActionStyle(primary: true)).keyboardShortcut(.defaultAction).disabled(!numbers.invalid.isEmpty)
            }.padding(.horizontal, 22).padding(.vertical, 12)
        }
        .font(.system(size: 15)).foregroundStyle(Color.nightrInk).tint(.nightrAmber)
        .background(Color.nightrSurface).frame(width: SettingsLayout.width, height: SettingsLayout.bodyHeight)
        .ignoresSafeArea(.container, edges: .top)
        .environmentObject(numbers)
        .onChange(of: tab) { session["tab"] = $0.rawValue }
        .onChange(of: draft) { session["draft"] = try? JSONEncoder().encode($0); saved = false }
        .onChange(of: notifications) { session["notifications"] = $0; saved = false }
        .onChange(of: automaticUpdates) { session["automaticUpdates"] = $0; saved = false }
        .alert("Install Nightr 0.1.1?", isPresented: $simulateInstall) {
            Button("Cancel", role: .cancel) { }
            Button("Simulate Install") { updates = .init(version: "0.1.1", build: "b71e506", phase: .current) }
        } message: { Text("Nightr will reopen after installation. Terminal will ask for administrator approval.") }
        .onReceive(NotificationCenter.default.publisher(for: .previewOpenSettings)) { request in
            let destination = request.userInfo?["section"] as? String
            tab = destination.flatMap(NightrSettingsSection.init(rawValue:)) ?? .general
        }
        .onReceive(NotificationCenter.default.publisher(for: .previewStateChanged)) { _ in
            forced = session["force"] as? Bool ?? true
        }
        .sheet(isPresented: $chooser) {
            NetworkChooser(configured: draft.hotspotSSID, pending: access.pending(for: draft.hotspotSSID),
                           pendingSecurity: access.security(for: draft.hotspotSSID),
                           data: .sample(savedAccess: access.saved)) { ssid, edit, security in
                access.stage(ssid, edit, security)
                draft.hotspotSSID = ssid
                draft.hotspot = true
            }
        }
    }

    private func condition(_ key: WritableKeyPath<NightrCore.Settings, Bool>) -> Binding<Bool> {
        Binding(get: { draft[keyPath: key] }, set: {
            draft.setProtectionCondition(key, enabled: $0)
            conditionsEdited = true; protectionError = nil
        })
    }
}

@MainActor @_cdecl("makeNightrSettingsPreview")
public func makeNightrSettingsPreview(_ state: UnsafeMutableRawPointer) -> UnsafeMutableRawPointer {
    let session = Unmanaged<NSMutableDictionary>.fromOpaque(state).takeUnretainedValue()
    let view = NSHostingView(rootView: PreviewSettings(session: session))
    if #available(macOS 14, *) { view.safeAreaRegions = [] }
    return Unmanaged.passRetained(view as NSView).toOpaque()
}

// The preview remembers credential availability by exact SSID, never password bytes.
private struct PreviewNetworkAccess {
    let session: NSMutableDictionary
    var saved: [Data: Bool] { session["previewSavedAccess"] as? [Data: Bool] ?? [:] }

    func security(for ssid: String) -> NetworkSecurity? {
        if session["previewNetworkSSID"] as? Data == Data(ssid.utf8),
           let raw = session["previewNetworkSecurity"] as? String { return NetworkSecurity(rawValue: raw) }
        return saved[Data(ssid.utf8)].map { $0 ? .password : .open }
    }

    func pending(for ssid: String) -> CredentialEdit {
        guard session["previewNetworkSSID"] as? Data == Data(ssid.utf8) else { return .unchanged }
        switch session["previewCredentialEdit"] as? String {
        case "password": return .password(ssid: ssid, data: Data())
        case "open": return .explicitOpen(ssid: ssid)
        default: return .unchanged
        }
    }

    func stage(_ ssid: String, _ edit: CredentialEdit, _ security: NetworkSecurity?) {
        discard()
        session["previewNetworkSSID"] = Data(ssid.utf8)
        session["previewNetworkSecurity"] = security?.rawValue
        switch edit {
        case .password: session["previewCredentialEdit"] = "password"
        case .explicitOpen: session["previewCredentialEdit"] = "open"
        case .unchanged: break
        }
    }

    func save() {
        if let id = session["previewNetworkSSID"] as? Data, let edit = session["previewCredentialEdit"] as? String {
            var updated = saved
            updated[id] = edit == "password"
            session["previewSavedAccess"] = updated
        }
        discard()
    }

    func discard() {
        for key in ["previewCredentialEdit", "previewNetworkSSID", "previewNetworkSecurity"] { session.removeObject(forKey: key) }
    }
}

private extension NetworkChooserData {
    static func sample(savedAccess: [Data: Bool] = [:]) -> Self {
        Self(saved: {
            let fixtures = ["Travel hotspot", "Studio Wi-Fi"]
            let added = savedAccess.keys.filter { key in !fixtures.contains { Data($0.utf8) == key } }
            return fixtures + added.map { String(decoding: $0, as: UTF8.self) }.sorted()
        },
        scan: { _ in .init(state: .complete, networks: [
            .init(ssid: "Sample guest", security: .password),
            .init(ssid: "Travel hotspot", security: .password),
            .init(ssid: "Open guest Wi-Fi", security: .open)
        ]) },
        credential: { name, _ in
            (savedAccess[Data(name.utf8)] ?? (name == "Travel hotspot")) ? .available : .missing
        })
    }
}

// Offscreen checks use the same chooser and network fixtures as the interactive sheet.
@MainActor @_cdecl("makeNightrNetworkChooserPreview")
public func makeNightrNetworkChooserPreview(_ state: UnsafeMutableRawPointer) -> UnsafeMutableRawPointer {
    let session = Unmanaged<NSMutableDictionary>.fromOpaque(state).takeUnretainedValue()
    let access = PreviewNetworkAccess(session: session)
    let ssid = "Sample guest"
    let chooser = NetworkChooser(configured: ssid, pending: access.pending(for: ssid), pendingSecurity: access.security(for: ssid),
                                 data: .sample(savedAccess: access.saved)) { name, edit, security in
        access.stage(name, edit, security)
    }
    return Unmanaged.passRetained(NSHostingView(rootView: chooser) as NSView).toOpaque()
}
