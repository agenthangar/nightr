import Foundation
import NightrCore
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

enum StateJournal {
    static func load(directory: URL) throws -> ControllerState {
        let url = directory.appendingPathComponent("state.json")
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        if fd < 0 && errno == ENOENT { return ControllerState() }
        guard fd >= 0 else { throw IPCError.invalid("cannot open controller state") }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_uid == getuid(), (info.st_mode & S_IFMT) == S_IFREG,
              info.st_nlink == 1, (info.st_mode & 0o777) == 0o600, info.st_size >= 0, info.st_size <= 65_536 else { throw IPCError.invalid("unsafe controller state") }
        var data = Data(); var bytes = [UInt8](repeating: 0, count: 4096)
        while true {
            let size = read(fd, &bytes, bytes.count)
            if size < 0 && errno == EINTR { continue }
            guard size >= 0 else { throw IPCError.invalid("cannot read controller state") }
            if size == 0 { break }
            data.append(contentsOf: bytes.prefix(size))
            guard data.count <= 65_536 else { throw IPCError.invalid("controller state exceeds limit") }
        }
        let state = try JSONDecoder().decode(ControllerState.self, from: data)
        guard state.schemaVersion == 1 else { throw IPCError.invalid("incompatible controller state version") }
        guard (0...4).contains(state.crashRestarts), (0...10).contains(state.conditionRetries), state.agentSamples >= 0 else {
            throw IPCError.invalid("invalid controller recovery counters")
        }
        if let outage = state.outage {
            guard (1...10).contains(outage.capturedLimit), (0...outage.capturedLimit).contains(outage.consumed) else {
                throw IPCError.invalid("invalid captured hotspot attempt budget")
            }
        }
        return state
    }
    static func save(_ state: ControllerState, directory: URL) throws {
        let url = directory.appendingPathComponent("state.json")
        let temporary = directory.appendingPathComponent(".state-\(UUID().uuidString)")
        let fd = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw IPCError.invalid("cannot create private state journal") }
        defer { close(fd); unlink(temporary.path) }
        let bytes = try JSONEncoder().encode(state)
        try bytes.withUnsafeBytes { buffer in
            var offset = 0
            while offset < bytes.count {
                let size = write(fd, buffer.baseAddress!.advanced(by: offset), bytes.count - offset)
                if size < 0 && errno == EINTR { continue }
                guard size > 0 else { throw IPCError.invalid("cannot write state journal") }; offset += size
            }
        }
        guard fsync(fd) == 0, rename(temporary.path, url.path) == 0 else { throw IPCError.invalid("cannot commit state journal") }
        let dirFD = open(directory.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        if dirFD >= 0 { defer { close(dirFD) }; guard fsync(dirFD) == 0 || errno == EINVAL else { throw IPCError.invalid("cannot sync state directory") } }
    }
}
public enum OfflineController {
    /// Only succeeds after obtaining the same lifetime ownership lock as the live service.
    public static func stop(runtimeDirectory: URL = NightrPaths.runtime) throws {
        let ownership = try RuntimeOwnership(directory: runtimeDirectory, globalLockDirectory: nil)
        try withExtendedLifetime(ownership) {
            var state = try StateJournal.load(directory: runtimeDirectory)
            state.desiredEnabled = false; state.pause = .stopped; state.uncleanShutdown = false
            try StateJournal.save(state, directory: runtimeDirectory)
        }
    }
    public static func assertQuiescent(runtimeDirectory: URL = NightrPaths.runtime) throws {
        let ownership = try RuntimeOwnership(directory: runtimeDirectory, globalLockDirectory: nil)
        withExtendedLifetime(ownership) {}
    }
}
