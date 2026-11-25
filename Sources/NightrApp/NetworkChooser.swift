#if os(macOS)
import SwiftUI
import AppKit
import NightrPlatform

private enum NetworkSource: String, CaseIterable, Identifiable { case saved = "Saved", nearby = "Nearby", manual = "Manual"; var id: String { rawValue } }
// An AppKit secure field owns the uncommitted text. No SwiftUI binding publishes it.
private final class PasswordInput: NSObject, ObservableObject, NSTextFieldDelegate {
    @Published private(set) var hasText = false
    func controlTextDidChange(_ notification: Notification) {
        hasText = field?.stringValue.isEmpty == false
    }
    weak var field: NSSecureTextField?
    func take() -> Data? {
        guard let field, !field.stringValue.isEmpty else { return nil }
        defer { clear() }
        return Data(field.stringValue.utf8)
    }
    func clear() {
        field?.stringValue = ""
        hasText = false
    }
}
private struct NativePasswordField: NSViewRepresentable {
    let input: PasswordInput
    let label: String
    func makeNSView(context: Context) -> NSSecureTextField {
        let field = NSSecureTextField()
        field.placeholderString = "Enter password"
        field.font = .systemFont(ofSize: 14)
        field.isBezeled = false
        field.isBordered = false
        field.drawsBackground = false
        field.delegate = input
        input.field = field
        return field
    }
    func updateNSView(_ nsView: NSSecureTextField, context: Context) { input.field = nsView; nsView.setAccessibilityLabel(label) }
    static func dismantleNSView(_ nsView: NSSecureTextField, coordinator: ()) { nsView.stringValue = "" }
}

struct NetworkChooserData {
    var saved: @Sendable () throws -> [String]
    var scan: @Sendable (BoundedProcess) throws -> NetworkObservation
    var credential: @Sendable (String, BoundedProcess) throws -> NativeCredentialStatus

    static var live: Self {
        let worker = NetworkWorkerClient(executable: Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/NightrNetworkWorker"))
        return Self(saved: { try KeychainCredentials(interactionAllowed: false).savedSSIDs() },
                    scan: { try worker.scan(process: $0) },
                    credential: { try worker.credentialStatus(ssid: $0, process: $1) })
    }
}

struct NetworkChooser: View {
    let configured: String
    let pending: CredentialEdit
    let pendingSecurity: NetworkSecurity?
    var data = NetworkChooserData.live
    let use: (String, CredentialEdit, NetworkSecurity?) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var source: NetworkSource = .saved
    @State private var selectedSaved = ""
    @State private var selectedNearby = ""
    @State private var manual = ""
    @State private var manualSecurity = NetworkSecurity.password
    @State private var nearbySecurity: [Data: NetworkSecurity] = [:]
    @State private var saved: [String] = []
    @State private var loadingSaved = true
    @State private var observation: NetworkObservation?
    @State private var scanning = false
    @State private var generation = UUID()
    @State private var scanProcess: BoundedProcess?
    @State private var error: String?
    @StateObject private var password = PasswordInput()
    @State private var permission: DiscoveryPermission?
    @State private var passwordEntryID: String?
    @State private var credentialState: NativeCredentialStatus?
    @State private var completedLookupID: String?
    @State private var checkedSource: NetworkSource?
    @State private var credentialGeneration = UUID()
    @State private var credentialProcess: BoundedProcess?
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Choose hotspot").font(.system(size: 16, weight: .semibold))
                Picker("Networks", selection: $source) {
                    ForEach(NetworkSource.allCases) { Text($0.rawValue).tag($0) }
                }.pickerStyle(.segmented).labelsHidden().accessibilityLabel("Network source")
            }
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Text(sectionTitle).font(.system(size: 13, weight: .semibold))
                    Spacer()
                    if source == .nearby { Button("Refresh") { refresh() }.disabled(scanning) }
                }.frame(height: 26)
                switch source {
                case .saved: savedList
                case .nearby: nearbyList
                case .manual: manualForm
                }
                if source == .nearby { credentials }
                if let error { Text(error).font(.callout).foregroundStyle(.red) }
            }
            .padding(.top, 14)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            Divider().padding(.vertical, 12)
            HStack(spacing: 8) {
                Spacer()
                Button("Cancel") { close() }.buttonStyle(SettingsActionStyle()).keyboardShortcut(.cancelAction)
                Button("Use network") { commit() }.buttonStyle(SettingsActionStyle(primary: true)).keyboardShortcut(.defaultAction).disabled(!canUseNetwork)
            }
        }.padding(SettingsLayout.formInset).frame(width: 440, height: 360)
        .foregroundStyle(.primary).tint(.nightrAmber)
        .background(Color.nightrSurface)
        .onAppear {
            selectedSaved = configured; manual = configured
        }
        .task(id: source) {
            guard source == .saved else { return }
            loadingSaved = true
            let lookup = data.saved
            let result = await Task.detached { Result { try lookup() } }.value
            guard !Task.isCancelled else { return }
            switch result {
            case .success(let names): saved = names
            case .failure(let failure): saved = []; error = failure.localizedDescription
            }
            if !configured.isEmpty && !saved.contains(where: { sameSSID($0, configured) }) {
                saved.insert(configured, at: 0)
            }
            loadingSaved = false
        }
        .onChange(of: credentialLookupID) { _ in passwordEntryID = nil; password.clear(); error = nil }
        .task(id: credentialLookupID) { await inspectCredential() }
        .onDisappear { generation = UUID(); scanProcess?.cancel(); credentialGeneration = UUID(); credentialProcess?.cancel(); password.clear() }
    }
    private var sectionTitle: String {
        switch source {
        case .saved: return "Saved networks"
        case .nearby: return "Nearby networks"
        case .manual: return "Network details"
        }
    }

    @ViewBuilder private var credentials: some View {
        if validSSID(name) {
            if source == .nearby && (observation?.networks.first(where: { sameSSID($0.ssid, name) })?.security ?? .unknown) == .unknown {
                Picker("Network security", selection: Binding(get: { nearbySecurity[ssidIdentity(name)] ?? .unknown }, set: { password.clear(); nearbySecurity[ssidIdentity(name)] = $0 })) {
                    Text("Choose security").tag(NetworkSecurity.unknown); Text("Open").tag(NetworkSecurity.open); Text("Password required").tag(NetworkSecurity.password)
                }
            }
            if security == .password {
                Divider()
                if !enteringNearbyPassword && (hasCredential || (currentCredential == nil && !keepManualField)) {
                    settingsRow("Password") {
                        HStack {
                            NightrStatusLabel(text: hasCredential ? "Saved" : "Checking…",
                                              tone: hasCredential ? .confirmed : .checking)
                            if source == .nearby {
                                Spacer()
                                Button(hasCredential ? "Change password" : "Enter password") {
                                    passwordEntryID = credentialLookupID
                                }
                                .buttonStyle(.link)
                            }
                        }.frame(width: inputWidth, alignment: .leading)
                    }
                }
                else {
                    if currentCredential == .authorization { Text("Saved password needs access repair in Settings.").font(.system(size: 13)).foregroundStyle(Color.nightrMuted) }
                    settingsRow("Password", hint: source == .nearby ? "Verified on the first connection attempt." : nil) {
                        settingsField(width: inputWidth, accented: true) {
                            Image(systemName: "key.fill").foregroundStyle(Color.nightrAmber).accessibilityHidden(true)
                            NativePasswordField(input: password, label: "Password for \(name)")
                        }
                    }
                }
            }
        }
    }

    private var credentialLookupID: String { source.rawValue + ":" + ssidIdentity(name).base64EncodedString() + ":" + security.rawValue }
    private var enteringNearbyPassword: Bool { source == .nearby && passwordEntryID == credentialLookupID }
    private var canUseNetwork: Bool {
        guard validSSID(name) else { return false }
        if source == .saved || security == .open { return true }
        guard security == .password else { return false }
        if enteringNearbyPassword { return password.hasText }
        return hasCredential || (currentCredential != nil && password.hasText)
    }
    private var currentCredential: NativeCredentialStatus? {
        completedLookupID == credentialLookupID ? credentialState : nil
    }
    // Keep an existing entry field mounted while the user types a different SSID.
    // Only the completed lookup for the exact current request can enable Use network.
    private var keepManualField: Bool {
        source == .manual && checkedSource == .manual && (credentialState == .missing || credentialState == .authorization)
    }
    private var savedAccessNotice: String? {
        if hasCredential || (sameSSID(name, configured) && pendingSecurity == .open) { return nil }
        if currentCredential == nil { return "Checking saved access…" }
        return currentCredential == .authorization ? "Saved credential needs authorization. Use hotspot access repair in Settings if a join is blocked." : "No password available to Nightr. If this network needs one, enter it in Manual."
    }
    private var selectionIdentity: Binding<Data?> {
        Binding(get: { name.isEmpty ? nil : ssidIdentity(name) }, set: { identity in
            switch source {
            case .saved: selectedSaved = saved.first { ssidIdentity($0) == identity } ?? ""
            case .nearby: selectedNearby = observation?.networks.first { $0.id == identity }?.ssid ?? ""
            case .manual: break
            }
        })
    }
    private var name: String {
        switch source {
        case .saved: return selectedSaved
        case .nearby: return selectedNearby
        case .manual: return manual
        }
    }
    private var security: NetworkSecurity {
        if source == .manual { return manualSecurity }
        return nearbySecurity[ssidIdentity(name)] ?? observation?.networks.first(where: { sameSSID($0.ssid, name) })?.security ?? .unknown
    }
    private var hasCredential: Bool {
        if case .password(let ssid, _) = pending, sameSSID(ssid, name) { return true }
        return currentCredential == .available
    }
    private var savedList: some View {
        VStack(alignment: .leading, spacing: 8) {
            if loadingSaved { ProgressView("Loading saved networks…").controlSize(.small) }
            else if saved.isEmpty && error == nil { Text("No saved networks. Choose Nearby or Manual.") }
            List(saved.map { NetworkRecord(ssid: $0) }, selection: selectionIdentity) { record in
                HStack {
                    Text(verbatim: record.ssid)
                    Spacer()
                    if sameSSID(record.ssid, configured) { Text("Configured").font(.system(size: 12)) }
                }.font(.system(size: 14)).tag(record.id)
            }.listStyle(.plain).scrollContentBackground(.hidden).accessibilityLabel("Saved networks")
            if validSSID(name), let savedAccessNotice { Text(savedAccessNotice).font(.system(size: 13)).foregroundStyle(Color.nightrMuted) }
        }
    }
    private var nearbyList: some View {
        VStack(alignment: .leading, spacing: 8) {
            if scanning {
                ProgressView("Scanning…").controlSize(.small)
            } else if observation?.state != .complete || observation?.networks.isEmpty == true {
                Text(stateLabel).font(.system(size: 13)).foregroundStyle(Color.nightrMuted)
            }
            if observation?.state == .permission {
                Button("Enable discovery…") { if permission == nil { permission = DiscoveryPermission() }; permission?.request() }
            }
            if let observation, observation.state == .denied || observation.state == .disabled {
                Button("Open Location Services settings…") { NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocationServices")!) }
            }
            List(observation?.networks ?? [], selection: selectionIdentity) { record in
                HStack {
                    Text(verbatim: record.ssid)
                    Spacer()
                    if record.current { Text("Current").font(.system(size: 12)) }
                    Image(systemName: record.security == .open ? "wifi" : "lock.fill")
                }.font(.system(size: 14)).tag(record.id)
            }.listStyle(.plain).scrollContentBackground(.hidden).accessibilityLabel("Nearby networks")
        }.onAppear { if observation == nil { refresh() } }
    }
    private let inputWidth: CGFloat = 206
    private var manualForm: some View {
        VStack(alignment: .leading, spacing: 0) {
            settingsRow("Network name") {
                settingsField(width: inputWidth) {
                    TextField("Exact Wi-Fi name", text: $manual).textFieldStyle(.plain)
                        .accessibilityLabel("Network name")
                }
            }
            if !manual.isEmpty && !validSSID(manual) {
                Text("Enter 1–32 UTF-8 bytes without control characters.")
                    .font(.callout).foregroundStyle(.red)
            }
            Divider()
            settingsRow("Security") {
                settingsChoiceMenu("Security", selection: $manualSecurity,
                                   options: [(.password, "Password required"), (.open, "Open")], width: inputWidth)
            }
            credentials
        }
    }
    private var stateLabel: String {
        switch observation?.state {
        case .complete: return observation?.networks.isEmpty == true ? "No networks found" : "Nearby networks"
        case .permission: return "Discovery needs Location permission"
        case .denied: return "Location permission denied"
        case .disabled: return "Location Services are disabled"
        case .off: return "Wi-Fi is off"
        case .unavailable: return "Wi-Fi discovery is unavailable"
        case .failed: return "Scan failed, availability unknown"
        case nil: return "Not scanned"
        }
    }
    private func refresh() {
        scanProcess?.cancel()
        let id = UUID(); generation = id; scanning = true
        let process = BoundedProcess(); scanProcess = process
        let scan = data.scan
        Task {
            let result = await Task.detached { try? scan(process) }.value
            guard generation == id else { return }
            observation = result ?? .init(state: .failed); scanning = false; scanProcess = nil
        }
    }
    private func inspectCredential() async {
        credentialProcess?.cancel()
        let id = UUID(); credentialGeneration = id
        let exactName = name, lookupID = credentialLookupID
        completedLookupID = nil
        guard validSSID(exactName), source == .saved || security == .password else { return }
        if case .password(let ssid, _) = pending, sameSSID(ssid, exactName) {
            credentialState = .available; checkedSource = source; completedLookupID = lookupID
            return
        }
        if source == .manual {
            do { try await Task.sleep(for: .milliseconds(150)) } catch { return }
        }
        let process = BoundedProcess(); credentialProcess = process
        let inspect = data.credential
        let result = await withTaskCancellationHandler {
            await Task.detached { try? inspect(exactName, process) }.value
        } onCancel: { process.cancel() }
        guard !Task.isCancelled, credentialGeneration == id, credentialLookupID == lookupID else { return }
        credentialState = result ?? .authorization
        checkedSource = source; completedLookupID = lookupID; credentialProcess = nil
    }
    private func close() { password.clear(); generation = UUID(); scanProcess?.cancel(); credentialGeneration = UUID(); credentialProcess?.cancel(); dismiss() }
    private func commit() {
        guard validSSID(name) else { error = "Enter a valid exact Wi-Fi name."; return }
        var edit: CredentialEdit = .unchanged
        if source == .saved {
            // List selection cannot create, clear, or reclassify a saved credential.
            if case .password(let ssid, _) = pending, sameSSID(ssid, name) { edit = pending }
        } else if security == .password {
            if enteringNearbyPassword || !hasCredential {
                guard enteringNearbyPassword || currentCredential != nil else { return }
                guard let data = password.take() else { error = "Enter the network password."; return }
                edit = .password(ssid: name, data: data)
            } else if case .password(let ssid, _) = pending, sameSSID(ssid, name) {
                edit = pending
            }
        } else if security == .open {
            // Only an explicit Manual conversion authorizes removing an old entry.
            if source == .manual { edit = .explicitOpen(ssid: name) }
        } else { error = "Choose Open or Password required."; return }
        let classification = source == .saved ? (sameSSID(name, configured) ? pendingSecurity : nil) : security
        use(name, edit, classification); close()
    }
}
#endif
