import Foundation

public struct InstallOwner: Codable, Equatable {
    public let pid: Int32
    public let uid: UInt32
    public let processStartSeconds: UInt64
    public let processStartMicroseconds: UInt64
    public let bootID: String
    public init(pid: Int32, uid: UInt32, processStartSeconds: UInt64, processStartMicroseconds: UInt64, bootID: String) {
        self.pid = pid; self.uid = uid; self.processStartSeconds = processStartSeconds
        self.processStartMicroseconds = processStartMicroseconds; self.bootID = bootID
    }
}
public struct InstallRequest: Codable, Equatable {
    public let schemaVersion: Int
    public let transaction: UUID
    public let owner: InstallOwner
    public let packagePath: String
    public let version: String
    public let originalVersion: String?
    public let teamID: String
    public let operation: String
    public init(transaction: UUID, owner: InstallOwner, packagePath: String, version: String, originalVersion: String?, teamID: String, operation: String = "install") {
        schemaVersion = 1; self.transaction = transaction; self.owner = owner; self.packagePath = packagePath
        self.version = version; self.originalVersion = originalVersion; self.teamID = teamID; self.operation = operation
    }
}
public struct InstallMarker: Codable, Equatable {
    public let schemaVersion: Int
    public let generation: UUID
    public let transaction: UUID
    public let owner: InstallOwner?
    public let originalVersion: String?
    public let newVersion: String
    public let teamID: String
    public var packagePath: String
    public var version: String
    public var phase: String
    public var invocation: String
    public let bootID: String
    public init(generation: UUID = UUID(), transaction: UUID = UUID(), owner: InstallOwner?, originalVersion: String?, teamID: String, packagePath: String, version: String, phase: String = "pending", bootID: String, invocation: String, newVersion: String? = nil) {
        schemaVersion = 1; self.generation = generation; self.transaction = transaction; self.owner = owner
        self.originalVersion = originalVersion; self.teamID = teamID; self.packagePath = packagePath
        self.version = version; self.phase = phase; self.bootID = bootID; self.invocation = invocation; self.newVersion = newVersion ?? version
    }
}
public enum InstallGuardError: Error, Equatable {
    case invalidRequest, invalidMarker, transactionExists, ownerMismatch, liveController, invalidPhase, packageMismatch, incompleteInstallation, unsafeFile, invalidSignature, systemFailure, unrelatedCommand
}
public enum InstallPolicy {
    public static func validateOwner(_ owner: InstallOwner) throws {
        guard owner.pid > 0, owner.processStartSeconds > 0, owner.processStartMicroseconds < 1_000_000,
              validBoot(owner.bootID) else { throw InstallGuardError.ownerMismatch }
    }
    public static func validateRequest(_ request: InstallRequest) throws {
        try validateOwner(request.owner)
        guard request.schemaVersion == 1, validPackagePath(request.packagePath), validVersion(request.version),
              request.originalVersion.map(validVersion) ?? true, validTeam(request.teamID),
              ["install", "rollback"].contains(request.operation) else { throw InstallGuardError.invalidRequest }
    }
    public static func validateMarker(_ marker: InstallMarker) throws {
        guard marker.schemaVersion == 1, validBoot(marker.bootID), ["pending", "complete"].contains(marker.phase),
              validTeam(marker.teamID), validVersion(marker.version), validVersion(marker.newVersion),
              marker.originalVersion.map(validVersion) ?? true, validPackagePath(marker.packagePath),
              validInvocation(marker.invocation),
              marker.version == marker.newVersion || marker.version == marker.originalVersion else { throw InstallGuardError.invalidMarker }
        if let owner = marker.owner {
            try validateOwner(owner)
            guard owner.bootID == marker.bootID else { throw InstallGuardError.invalidMarker }
        }
    }
    public static func begin(existing: InstallMarker?, owner: InstallOwner?, request: InstallRequest?, packagePath: String, version: String, teamID: String, originalVersion: String?, controllerExclusive: Bool, bootID: String, invocation: String) throws -> InstallMarker {
        if let marker = existing { try validateMarker(marker) }
        guard controllerExclusive else { throw InstallGuardError.liveController }
        guard validVersion(version), validTeam(teamID), validPackagePath(packagePath), validBoot(bootID),
              (originalVersion.map(validVersion) ?? true), validInvocation(invocation) else { throw InstallGuardError.invalidRequest }
        if let marker = existing, marker.bootID != bootID {
            guard owner == nil, marker.teamID == teamID,
                  version == marker.newVersion || version == marker.originalVersion else { throw InstallGuardError.invalidPhase }
            return InstallMarker(generation: marker.generation, transaction: marker.transaction, owner: nil, originalVersion: marker.originalVersion, teamID: teamID, packagePath: packagePath, version: version, bootID: bootID, invocation: invocation, newVersion: marker.newVersion)
        }
        if let owner {
            try validateOwner(owner)
            guard owner.bootID == bootID, let request else { throw InstallGuardError.ownerMismatch }
            try validateRequest(request)
            guard request.owner == owner, request.packagePath == packagePath, request.version == version,
                  request.teamID == teamID else { throw InstallGuardError.ownerMismatch }
            if var marker = existing {
                guard marker.owner == owner, marker.transaction == request.transaction, marker.teamID == teamID else { throw InstallGuardError.ownerMismatch }
                guard marker.phase == "complete", request.operation == "rollback", marker.originalVersion == version,
                      request.originalVersion == marker.originalVersion else { throw InstallGuardError.invalidPhase }
                marker.packagePath = packagePath; marker.version = version; marker.phase = "pending"; marker.invocation = invocation
                return marker
            }
            guard request.operation == "install", request.originalVersion == originalVersion else { throw InstallGuardError.invalidRequest }
            return InstallMarker(transaction: request.transaction, owner: owner, originalVersion: originalVersion, teamID: teamID, packagePath: packagePath, version: version, bootID: bootID, invocation: invocation)
        }
        guard existing == nil else { throw InstallGuardError.transactionExists }
        return InstallMarker(owner: nil, originalVersion: originalVersion, teamID: teamID, packagePath: packagePath, version: version, bootID: bootID, invocation: invocation)
    }
    public static func authorizePublishedBegin(_ marker: InstallMarker, observedOwner: InstallOwner?, controllerExclusive: Bool) throws {
        try validateMarker(marker)
        guard marker.phase == "pending", marker.owner == observedOwner else { throw InstallGuardError.ownerMismatch }
        guard controllerExclusive else { throw InstallGuardError.liveController }
    }
    public static func complete(_ marker: InstallMarker, owner: InstallOwner?, request: InstallRequest?, packagePath: String, version: String, teamID: String) throws -> InstallMarker {
        try validateMarker(marker)
        guard marker.phase == "pending" else { throw InstallGuardError.invalidPhase }
        guard marker.packagePath == packagePath, marker.version == version, marker.teamID == teamID else { throw InstallGuardError.packageMismatch }
        try authenticate(marker, owner: owner, request: request)
        var result = marker; result.phase = "complete"; return result
    }
    public static func finish(_ marker: InstallMarker, owner: InstallOwner?, request: InstallRequest?, transaction: UUID, installedVersion: String, teamID: String) throws {
        try validateMarker(marker)
        guard marker.phase == "complete", marker.owner != nil, marker.transaction == transaction,
              marker.version == installedVersion, marker.teamID == teamID else { throw InstallGuardError.incompleteInstallation }
        try authenticate(marker, owner: owner, request: request)
    }
    public static func rollbackReady(_ marker: InstallMarker, owner: InstallOwner?, request: InstallRequest?, transaction: UUID) throws {
        try validateMarker(marker)
        guard marker.phase == "complete", marker.owner != nil, marker.transaction == transaction else { throw InstallGuardError.invalidPhase }
        try authenticate(marker, owner: owner, request: request)
    }
    public static func repair(_ marker: InstallMarker, installedVersion: String, teamID: String, currentBootID: String) throws {
        try validateMarker(marker)
        guard validBoot(currentBootID), marker.bootID != currentBootID else { throw InstallGuardError.invalidPhase }
        guard marker.teamID == teamID, installedVersion == marker.newVersion || installedVersion == marker.originalVersion else { throw InstallGuardError.incompleteInstallation }
    }
    private static func authenticate(_ marker: InstallMarker, owner: InstallOwner?, request: InstallRequest?) throws {
        guard marker.owner == owner else { throw InstallGuardError.ownerMismatch }
        if let owner {
            guard let request else { throw InstallGuardError.ownerMismatch }
            try validateRequest(request)
            guard request.owner == owner, request.transaction == marker.transaction, request.version == marker.version,
                  request.originalVersion == marker.originalVersion, request.packagePath == marker.packagePath,
                  request.teamID == marker.teamID else { throw InstallGuardError.ownerMismatch }
        }
    }
    public static func verifyInvocation(_ marker: InstallMarker, identity: String?) throws {
        try validateMarker(marker)
        guard let identity, marker.invocation == identity else { throw InstallGuardError.packageMismatch }
    }
    public static func validInvocation(_ value: String) -> Bool {
        let fields = value.split(separator: ":", omittingEmptySubsequences: false)
        return value.hasPrefix("/") && !value.contains("\0") && value.utf8.count <= 8192 && fields.count == 5 && fields.dropFirst().allSatisfy { UInt64($0) != nil }
    }
    public static func validBoot(_ value: String) -> Bool { UUID(uuidString: value)?.uuidString == value }
    public static func validPackagePath(_ value: String) -> Bool { value.hasPrefix("/") && !value.contains("\0") && value.utf8.count <= 4096 && URL(fileURLWithPath: value).standardizedFileURL.path == value }
    public static func validVersion(_ value: String) -> Bool { value.range(of: "^0\\.[0-9]+\\.[0-9]+$", options: .regularExpression) != nil }
    public static func validTeam(_ value: String) -> Bool { value.range(of: "^[A-Z0-9]{10}$", options: .regularExpression) != nil }
}
