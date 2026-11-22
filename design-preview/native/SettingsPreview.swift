import AppKit
import SwiftUI
import NightrCore

private struct PreviewSettings: View {
    let session: NSMutableDictionary
    @State private var tab: NightrSettingsSection
    @State private var draft: NightrCore.Settings
    @State private var notifications: Bool
    @State private var force: Bool
    @State private var mode = HotspotJoinMode.current()
    @StateObject private var numbers = NumericDrafts()
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
                CompactSettingsForm(draft: $draft, section: tab, notifications: $notifications,
                                    notificationsReady: true, force: force, toggleForce: { force.toggle() },
                                    condition: { $draft[dynamicMember: $0] },
                                    internet: force ? "Checks paused" : "Connected", mode: mode) {
                    Menu {
                        ForEach(["Travel hotspot", "Sample iPhone"], id: \.self) { name in
                            Button(name) { draft.hotspotSSID = name; draft.hotspot = true }
                        }
                    } label: { Text(draft.hotspotSSID.isEmpty ? "Choose network…" : draft.hotspotSSID) }
                    .frame(width: 154).accessibilityLabel("Choose hotspot")
                }
            }
            Divider()
            HStack(spacing: 9) {
                Button("Reset") { draft = NightrCore.Settings(); notifications = true; numbers.reset() }.buttonStyle(SettingsActionStyle())
                Spacer()
                Text(saved ? "Saved in preview" : "Local preview").font(.system(size: 11)).foregroundStyle(Color.nightrMuted)
                Button("Cancel") {
                    numbers.reset()
                    draft = Self.settings(session["savedDraft"])
                    notifications = session["savedNotifications"] as? Bool ?? true
                }.buttonStyle(SettingsActionStyle())
                Button("Save") {
                    session["savedDraft"] = try? JSONEncoder().encode(draft)
                    session["savedNotifications"] = notifications
                    saved = true
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
        .onChange(of: force) { session["force"] = $0 }
        .task(id: active) { mode = .current() }
    }

}

@MainActor @_cdecl("makeNightrSettingsPreview")
public func makeNightrSettingsPreview(_ state: UnsafeMutableRawPointer) -> UnsafeMutableRawPointer {
    let session = Unmanaged<NSMutableDictionary>.fromOpaque(state).takeUnretainedValue()
    let view = NSHostingView(rootView: PreviewSettings(session: session))
    if #available(macOS 14, *) { view.safeAreaRegions = [] }
    return Unmanaged.passRetained(view as NSView).toOpaque()
}
