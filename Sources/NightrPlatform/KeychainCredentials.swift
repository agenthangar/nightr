import Foundation

public enum CredentialAccessFailure: Error, LocalizedError {
    case untrustedInstallation, invalidTrustedApplication
    public var errorDescription: String? {
        "Authorize hotspot access from the signed Nightr app installed in Applications. Existing passwords need explicit Keychain authorization before unattended use."
    }
}

public struct CredentialProgramSignature: Sendable {
    public let identifier: String
    public let teamID: String
    public let validDeveloperID: Bool
    public init(identifier: String, teamID: String, validDeveloperID: Bool) {
        self.identifier = identifier; self.teamID = teamID; self.validDeveloperID = validDeveloperID
    }
}

/// The allowlist is deliberately fixed to the three installed executables that
/// consume credentials. A caller cannot add a path, unsigned tool, or another team.
public enum CredentialAccessPolicy {
    public static let application = URL(fileURLWithPath: "/Applications/Nightr.app/Contents/MacOS/NightrApp")
    public static let controller = URL(fileURLWithPath: "/Applications/Nightr.app/Contents/MacOS/nightr-native")
    public static let worker = URL(fileURLWithPath: "/Applications/Nightr.app/Contents/MacOS/NightrNetworkWorker")
    public static func trustedPrograms(teamID: String, inspect: (URL) throws -> CredentialProgramSignature) throws -> [URL] {
        guard teamID.range(of: "^[A-Z0-9]{10}$", options: .regularExpression) != nil else { throw CredentialAccessFailure.untrustedInstallation }
        let programs = [(application, "ai.nightr.app"), (worker, "ai.nightr.networkworker"), (controller, "ai.nightr.controller")]
        for (url, identifier) in programs {
            let signature = try inspect(url)
            guard signature.validDeveloperID, signature.teamID == teamID, signature.identifier == identifier else {
                throw CredentialAccessFailure.invalidTrustedApplication
            }
        }
        return programs.map(\.0)
    }
}

/// Existing-item writes retain their ACL. Only creation or a separate explicit
/// repair action constructs shared access. Injected closures keep tests Keychain-free.
public enum CredentialWritePolicy {
    public static func write<Access>(updateExisting: () throws -> Bool, createAccess: () throws -> Access,
                                     add: (Access) throws -> Void) throws {
        if try updateExisting() { return }
        let access = try createAccess()
        try add(access)
    }
    public static func repair<Access>(createAccess: () throws -> Access, authorizeAndSet: (Access) throws -> Void) throws {
        let access = try createAccess()
        try authorizeAndSet(access)
    }
}

public enum SavedCredentialPolicy {
    /// An inaccessible Nightr credential is a repair state, not permission to
    /// silently replace it with another password. Only absence permits fallback.
    public static func password(primary: () throws -> Data?, savedWiFi: () throws -> Data?) throws -> Data? {
        if let primary = try primary() { return primary }
        return try savedWiFi()
    }
}

#if os(macOS)
import Security
import LocalAuthentication
import CoreWLAN

public struct KeychainCredentials: CredentialStore {
    public static let service = "agenthangar.nosleep.hotspot"
    private let interactionAllowed: Bool
    public init(interactionAllowed: Bool = true) { self.interactionAllowed = interactionAllowed }
    private func query(_ ssid: String? = nil) -> [String: Any] {
        var result: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                   kSecAttrService as String: Self.service,
                                   kSecUseDataProtectionKeychain as String: false]
        if let ssid { result[kSecAttrAccount as String] = ssid }
        if !interactionAllowed { let context = LAContext(); context.interactionNotAllowed = true; result[kSecUseAuthenticationContext as String] = context }
        return result
    }
    public func contains(ssid: String) -> Bool {
        var request = query(ssid)
        let context = LAContext(); context.interactionNotAllowed = true
        request[kSecUseAuthenticationContext as String] = context
        request[kSecReturnAttributes as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        return SecItemCopyMatching(request as CFDictionary, nil) == errSecSuccess
    }
    private func check(_ status: OSStatus) throws {
        guard status == errSecSuccess || status == errSecItemNotFound else { throw KeychainFailure(status: status) }
    }
    public func read(ssid: String) throws -> Data? {
        var request = query(ssid)
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        try check(status)
        return status == errSecItemNotFound ? nil : result as? Data
    }
    public func write(ssid: String, password: Data) throws {
        guard validSSID(ssid), !password.isEmpty else { throw KeychainFailure(status: errSecParam) }
        try CredentialWritePolicy.write(updateExisting: {
            let attributes: [String: Any] = [kSecValueData as String: password]
            let status = SecItemUpdate(query(ssid) as CFDictionary, attributes as CFDictionary)
            if status == errSecItemNotFound { return false }
            try check(status); return true
        }, createAccess: sharedAccess) { access in
            var item = query(ssid)
            item[kSecValueData as String] = password
            item[kSecAttrAccess as String] = access
            try check(SecItemAdd(item as CFDictionary, nil))
        }
    }
    /// Call only from an explicit authorization/repair control. macOS can ask the
    /// user to approve this legacy ACL migration. Reads and browsing never call it.
    public func repairAccess(ssid: String) throws {
        guard interactionAllowed, validSSID(ssid) else { throw CredentialAccessFailure.untrustedInstallation }
        try CredentialWritePolicy.repair(createAccess: sharedAccess) { access in
            var request = query(ssid)
            request[kSecReturnRef as String] = true
            request[kSecMatchLimit as String] = kSecMatchLimitOne
            var result: CFTypeRef?
            let status = SecItemCopyMatching(request as CFDictionary, &result)
            if status == errSecItemNotFound {
                // Explicitly authorizing an ordinary macOS saved network may
                // require an OS Keychain prompt. Copy only this exact credential
                // into a newly protected Nightr item; never alter Apple's ACL.
                for domain in [CWKeychainDomain.user, .system] {
                    var password: NSString?
                    let found = CWKeychainFindWiFiPassword(domain, Data(ssid.utf8), &password)
                    if found == errSecSuccess, let password, password.length > 0 {
                        var item = query(ssid)
                        item[kSecValueData as String] = Data((password as String).utf8)
                        item[kSecAttrAccess as String] = access
                        try check(SecItemAdd(item as CFDictionary, nil)); return
                    }
                    guard found == errSecItemNotFound else { throw KeychainFailure(status: found) }
                }
                throw KeychainFailure(status: errSecItemNotFound)
            }
            guard status == errSecSuccess, let result else { throw KeychainFailure(status: status) }
            // kSecReturnRef for a file-keychain generic password returns this type.
            guard CFGetTypeID(result) == SecKeychainItemGetTypeID() else { throw CredentialAccessFailure.invalidTrustedApplication }
            let item = unsafeBitCast(result, to: SecKeychainItem.self)
            try check(SecKeychainItemSetAccess(item, access))
        }
    }
    public func remove(ssid: String) throws { try check(SecItemDelete(query(ssid) as CFDictionary)) }
    public func savedSSIDs() throws -> [String] {
        var request = query()
        request[kSecReturnAttributes as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitAll
        var result: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        let profiles = ((CWWiFiClient.shared().interface()?.configuration()?.networkProfiles.array as? [CWNetworkProfile]) ?? []).compactMap(\.ssid)
        let ours = status == errSecSuccess ? ((result as? [[String: Any]]) ?? []).compactMap { $0[kSecAttrAccount as String] as? String } : []
        if profiles.isEmpty { try check(status) }
        var unique: [Data: String] = [:]
        for name in profiles + ours where validSSID(name) { unique[ssidIdentity(name)] = name }
        return unique.values.sorted { $0.utf8.lexicographicallyPrecedes($1.utf8) }
    }

    private func sharedAccess() throws -> SecAccess {
        guard interactionAllowed,
              [CredentialAccessPolicy.application, CredentialAccessPolicy.controller].contains(URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL.resolvingSymlinksInPath()) else {
            throw CredentialAccessFailure.untrustedInstallation
        }
        var current: SecCode?
        guard SecCodeCopySelf([], &current) == errSecSuccess, let current else { throw CredentialAccessFailure.untrustedInstallation }
        var currentStatic: SecStaticCode?
        guard SecCodeCopyStaticCode(current, [], &currentStatic) == errSecSuccess, let currentStatic else { throw CredentialAccessFailure.untrustedInstallation }
        var information: CFDictionary?
        guard SecCodeCopySigningInformation(currentStatic, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess,
              let values = information as? [String: Any],
              let team = values[kSecCodeInfoTeamIdentifier as String] as? String,
              let identifier = values[kSecCodeInfoIdentifier as String] as? String,
              ["ai.nightr.app", "ai.nightr.controller"].contains(identifier) else {
            throw CredentialAccessFailure.untrustedInstallation
        }
        guard team.range(of: "^[A-Z0-9]{10}$", options: .regularExpression) != nil else { throw CredentialAccessFailure.untrustedInstallation }
        let currentExpression = "anchor apple generic and certificate leaf[subject.OU] = \"\(team)\" and identifier \"\(identifier)\""
        var currentRequirement: SecRequirement?
        guard SecRequirementCreateWithString(currentExpression as CFString, [], &currentRequirement) == errSecSuccess,
              SecCodeCheckValidity(current, [], currentRequirement) == errSecSuccess else { throw CredentialAccessFailure.untrustedInstallation }
        let paths = try CredentialAccessPolicy.trustedPrograms(teamID: team) { url in
            guard url.standardizedFileURL.resolvingSymlinksInPath() == url else { throw CredentialAccessFailure.invalidTrustedApplication }
            let identifier = url == CredentialAccessPolicy.application ? "ai.nightr.app" : (url == CredentialAccessPolicy.worker ? "ai.nightr.networkworker" : "ai.nightr.controller")
            let expression = "anchor apple generic and certificate leaf[subject.OU] = \"\(team)\" and identifier \"\(identifier)\""
            var requirement: SecRequirement?
            guard SecRequirementCreateWithString(expression as CFString, [], &requirement) == errSecSuccess, let requirement else {
                throw CredentialAccessFailure.invalidTrustedApplication
            }
            var code: SecStaticCode?
            guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, let code,
                  SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSStrictValidate | kSecCSCheckAllArchitectures), requirement) == errSecSuccess else {
                throw CredentialAccessFailure.invalidTrustedApplication
            }
            return CredentialProgramSignature(identifier: identifier, teamID: team, validDeveloperID: true)
        }
        var trusted: [SecTrustedApplication] = []
        for path in paths {
            var application: SecTrustedApplication?
            guard SecTrustedApplicationCreateFromPath(path.path, &application) == errSecSuccess, let application else {
                throw CredentialAccessFailure.invalidTrustedApplication
            }
            trusted.append(application)
        }
        // Never pass nil or an empty list: those have special default semantics.
        guard trusted.count == 3 else { throw CredentialAccessFailure.invalidTrustedApplication }
        var access: SecAccess?
        guard SecAccessCreate("Nightr saved hotspot password" as CFString, trusted as CFArray, &access) == errSecSuccess, let access else {
            throw CredentialAccessFailure.invalidTrustedApplication
        }
        return access
    }
}
public struct KeychainFailure: Error, LocalizedError {
    public let status: OSStatus
    public var errorDescription: String? { "Keychain access failed (\(status)). Unlock Keychain or repair access in macOS." }
}
#endif
