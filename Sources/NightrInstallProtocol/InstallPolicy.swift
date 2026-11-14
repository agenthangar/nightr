import Foundation

public struct InstallOwner: Codable, Equatable {
    public let pid: Int32
    public let uid: UInt32
    public init(pid: Int32, uid: UInt32) { self.pid = pid; self.uid = uid }
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
    public let teamID: String
    public var packagePath: String
    public var version: String
    public var phase: String
    public var invocation: String? = nil
    public init(generation: UUID = UUID(), transaction: UUID = UUID(), owner: InstallOwner?, originalVersion: String?, teamID: String, packagePath: String, version: String, phase: String = "pending") {
        schemaVersion = 1; self.generation = generation; self.transaction = transaction; self.owner = owner
        self.originalVersion = originalVersion; self.teamID = teamID; self.packagePath = packagePath; self.version = version; self.phase = phase
    }
}
public enum InstallGuardError: Error, Equatable {
    case invalidRequest, transactionExists, ownerMismatch, liveController, invalidPhase, packageMismatch, incompleteInstallation, unsafeFile, invalidSignature, systemFailure
}
public enum InstallPolicy {
    public static func begin(existing: InstallMarker?, owner: InstallOwner?, request: InstallRequest?, packagePath: String, version: String, teamID: String, originalVersion: String?, controllerExclusive: Bool) throws -> InstallMarker {
        guard controllerExclusive else { throw InstallGuardError.liveController }
        guard validVersion(version), validTeam(teamID), packagePath.hasPrefix("/"), !packagePath.contains("\0") else { throw InstallGuardError.invalidRequest }
        if let owner {
            guard let request, request.schemaVersion == 1, request.owner == owner,
                  request.packagePath == packagePath, request.version == version, request.teamID == teamID else { throw InstallGuardError.ownerMismatch }
            if var marker = existing {
                guard marker.schemaVersion == 1, marker.owner == owner, marker.transaction == request.transaction,
                      marker.teamID == teamID else { throw InstallGuardError.ownerMismatch }
                guard ["pending", "complete"].contains(marker.phase), request.operation == "rollback",
                      marker.originalVersion == version, request.originalVersion == marker.originalVersion else { throw InstallGuardError.invalidPhase }
                marker.packagePath = packagePath; marker.version = version; marker.phase = "pending"
                return marker
            }
            guard request.operation == "install", request.originalVersion == originalVersion else { throw InstallGuardError.invalidRequest }
            return InstallMarker(transaction: request.transaction, owner: owner, originalVersion: originalVersion, teamID: teamID, packagePath: packagePath, version: version)
        }
        guard existing == nil else { throw InstallGuardError.transactionExists }
        return InstallMarker(owner: nil, originalVersion: originalVersion, teamID: teamID, packagePath: packagePath, version: version)
    }
    public static func complete(_ marker: InstallMarker, owner: InstallOwner?, request: InstallRequest?, packagePath: String, version: String, teamID: String) throws -> InstallMarker {
        guard marker.schemaVersion == 1, marker.phase == "pending" else { throw InstallGuardError.invalidPhase }
        guard marker.packagePath == packagePath, marker.version == version, marker.teamID == teamID else { throw InstallGuardError.packageMismatch }
        try authenticate(marker, owner: owner, request: request)
        var result = marker; result.phase = "complete"; return result
    }
    public static func finish(_ marker: InstallMarker, owner: InstallOwner?, request: InstallRequest?, transaction: UUID, installedVersion: String, teamID: String) throws {
        guard marker.phase == "complete", marker.owner != nil, marker.transaction == transaction,
              marker.version == installedVersion, marker.teamID == teamID else { throw InstallGuardError.incompleteInstallation }
        try authenticate(marker, owner: owner, request: request)
    }
    public static func repair(_ marker: InstallMarker, installedVersion: String, teamID: String) throws {
        guard marker.schemaVersion == 1, marker.teamID == teamID,
              installedVersion == marker.version || installedVersion == marker.originalVersion else { throw InstallGuardError.incompleteInstallation }
    }
    private static func authenticate(_ marker: InstallMarker, owner: InstallOwner?, request: InstallRequest?) throws {
        guard marker.owner == owner else { throw InstallGuardError.ownerMismatch }
        if let owner {
            guard let request, request.schemaVersion == 1, request.owner == owner, request.transaction == marker.transaction,
                  request.version == marker.version, request.packagePath == marker.packagePath,
                  request.teamID == marker.teamID else { throw InstallGuardError.ownerMismatch }
        }
    }
    public static func validVersion(_ value: String) -> Bool { value.range(of: "^0\\.[0-9]+\\.[0-9]+$", options: .regularExpression) != nil }
    public static func validTeam(_ value: String) -> Bool { value.range(of: "^[A-Z0-9]{10}$", options: .regularExpression) != nil }
}
