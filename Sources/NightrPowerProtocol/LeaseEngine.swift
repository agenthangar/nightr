import Foundation

public struct LeaseIdentity: Equatable {
    public let uid: UInt32
    public let connection: UUID
    public let generation: UUID
    public init(uid: UInt32, connection: UUID, generation: UUID = UUID()) {
        self.uid = uid; self.connection = connection; self.generation = generation
    }
}
public struct PowerJournal: Codable, Equatable {
    public let generation: UUID
    public let original: Int
    public var phase: String
    public init(generation: UUID, original: Int = 0, phase: String = "pending") {
        self.generation = generation; self.original = original; self.phase = phase
    }
}
public protocol PowerBackend {
    func readDisabledSleep() throws -> Int
    func setDisabledSleep(_ disabled: Bool) throws
    func batteryIsSafe(threshold: Int) throws -> Bool
}
public protocol JournalStore {
    func load() throws -> PowerJournal?
    func save(_ journal: PowerJournal) throws
    func clear() throws
}
public enum PowerError: Error, Equatable {
    case busy, preexistingHold, staleLease, unsafeBattery, externalChange, restoreFailed, invalidThreshold, invalidJournal
}
/// Single global engine, serialized by the root helper. This does not establish
/// exclusive OS ownership: other utilities must not write disablesleep while held.
public final class PowerLeaseEngine {
    public static let leaseDuration: TimeInterval = 30
    private let backend: PowerBackend
    private let journal: JournalStore
    private let now: () -> TimeInterval
    private var lease: LeaseIdentity?
    private var deadline: TimeInterval = 0
    private var threshold = 20
    private var blocked = false
    private var restorationPending = false
    public init(backend: PowerBackend, journal: JournalStore, now: @escaping () -> TimeInterval) {
        self.backend = backend; self.journal = journal; self.now = now
    }
    /// Must succeed before accepting any connection. Pending covers a crash
    /// between journal persistence, mutation and verified active persistence.
    public func recover() throws {
        if let record = try journal.load() {
            guard record.original == 0, ["pending", "active"].contains(record.phase) else { blocked = true; throw PowerError.invalidJournal }
            restorationPending = true
            try finishRestoration()
        }
        blocked = false
    }
    public func acquire(uid: UInt32, connection: UUID, batteryThreshold: Int) throws -> LeaseIdentity {
        try tick()
        guard !blocked else { throw PowerError.restoreFailed }
        guard lease == nil else { throw PowerError.busy }
        guard (0...100).contains(batteryThreshold) else { throw PowerError.invalidThreshold }
        guard try backend.batteryIsSafe(threshold: batteryThreshold) else { throw PowerError.unsafeBattery }
        guard try backend.readDisabledSleep() == 0 else { throw PowerError.preexistingHold }
        let token = LeaseIdentity(uid: uid, connection: connection)
        // Never mutate before a durable pending original=0 record.
        try journal.save(PowerJournal(generation: token.generation))
        do {
            try backend.setDisabledSleep(true)
            guard try backend.readDisabledSleep() == 1 else { throw PowerError.externalChange }
            try journal.save(PowerJournal(generation: token.generation, phase: "active"))
        } catch {
            restorationPending = true
            try finishRestoration()
            throw error
        }
        lease = token; threshold = batteryThreshold; deadline = now() + Self.leaseDuration
        return token
    }
    public func renew(_ token: LeaseIdentity, batteryThreshold: Int? = nil) throws {
        try tick()
        guard lease == token else { throw PowerError.staleLease }
        if let updated = batteryThreshold {
            guard (0...100).contains(updated) else { throw PowerError.invalidThreshold }
            let safe: Bool
            do { safe = try backend.batteryIsSafe(threshold: updated) }
            catch { try endLease(); throw error }
            if !safe { try endLease(); throw PowerError.unsafeBattery }
            threshold = updated
        }
        deadline = now() + Self.leaseDuration
    }
    public func release(_ token: LeaseIdentity) throws {
        guard lease == token else { throw PowerError.staleLease }
        try endLease()
    }
    public func disconnected(_ connection: UUID) throws {
        if let token = lease, token.connection == connection { try release(token) }
    }
    public func tick() throws {
        // Cleanup retries survive invalidated leases. An invalid journal alone
        // never authorizes restoration; only a validated acquisition/recovery does.
        if restorationPending { try finishRestoration(); return }
        guard lease != nil else { return }
        // Expiry is independent of successful power or battery observations.
        if now() >= deadline { try endLease(); return }
        let disabled: Int
        let batterySafe: Bool
        do {
            disabled = try backend.readDisabledSleep()
            batterySafe = try backend.batteryIsSafe(threshold: threshold)
        } catch { try endLease(); throw error }
        if disabled == 0 {
            lease = nil
            do { try journal.clear() } catch { blocked = true; throw error }
            throw PowerError.externalChange
        }
        if !batterySafe { try endLease() }
    }
    private func endLease() throws {
        lease = nil; restorationPending = true
        try finishRestoration()
    }
    private func finishRestoration() throws {
        do {
            try restore()
            restorationPending = false; blocked = false
        } catch { blocked = true; throw PowerError.restoreFailed }
    }
    public var activeLease: LeaseIdentity? { lease }
    public var restorationBlocked: Bool { blocked }
    private func restore() throws {
        // Under our recorded exclusive-writer contract a failed read must not
        // prevent attempting to undo the hold. Verification still must succeed.
        if (try? backend.readDisabledSleep()) != 0 { try backend.setDisabledSleep(false) }
        guard try backend.readDisabledSleep() == 0 else { throw PowerError.restoreFailed }
        try journal.clear()
    }
}
