#if os(macOS)
import SwiftUI
import AppKit
import NightrPlatform

private enum NetworkSource: String, CaseIterable, Identifiable { case saved = "Saved", nearby = "Nearby", manual = "Manual"; var id: String { rawValue } }
// An AppKit secure field owns the uncommitted text. No SwiftUI binding publishes it.
private final class PasswordInput {
    weak var field: NSSecureTextField?
    func take() -> Data? {
        guard let field, !field.stringValue.isEmpty else { return nil }
        defer { field.stringValue = "" }
        return Data(field.stringValue.utf8)
    }
    func clear() { field?.stringValue = "" }
}
private struct NativePasswordField: NSViewRepresentable {
    let input: PasswordInput
    func makeNSView(context: Context) -> NSSecureTextField {
        let field = NSSecureTextField(); field.placeholderString = "Password"; field.setAccessibilityLabel("Network password"); input.field = field; return field
    }
    func updateNSView(_ nsView: NSSecureTextField, context: Context) { input.field = nsView }
    static func dismantleNSView(_ nsView: NSSecureTextField, coordinator: ()) { nsView.stringValue = "" }
}

struct NetworkChooser: View {
    let configured: String
    let pending: CredentialEdit
    let pendingSecurity: NetworkSecurity?
    let use: (String, CredentialEdit, NetworkSecurity?) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var source: NetworkSource = .saved
    @State private var selected = ""
    @State private var manual = ""
    @State private var manualSecurity = NetworkSecurity.password
    @State private var nearbySecurity: [Data: NetworkSecurity] = [:]
    @State private var saved: [String] = []
    @State private var observation: NetworkObservation?
    @State private var scanning = false
    @State private var generation = UUID()
    @State private var scanProcess: BoundedProcess?
    @State private var error: String?
    @State private var password = PasswordInput()
    @State private var permission = DiscoveryPermission()
    @State private var credentialState: NativeCredentialStatus?
    @State private var credentialIdentity: Data?
    @State private var credentialGeneration = UUID()
    @State private var credentialProcess: BoundedProcess?
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Choose hotspot").font(.headline)
            Picker("Networks", selection: $source) { ForEach(NetworkSource.allCases) { Text($0.rawValue).tag($0) } }.pickerStyle(.segmented)
            Group {
                switch source {
                case .saved: savedList
                case .nearby: nearbyList
                case .manual: manualForm
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            if source != .saved, validSSID(name) {
                if source == .nearby && (observation?.networks.first(where: { sameSSID($0.ssid, name) })?.security ?? .unknown) == .unknown {
                    Picker("Network security", selection: Binding(get: { nearbySecurity[ssidIdentity(name)] ?? .unknown }, set: { password.clear(); nearbySecurity[ssidIdentity(name)] = $0 })) {
                        Text("Choose security").tag(NetworkSecurity.unknown); Text("Open").tag(NetworkSecurity.open); Text("Password required").tag(NetworkSecurity.password)
                    }
                }
                if security == .password {
                    if hasCredential { Text("Saved password will be reused.").font(.callout).foregroundStyle(.secondary) }
                    else if credentialState == nil { Text("Checking saved access…").font(.callout).foregroundStyle(.secondary) }
                    else {
                        if credentialState == .authorization { Text("Saved password needs access repair in Settings.").font(.callout).foregroundStyle(.secondary) }
                        NativePasswordField(input: password).frame(height: 25)
                    }
                }
            }
            if let error { Text(error).font(.callout).foregroundStyle(.red) }
            Divider()
            HStack {
                Spacer(); Button("Cancel") { close() }.keyboardShortcut(.cancelAction)
                Button("Use network") { commit() }.keyboardShortcut(.defaultAction).disabled(!validSSID(name) || (source != .saved && security == .unknown) || (source != .saved && security == .password && credentialState == nil))
            }
        }.padding(20).frame(width: 480, height: 420)
        .onAppear {
            selected = configured; manual = configured
            do { saved = try KeychainCredentials(interactionAllowed: false).savedSSIDs(); if !configured.isEmpty && !saved.contains(where: { sameSSID($0, configured) }) { saved.insert(configured, at: 0) } }
            catch { self.error = error.localizedDescription; saved = configured.isEmpty ? [] : [configured] }
        }
        .onChange(of: source) { _ in password.clear(); error = nil }
        .onChange(of: ssidIdentity(selected)) { _ in password.clear(); error = nil }
        .onChange(of: ssidIdentity(manual)) { _ in password.clear(); error = nil }
        .onChange(of: manualSecurity) { _ in password.clear(); error = nil }
        .task(id: credentialLookupID) { await inspectCredential() }
        .onDisappear { generation = UUID(); scanProcess?.cancel(); credentialGeneration = UUID(); credentialProcess?.cancel(); password.clear() }
    }
    private var credentialLookupID: String { source.rawValue + ":" + ssidIdentity(name).base64EncodedString() + ":" + security.rawValue }
    private var savedAccessLabel: String {
        if !validSSID(name) { return "Select a saved network. Passwords stay in Keychain." }
        if hasCredential { return "Saved password is available to Nightr." }
        if credentialState == nil { return "Checking saved access…" }
        return credentialState == .authorization ? "Saved credential needs authorization. Use hotspot access repair in Settings if a join is blocked." : "No saved password found. Use macOS Wi-Fi settings or Manual to add one."
    }
    private var selectionIdentity: Binding<Data> {
        Binding(get: { ssidIdentity(selected) }, set: { identity in
            if let record = observation?.networks.first(where: { $0.id == identity }) { selected = record.ssid }
            else if let name = saved.first(where: { ssidIdentity($0) == identity }) { selected = name }
        })
    }
    private var name: String { source == .manual ? manual : selected }
    private var security: NetworkSecurity {
        if source == .manual { return manualSecurity }
        return nearbySecurity[ssidIdentity(name)] ?? observation?.networks.first(where: { sameSSID($0.ssid, name) })?.security ?? .unknown
    }
    private var hasCredential: Bool {
        if case .password(let ssid, _) = pending, sameSSID(ssid, name) { return true }
        return credentialIdentity == ssidIdentity(name) && credentialState == .available
    }
    private var savedList: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Keychain and configured networks").font(.callout).foregroundStyle(.secondary)
            if saved.isEmpty { Text("No saved hotspot. Use Nearby or Manual.") }
            Picker("Saved networks", selection: selectionIdentity) {
                ForEach(saved.map { NetworkRecord(ssid: $0) }) { record in
                let ssid = record.ssid
                VStack(alignment: .leading, spacing: 3) {
                    Text(ssid)
                    Text((sameSSID(ssid, configured) ? "Configured · " : "Saved · ") + (observation?.availability(of: ssid) ?? "Availability unknown")).font(.caption).foregroundStyle(.secondary)
                }.tag(ssidIdentity(ssid))
                }
            }.pickerStyle(.radioGroup).labelsHidden()
            Text(savedAccessLabel).font(.callout).foregroundStyle(.secondary)
        }
    }
    private var nearbyList: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(scanning ? "Scanning…" : stateLabel).font(.callout).foregroundStyle(.secondary)
                Spacer(); Button("Refresh") { refresh() }.disabled(scanning)
            }
            if observation?.state == .permission {
                Button("Enable discovery…") { permission.request() }
            }
            if let observation, observation.state == .denied || observation.state == .disabled {
                Button("Open Location Services settings…") { NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocationServices")!) }
            }
            ScrollView {
                Picker("Nearby networks", selection: selectionIdentity) {
                    ForEach(observation?.networks ?? []) { record in
                        HStack { Text(record.ssid); if record.current { Text("Current").font(.caption) }; Image(systemName: record.security == .open ? "wifi" : "lock.fill") }.tag(ssidIdentity(record.ssid))
                    }
                }.pickerStyle(.radioGroup).labelsHidden()
            }
        }.onAppear { if observation == nil { refresh() } }
    }
    private var manualForm: some View {
        VStack(alignment: .leading, spacing: 12) {
            TextField("Exact Wi-Fi name", text: $manual).textFieldStyle(.roundedBorder)
            Text("1–32 UTF-8 bytes. Spaces and letter case are preserved.").font(.callout).foregroundStyle(.secondary)
            Picker("Security", selection: $manualSecurity) { Text("Password required").tag(NetworkSecurity.password); Text("Open").tag(NetworkSecurity.open) }.pickerStyle(.radioGroup)
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
        case .failed: return "Scan failed · availability unknown"
        case nil: return "Not scanned"
        }
    }
    private func refresh() {
        scanProcess?.cancel()
        let id = UUID(); generation = id; scanning = true
        let process = BoundedProcess(); scanProcess = process
        let worker = NetworkWorkerClient(executable: Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/NightrNetworkWorker"))
        Task {
            let result = await Task.detached { try? worker.scan(process: process) }.value
            guard generation == id else { return }
            observation = result ?? .init(state: .failed); scanning = false; scanProcess = nil
        }
    }
    private func inspectCredential() async {
        credentialProcess?.cancel()
        let id = UUID(); credentialGeneration = id
        let exactName = name, identity = ssidIdentity(name)
        credentialIdentity = identity; credentialState = nil
        guard validSSID(exactName) else { return }
        if case .password(let ssid, _) = pending, sameSSID(ssid, exactName) { credentialState = .available; return }
        let process = BoundedProcess(); credentialProcess = process
        let worker = NetworkWorkerClient(executable: Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/NightrNetworkWorker"))
        let result = await withTaskCancellationHandler {
            await Task.detached { try? worker.credentialStatus(ssid: exactName, process: process) }.value
        } onCancel: { process.cancel() }
        guard !Task.isCancelled, credentialGeneration == id, ssidIdentity(name) == identity else { return }
        credentialState = result ?? .authorization; credentialProcess = nil
    }
    private func close() { password.clear(); generation = UUID(); scanProcess?.cancel(); credentialGeneration = UUID(); credentialProcess?.cancel(); dismiss() }
    private func commit() {
        guard validSSID(name) else { error = "Enter a valid exact Wi-Fi name."; return }
        var edit: CredentialEdit = .unchanged
        if source == .saved {
            // List selection cannot create, clear, or reclassify a saved credential.
            if case .password(let ssid, _) = pending, sameSSID(ssid, name) { edit = pending }
        } else if security == .password {
            if case .password(let ssid, _) = pending, sameSSID(ssid, name) { edit = pending }
            else if !hasCredential {
                guard let data = password.take() else { error = "Enter the network password."; return }
                edit = .password(ssid: name, data: data)
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
