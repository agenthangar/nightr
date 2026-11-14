import Foundation
import NightrPowerProtocol

public enum SigningPolicy {
    public static func requirement(teamID: String, identifiers: [String]) throws -> String {
        guard teamID.range(of: "^[A-Z0-9]{10}$", options: .regularExpression) != nil,
              !identifiers.isEmpty, identifiers.allSatisfy({ $0.range(of: "^[A-Za-z0-9.-]+$", options: .regularExpression) != nil }) else { throw PowerError.invalidJournal }
        let names = identifiers.map { "identifier \"\($0)\"" }.joined(separator: " or ")
        return "anchor apple generic and certificate leaf[subject.OU] = \"\(teamID)\" and (\(names))"
    }
}
final class BoundedReply<T> {
    private let lock = NSLock()
    private var completion: ((Result<T, Error>) -> Void)?
    private let onFailure: () -> Void
    init(_ completion: @escaping (Result<T, Error>) -> Void,
         onFailure: @escaping () -> Void,
         schedule: (@escaping () -> Void) -> Void = { callback in DispatchQueue.global().asyncAfter(deadline: .now() + 5, execute: callback) }) {
        self.completion = completion; self.onFailure = onFailure
        schedule { [self] in
            finish(.failure(NSError(domain: "ai.nightr.powerhelper", code: 2, userInfo: [NSLocalizedDescriptionKey: "Power helper timed out"])))
        }
    }
    func finish(_ result: Result<T, Error>) {
        lock.lock(); let callback = completion; completion = nil; lock.unlock()
        guard let callback else { return }
        if case .failure = result { onFailure() }
        callback(result)
    }
}
#if os(macOS)
public final class SignedPowerClient {
    private let connection: NSXPCConnection
    private let stateLock = NSLock()
    private var retired = false
    public init(teamID: String) throws {
        let requirement = try SigningPolicy.requirement(teamID: teamID, identifiers: ["ai.nightr.powerhelper"])
        connection = NSXPCConnection(machServiceName: "ai.nightr.powerhelper", options: .privileged)
        connection.remoteObjectInterface = NSXPCInterface(with: NightrPowerXPC.self)
        connection.setCodeSigningRequirement(requirement)
        connection.resume()
    }
    deinit { connection.invalidate() }
    /// Also call when cancelling an in-flight acquire: its token may not yet
    /// have reached the caller. Root disconnect cleanup owns that exact lease.
    public func invalidate() {
        stateLock.lock(); let wasRetired = retired; retired = true; stateLock.unlock()
        if !wasRetired { connection.invalidate() }
    }
    private func remote(_ failure: @escaping (Error) -> Void) -> NightrPowerXPC? {
        stateLock.lock(); let unavailable = retired; stateLock.unlock()
        if unavailable {
            failure(NSError(domain: "ai.nightr.powerhelper", code: 3, userInfo: [NSLocalizedDescriptionKey: "Power helper connection retired; create a fresh client"]))
            return nil
        }
        return connection.remoteObjectProxyWithErrorHandler(failure) as? NightrPowerXPC
    }
    public func acquire(batteryThreshold: Int, completion: @escaping (Result<PowerReply, Error>) -> Void) {
        let response = BoundedReply(completion, onFailure: { [weak self] in self?.invalidate() })
        remote { response.finish(.failure($0)) }?.acquire(batteryThreshold) { token, error in
            if let token { response.finish(.success(PowerReply(active: true, restorationBlocked: false, lease: token))) }
            else { response.finish(.failure(NSError(domain: "ai.nightr.powerhelper", code: 1, userInfo: [NSLocalizedDescriptionKey: error ?? "Helper unavailable"]))) }
        }
    }
    public func renew(lease: String, completion: @escaping (Result<PowerReply, Error>) -> Void) {
        let response = BoundedReply(completion, onFailure: { [weak self] in self?.invalidate() })
        remote { response.finish(.failure($0)) }?.renew(lease, threshold: -1) { error in
            if let error { response.finish(.failure(NSError(domain: "ai.nightr.powerhelper", code: 1, userInfo: [NSLocalizedDescriptionKey: error]))) }
            else { response.finish(.success(PowerReply(active: true, restorationBlocked: false, lease: lease))) }
        }
    }
    public func update(lease: String, batteryThreshold: Int, completion: @escaping (Result<PowerReply, Error>) -> Void) {
        let response = BoundedReply(completion, onFailure: { [weak self] in self?.invalidate() })
        remote { response.finish(.failure($0)) }?.renew(lease, threshold: batteryThreshold) { error in
            if let error { response.finish(.failure(NSError(domain: "ai.nightr.powerhelper", code: 1, userInfo: [NSLocalizedDescriptionKey: error]))) }
            else { response.finish(.success(PowerReply(active: true, restorationBlocked: false, lease: lease))) }
        }
    }
    public func release(lease: String, completion: @escaping (Result<PowerReply, Error>) -> Void) {
        let response = BoundedReply(completion, onFailure: { [weak self] in self?.invalidate() })
        remote { response.finish(.failure($0)) }?.release(lease) { error in
            if let error { response.finish(.failure(NSError(domain: "ai.nightr.powerhelper", code: 1, userInfo: [NSLocalizedDescriptionKey: error]))) }
            else { response.finish(.success(PowerReply(active: false, restorationBlocked: false))) }
        }
    }
    public func status(completion: @escaping (Result<PowerReply, Error>) -> Void) {
        let response = BoundedReply(completion, onFailure: { [weak self] in self?.invalidate() })
        remote { response.finish(.failure($0)) }?.status { json in
            do { response.finish(.success(try JSONDecoder().decode(PowerReply.self, from: Data(json.utf8)))) }
            catch { response.finish(.failure(error)) }
        }
    }
}
#endif
