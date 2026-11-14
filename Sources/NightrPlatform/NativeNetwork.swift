import Foundation
#if os(macOS)
import CoreWLAN
import CoreLocation
import Security

public struct NativeNetworkWorker {
    public init() {}
    public func scan() -> NetworkObservation {
        guard CLLocationManager.locationServicesEnabled() else { return .init(state: .disabled) }
        switch CLLocationManager().authorizationStatus {
        case .notDetermined: return .init(state: .permission)
        case .denied, .restricted: return .init(state: .denied)
        case .authorizedAlways, .authorizedWhenInUse: break
        @unknown default: return .init(state: .unavailable)
        }
        guard let interface = CWWiFiClient.shared().interface() else { return .init(state: .unavailable) }
        guard interface.powerOn() else { return .init(state: .off) }
        do {
            let current = interface.ssid()
            let records = try interface.scanForNetworks(withSSID: nil).compactMap { network -> NetworkRecord? in
                guard let ssid = network.ssid else { return nil }
                let security: NetworkSecurity = network.supportsSecurity(.none) ? .open :
                    (network.supportsSecurity(.unknown) ? .unknown : .password)
                return NetworkRecord(ssid: ssid, signal: network.rssiValue, security: security, current: current.map { sameSSID(ssid, $0) } ?? false)
            }
            return .init(state: .complete, networks: Array(NetworkObservation.ordered(records).prefix(256)))
        } catch { return .init(state: .failed) }
    }
    public func join(ssid: String) -> NativeJoinOutcome {
        guard CLLocationManager.locationServicesEnabled() else { return .permissionDenied }
        switch CLLocationManager().authorizationStatus {
        case .authorizedAlways, .authorizedWhenInUse: break
        default: return .permissionDenied
        }
        guard validSSID(ssid), let interface = CWWiFiClient.shared().interface(), interface.powerOn() else { return .unavailable }
        do {
            let networks = try interface.scanForNetworks(withSSID: Data(ssid.utf8))
            guard let network = networks.filter({ $0.ssid.map { sameSSID($0, ssid) } ?? false }).max(by: { $0.rssiValue < $1.rssiValue }) else { return .notSeen }
            let classification = try NetworkSecurityStore().security(ssid: ssid)
            let stored: Data?
            if network.supportsSecurity(.none) && classification == .open { stored = nil }
            else { stored = try credentialPassword(ssid: ssid) }
            let password: String?
            if network.supportsSecurity(.none), classification == .password || stored != nil { return .credentialMissing }
            if network.supportsSecurity(.unknown) { return .credentialMissing }
            if network.supportsSecurity(.none) { password = nil }
            else {
                guard let data = stored,
                      let value = String(data: data, encoding: .utf8), !value.isEmpty else { return .credentialMissing }
                password = value
            }
            try interface.associate(to: network, password: password)
            return .associated
        } catch is KeychainFailure { return .credentialMissing }
        catch { return .failed }
    }
    public func credentialStatus(ssid: String) -> NativeCredentialStatus {
        guard validSSID(ssid) else { return .missing }
        do { return try credentialPassword(ssid: ssid).map { $0.isEmpty ? .missing : .available } ?? .missing }
        catch { return .authorization }
    }
    private func credentialPassword(ssid: String) throws -> Data? {
        // This function runs only inside the owned one-shot worker. CoreWLAN has
        // no per-call UI option, so suppress interaction for this process, then
        // restore the prior setting. Never copy a macOS Wi-Fi password to config.
        var allowed: DarwinBoolean = false
        guard SecKeychainGetUserInteractionAllowed(&allowed) == errSecSuccess,
              SecKeychainSetUserInteractionAllowed(false) == errSecSuccess else { throw KeychainFailure(status: errSecInteractionNotAllowed) }
        defer { _ = SecKeychainSetUserInteractionAllowed(allowed.boolValue) }
        return try SavedCredentialPolicy.password(primary: {
            try KeychainCredentials(interactionAllowed: false).read(ssid: ssid)
        }, savedWiFi: { try savedWiFiPassword(ssid: ssid) })
    }
    private func savedWiFiPassword(ssid: String) throws -> Data? {
        for domain in [CWKeychainDomain.user, .system] {
            var password: NSString?
            let status = CWKeychainFindWiFiPassword(domain, Data(ssid.utf8), &password)
            if status == errSecSuccess, let password, password.length > 0 { return Data((password as String).utf8) }
            guard status == errSecItemNotFound else { throw KeychainFailure(status: status) }
        }
        return nil
    }
}

@MainActor
public final class DiscoveryPermission: NSObject, CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    public override init() { super.init(); manager.delegate = self }
    public func request() { manager.requestAlwaysAuthorization() }
    nonisolated public func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {}
}
#endif

public enum NativeJoinOutcome: String, Codable, Sendable {
    case associated, notSeen, credentialMissing, permissionDenied, unavailable, failed
}
public enum NativeCredentialStatus: String, Codable, Sendable {
    case available, missing, authorization
}

public struct NetworkWorkerClient: Sendable {
    public let executable: URL
    public init(executable: URL) { self.executable = executable }
    public func scan(process: BoundedProcess) throws -> NetworkObservation {
        let data = try process.run(executable: executable, arguments: ["scan"], timeout: 10)
        return try JSONDecoder().decode(NetworkObservation.self, from: data)
    }
    public func join(ssid: String, timeout: TimeInterval, process: BoundedProcess) throws -> NativeJoinOutcome {
        guard validSSID(ssid) else { throw NativeOperationError.malformed }
        let data = try process.run(executable: executable, arguments: ["join"],
                                   input: JSONEncoder().encode(ssid), timeout: min(timeout, 30))
        return try JSONDecoder().decode(NativeJoinOutcome.self, from: data)
    }
    public func credentialStatus(ssid: String, process: BoundedProcess) throws -> NativeCredentialStatus {
        guard validSSID(ssid) else { throw NativeOperationError.malformed }
        let data = try process.run(executable: executable, arguments: ["credential-status"], input: JSONEncoder().encode(ssid), timeout: 5)
        return try JSONDecoder().decode(NativeCredentialStatus.self, from: data)
    }
}
