#if os(macOS)
import CoreLocation
import NightrCore
import NightrPlatform
import NightrPowerClient
import ServiceManagement
import SwiftUI
import UserNotifications

@MainActor struct GuidedSetup: View {
    enum Step: String {
        case welcome = "Set up Nightr"
        case helper = "Allow the power helper"
        case features = "Choose your features"
        case notifications = "Allow hotspot notifications"
        case location = "Allow nearby Wi-Fi discovery"
        case finish = "Nightr is ready"
    }

    @ObservedObject var model: AppModel
    let finish: () -> Void
    @State private var step = Step.welcome
    @State private var login = false
    @State private var alerts = false
    @State private var nearby = false
    @State private var loaded = false
    @State private var helperVerified = false
    @State private var helperMessage = "Checking the power helper…"
    @State private var working = false
    @State private var notice = ""
    @State private var authorization = UNAuthorizationStatus.notDetermined
    @State private var location = CLAuthorizationStatus.notDetermined
    @State private var locationEnabled = false
    @State private var discovery = DiscoveryPermission()

    private var steps: [Step] {
        [.welcome, .helper, .features] + (alerts ? [.notifications] : []) + (nearby ? [.location] : []) + [.finish]
    }
    private var index: Int { steps.firstIndex(of: step) ?? 0 }
    private var helperReady: Bool { model.helperStatus == .enabled && helperVerified }
    private var allowed: Bool {
        switch step {
        case .helper: return helperReady
        case .notifications: return [.authorized, .provisional].contains(authorization)
        case .location: return locationEnabled && location == .authorizedAlways
        default: return true
        }
    }
    private var description: String {
        switch step {
        case .welcome: return "Nightr keeps your Mac awake while your agents work. Set up the power helper, then choose the features you want."
        case .helper: return "Nightr uses a background helper to keep your Mac awake and restore your power settings afterward."
        case .features: return "You can change these later in Settings."
        case .notifications: return "Allow Nightr to send you notifications about hotspot recovery."
        case .location: return "macOS requires Location access to show nearby Wi-Fi names. You can also enter your hotspot’s name yourself."
        case .finish: return "Open Nightr in the menu bar to see your protection status."
        }
    }
    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading) {
                HStack { ForEach(steps.indices, id: \.self) { i in
                    Capsule().fill(i <= index ? Color.accentColor : Color.secondary.opacity(0.3)).frame(height: 4)
                } }
                Text("Step \(index + 1) of \(steps.count)").foregroundStyle(.secondary)
            }.padding(24)
            Spacer()
            VStack(spacing: 14) {
                NightrAppIcon().frame(width: 56, height: 56)
                Text(step.rawValue).font(.title.bold())
                Text(description).foregroundStyle(.secondary).multilineTextAlignment(.center)
                controls
                if !notice.isEmpty { Text(notice).foregroundStyle(.secondary).multilineTextAlignment(.center) }
            }.frame(maxWidth: 460)
            Spacer()
            Divider()
            HStack {
                Button("Back") { move(-1) }.disabled(index == 0)
                if [.notifications, .location].contains(step) && !allowed { Button("Skip for Now") { move(1) } }
                Spacer()
                Button(step == .finish ? "Open Nightr" : "Continue") {
                    if step == .finish { finish() }
                    else if step == .features { Task { await applyLogin() } }
                    else { move(1) }
                }.keyboardShortcut(.defaultAction).disabled(!allowed || !loaded)
            }.padding(18)
        }.frame(width: 630, height: 465).disabled(working)
        .task {
            do { login = try model.store.load().launchAtLogin; loaded = true }
            catch { notice = error.localizedDescription }
            await refresh()
            alerts = [.authorized, .provisional].contains(authorization)
            nearby = locationEnabled && location == .authorizedAlways
            while !Task.isCancelled {
                do { try await Task.sleep(nanoseconds: 1_000_000_000) } catch { return }
                await refresh()
            }
        }
    }
    @ViewBuilder private var controls: some View {
        switch step {
        case .features:
            VStack(alignment: .leading, spacing: 10) {
                Toggle(isOn: $login) { Text("Open Nightr at login"); Text("Show Nightr in the menu bar when you sign in.") }
                Toggle(isOn: $alerts) { Text("Hotspot notifications"); Text("Get updates about hotspot recovery.") }
                Toggle(isOn: $nearby) { Text("Nearby Wi-Fi networks"); Text("Find a backup hotspot by name.") }
                if login && DesktopSetup.loginPending {
                    Button("Review in Login Items") { SMAppService.openSystemSettingsLoginItems() }
                }
            }
        case .helper, .notifications, .location:
            if allowed { Label(step == .helper ? "Ready" : "Allowed", systemImage: "checkmark.circle.fill").foregroundStyle(.green) }
            else if step == .helper {
                if model.helperStatus == .missingBundleFiles { Text("The power helper is missing from this copy of Nightr. Reinstall Nightr to continue.") }
                else if model.helperStatus == .enabled {
                    Text(helperMessage)
                    Button("Check Again") { Task { await refresh() } }
                } else {
                    if model.helperStatus == .requiresApproval { Text("Open Login Items and allow Nightr to run in the background.") }
                    Button(model.helperStatus == .requiresApproval ? "Open Login Items" : "Set Up Helper") { model.setupHelper() }
                    if let error = model.setupError { Text(error) }
                }
            } else if step == .notifications {
                Button(authorization == .denied ? "Open Notification Settings" : "Allow Notifications") {
                    if authorization == .denied { open("com.apple.Notifications-Settings.extension") }
                    else { Task { do { try await DesktopSetup.notifications() } catch { notice = error.localizedDescription }; await refresh() } }
                }
            } else {
                let needsSettings = !locationEnabled || [.restricted, .denied].contains(location)
                Button(needsSettings ? "Open Location Settings" : "Allow Location Access") {
                    if needsSettings { open("com.apple.preference.security?Privacy_LocationServices") } else { discovery.request() }
                }
            }
        default: EmptyView()
        }
    }
    private func open(_ pane: String) {
        if let url = URL(string: "x-apple.systempreferences:" + pane) { NSWorkspace.shared.open(url) }
    }
    private func refresh() async {
        if step == .helper && DesktopSetup.helperStatus == .enabled {
            if let team = MacControllerPlatform.signedTeam(), let client = try? SignedPowerClient(teamID: team) {
                let reply = try? await withCheckedThrowingContinuation { continuation in
                    client.status { continuation.resume(with: $0) }
                }
                helperVerified = reply?.restorationBlocked == false
                helperMessage = reply?.restorationBlocked == true ? "Power settings need attention. Nightr still needs to restore power settings from an earlier run." : "The power helper didn’t respond."
            } else { helperVerified = false; helperMessage = "Reinstall the signed copy of Nightr to verify the power helper." }
        } else { helperVerified = false }
        authorization = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
        location = CLLocationManager().authorizationStatus
        locationEnabled = CLLocationManager.locationServicesEnabled()
    }
    private func move(_ offset: Int) { notice = ""; step = steps[index + offset] }
    private func applyLogin() async {
        guard !working else { return }
        working = true
        defer { working = false }
        do {
            let expected = try? Data(contentsOf: model.store.url)
            var settings = try model.store.load()
            let receipt = login ? try DesktopSetup.login(enabled: true) : nil
            if settings.launchAtLogin != login {
                settings.launchAtLogin = login
                do { try model.store.save(settings, expected: expected) }
                catch { try receipt?.rollback(); throw error }
            }
            if !login { _ = try DesktopSetup.login(enabled: false) }
            try await model.applySettingsForSave(settings)
            if receipt?.pending.isEmpty == false { notice = DesktopSetup.approvalGuidance }
            else { move(1) }
        } catch { notice = error.localizedDescription }
    }
}
#endif
