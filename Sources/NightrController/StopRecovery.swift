import Foundation
import NightrCore

public struct RuntimeOwnershipBusyError: Error, LocalizedError, Sendable {
    public var errorDescription: String? { "another Nightr controller already owns this user session" }
    public init() {}
}

/// Stop always targets the current endpoint, including a replacement after update.
/// Only endpoint absence permits the offline path, which acquires the owner lock.
public enum StopRecovery {
    public static func stop(runtimeDirectory: URL = NightrPaths.runtime) async throws -> ControllerStatus? {
        try await confirm(send: { try ControllerClient(runtimeDirectory: runtimeDirectory).request(.init(command: .stop)) },
                          offline: { try OfflineController.stop(runtimeDirectory: runtimeDirectory) })
    }
    static func confirm(attempts: Int = 5,
                        send: @Sendable () throws -> ControllerResponse,
                        offline: @Sendable () throws -> Void,
                        pause: @Sendable () async throws -> Void = { try await Task.sleep(nanoseconds: 100_000_000) }) async throws -> ControllerStatus? {
        for attempt in 0..<max(1, attempts) {
            do {
                let response = try send()
                if let error = response.error { throw IPCError.invalid(error) }
                guard let status = response.status, !status.state.desiredEnabled else {
                    throw IPCError.invalid("controller did not confirm durable Stop; protection may resume")
                }
                return status
            } catch is ControllerUnavailableError {
                do { try offline(); return nil }
                catch is RuntimeOwnershipBusyError {
                    guard attempt + 1 < max(1, attempts) else {
                        throw IPCError.invalid("Stop could not be confirmed during controller handoff; run `nightr stop` again")
                    }
                    try await pause()
                }
            }
        }
        throw IPCError.invalid("Stop could not be confirmed")
    }
}
