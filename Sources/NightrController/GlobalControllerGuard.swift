import Foundation
import NightrCore
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

@_silgen_name("flock") private func globalFlock(_ fd: Int32, _ operation: Int32) -> Int32

/// The privileged package creates these fixed, content-free lock files.
/// Controllers never create, repair or chmod system-owned installation files.
final class GlobalControllerGuard {
    // POSIX record locks are process-owned. Serializing startup also prevents a
    // second startup from opening/closing update.lock while our record is held.
    private static let startupGate = NSLock()
    private var controllerFD: Int32 = -1
    init(directory: URL, expectedUID: uid_t = 0,
         markerCheck: (URL) throws -> Void = GlobalControllerGuard.requireNoTransaction) throws {
        Self.startupGate.lock()
        defer { Self.startupGate.unlock() }
        var info = stat()
        guard lstat(directory.path, &info) == 0, info.st_uid == expectedUID,
              (info.st_mode & S_IFMT) == S_IFDIR, (info.st_mode & 0o777) == 0o755 else {
            throw IPCError.invalid("Nightr installation update guards need repair; run setup")
        }
        let marker = directory.appendingPathComponent("install-transaction.json")
        try markerCheck(marker)
        func openLock(_ name: String) throws -> Int32 {
            let fd = open(directory.appendingPathComponent(name).path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
            guard fd >= 0 else { throw IPCError.invalid("Nightr installation update guards are missing; repair the package") }
            // Validate this exact descriptor: opening and closing another descriptor
            // for the same inode would release all this process's POSIX locks.
            guard fstat(fd, &info) == 0, info.st_uid == expectedUID, (info.st_mode & S_IFMT) == S_IFREG,
                  info.st_nlink == 1, (info.st_mode & 0o777) == 0o666 else {
                close(fd); throw IPCError.invalid("unsafe Nightr installation update guard")
            }
            return fd
        }
        let updateFD = try openLock("update.lock")
        defer {
            var unlock = Self.record(type: Int16(F_UNLCK))
            _ = fcntl(updateFD, F_SETLK, &unlock)
            close(updateFD)
        }
        var shared = Self.record(type: Int16(F_RDLCK))
        guard fcntl(updateFD, F_SETLK, &shared) == 0 else {
            throw IPCError.invalid("Nightr is being updated; retry after the update finishes")
        }
        let controller = try openLock("controller.lock")
        var retained = false
        defer { if !retained { _ = globalFlock(controller, LOCK_UN); close(controller) } }
        guard globalFlock(controller, LOCK_SH | LOCK_NB) == 0 else {
            throw IPCError.invalid("Nightr is being updated; retry after the update finishes")
        }
        // A late preinstall marker must also block startup. Existence, malformed
        // content and lookup failures all require explicit trusted repair.
        try markerCheck(marker)
        controllerFD = controller
        retained = true
    }
    static func requireNoTransaction(_ marker: URL) throws {
        var info = stat()
        if lstat(marker.path, &info) == -1 && errno == ENOENT { return }
        throw IPCError.invalid("Nightr installation is incomplete or being updated; finish or repair the installation")
    }
    private static func record(type: Int16) -> flock {
        var lock = flock()
        lock.l_type = type
        lock.l_whence = Int16(SEEK_SET)
        lock.l_start = 0
        lock.l_len = 0 // Whole file, including future writes.
        return lock
    }
    deinit { if controllerFD >= 0 { _ = globalFlock(controllerFD, LOCK_UN); close(controllerFD) } }
}
