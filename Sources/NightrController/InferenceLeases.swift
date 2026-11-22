import Foundation
import NightrCore

/// Obtained from authenticated Unix peer credentials, never request JSON.
public struct ControllerPeer: Equatable, Sendable {
    public let uid: UInt32
    public let pid: Int32
    public init(uid: UInt32, pid: Int32) { self.uid = uid; self.pid = pid }
}

struct InferenceLeases {
    static let lifetime: TimeInterval = 15
    static let maximum = 32
    struct Lease { var observationID: String = UUID().uuidString; var owner: ControllerPeer; var metadata: InferenceMetadata; var beganUptime: TimeInterval; var deadline: TimeInterval }
    private(set) var leases: [UUID: Lease] = [:]
    mutating func clear() { leases.removeAll() }
    mutating func prune(at uptime: TimeInterval) { leases = leases.filter { $0.value.deadline > uptime } }
    mutating func begin(_ metadata: InferenceMetadata, peer: ControllerPeer, uptime: TimeInterval) throws -> UUID {
        try metadata.validate(); prune(at: uptime)
        guard peer.pid > 0, leases.count < Self.maximum else { throw IPCError.invalid("inference producer limit reached or caller process unavailable") }
        let token = UUID(); leases[token] = Lease(owner: peer, metadata: metadata, beganUptime: uptime, deadline: uptime + Self.lifetime); return token
    }
    mutating func heartbeat(_ token: UUID, peer: ControllerPeer, uptime: TimeInterval) throws {
        prune(at: uptime)
        guard var lease = leases[token], lease.owner == peer else { throw IPCError.invalid("inference token expired or belongs to another caller") }
        lease.deadline = uptime + Self.lifetime; leases[token] = lease
    }
    mutating func end(_ token: UUID, peer: ControllerPeer, uptime: TimeInterval) throws {
        prune(at: uptime)
        guard leases[token]?.owner == peer else { throw IPCError.invalid("inference token expired or belongs to another caller") }
        leases[token] = nil
    }
    mutating func adding(to observation: ActivityObservation?, now: Date, uptime: TimeInterval) -> ActivityObservation? {
        prune(at: uptime)
        guard !leases.isEmpty else { return observation }
        var result = observation ?? ActivityObservation()
        for (_, lease) in leases.sorted(by: { $0.key.uuidString < $1.key.uuidString }) {
            let model = LocalModelObservation(id: "integration:" + lease.observationID, name: lease.metadata.model,
                activity: lease.metadata.activity, startedAt: now.addingTimeInterval(-(uptime - lease.beganUptime)), inferenceExpiresAt: now.addingTimeInterval(lease.deadline - uptime))
            result.runtimes.append(RuntimeObservation(runtime: lease.metadata.runtime, observedAt: now, models: [model]))
        }
        return result
    }
}
