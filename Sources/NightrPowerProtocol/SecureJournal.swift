import Foundation
#if os(macOS)
import Darwin

struct JournalFailure: Error { let operation: String }
/// Every operation is relative to a verified root-owned directory descriptor.
/// No caller can select a filename or journal path in the production executable.
public final class SecureJournal: JournalStore {
    private let directory: Int32
    private let name = "lease.json"
    private let expectedOwner: uid_t
    public init(directoryPath path: String = "/var/db/ai.nightr.powerhelper", expectedOwner: uid_t = 0) throws {
        self.expectedOwner = expectedOwner
        if mkdir(path, 0o700) != 0 && errno != EEXIST { throw JournalFailure(operation: "mkdir") }
        directory = open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard directory >= 0 else { throw JournalFailure(operation: "open directory") }
        var s = stat()
        guard fstat(directory, &s) == 0, s.st_uid == expectedOwner, (s.st_mode & 0o7777) == 0o700,
              (s.st_mode & S_IFMT) == S_IFDIR else { close(directory); throw JournalFailure(operation: "unsafe directory") }
    }
    deinit { close(directory) }
    public func lock() throws -> Int32 {
        let fd = openat(directory, "lock", O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
        var s = stat()
        guard fd >= 0, fstat(fd, &s) == 0, s.st_uid == expectedOwner,
              (s.st_mode & 0o7777) == 0o600, (s.st_mode & S_IFMT) == S_IFREG,
              s.st_nlink == 1, flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            if fd >= 0 { close(fd) }; throw JournalFailure(operation: "global lock")
        }
        return fd // Held for the daemon lifetime.
    }
    public func load() throws -> PowerJournal? {
        let fd = openat(directory, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        if fd < 0 && errno == ENOENT { return nil }
        guard fd >= 0 else { throw JournalFailure(operation: "open journal") }
        defer { close(fd) }
        var s = stat()
        guard fstat(fd, &s) == 0, s.st_uid == expectedOwner, (s.st_mode & 0o7777) == 0o600,
              (s.st_mode & S_IFMT) == S_IFREG, s.st_nlink == 1, s.st_size > 0, s.st_size <= 4096
        else { throw JournalFailure(operation: "unsafe journal") }
        var bytes = [UInt8](repeating: 0, count: Int(s.st_size))
        let size = bytes.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
        guard size == bytes.count else { throw JournalFailure(operation: "read journal") }
        return try JSONDecoder().decode(PowerJournal.self, from: Data(bytes))
    }
    public func save(_ journal: PowerJournal) throws {
        // Validate any existing record, including links, before replacing it.
        _ = try load()
        let temporary = ".lease-" + UUID().uuidString
        let fd = openat(directory, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw JournalFailure(operation: "create journal") }
        defer { close(fd); unlinkat(directory, temporary, 0) }
        let data = try JSONEncoder().encode(journal)
        let written = data.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
        guard written == data.count, fsync(fd) == 0,
              renameat(directory, temporary, directory, name) == 0, fsync(directory) == 0
        else { throw JournalFailure(operation: "persist journal") }
    }
    public func clear() throws {
        _ = try load()
        guard unlinkat(directory, name, 0) == 0 || errno == ENOENT, fsync(directory) == 0
        else { throw JournalFailure(operation: "clear journal") }
    }
}

#endif
