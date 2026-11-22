import Foundation
import NightrCore
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

@_silgen_name("flock") private func advisoryLock(_ fd: Int32, _ operation: Int32) -> Int32

private func systemError(_ operation: String) -> IPCError { .invalid("\(operation): \(String(cString: strerror(errno)))") }

public final class RuntimeOwnership: @unchecked Sendable {
    public let directory: URL
    private var lockFD: Int32 = -1
    private let globalGuard: GlobalControllerGuard?
    public init(directory: URL, globalLockDirectory: URL? = NightrPaths.globalLocks) throws {
        self.directory = directory
        globalGuard = try globalLockDirectory.map { try GlobalControllerGuard(directory: $0) }
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var info = stat()
        guard lstat(directory.path, &info) == 0, info.st_uid == getuid(), (info.st_mode & S_IFMT) == S_IFDIR,
              (info.st_mode & 0o777) == 0o700 else { throw IPCError.invalid("runtime directory must be an owned private 0700 directory") }
        let path = directory.appendingPathComponent("controller.lock").path
        lockFD = open(path, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard lockFD >= 0 else { throw systemError("open controller lock") }
        guard fstat(lockFD, &info) == 0, info.st_uid == getuid(), (info.st_mode & S_IFMT) == S_IFREG,
              info.st_nlink == 1, (info.st_mode & 0o777) == 0o600 else { close(lockFD); lockFD = -1; throw IPCError.invalid("unsafe controller lock") }
        guard advisoryLock(lockFD, LOCK_EX | LOCK_NB) == 0 else {
            let code = errno; close(lockFD); lockFD = -1
            if code == EWOULDBLOCK || code == EAGAIN { throw RuntimeOwnershipBusyError() }
            throw IPCError.invalid("cannot acquire controller ownership lock")
        }
    }
    deinit { if lockFD >= 0 { _ = advisoryLock(lockFD, LOCK_UN); close(lockFD) } }
}

private func address(_ path: String) throws -> sockaddr_un {
    var addr = sockaddr_un(); addr.sun_family = sa_family_t(AF_UNIX)
    let bytes = Array(path.utf8) + [0]
    guard bytes.count <= MemoryLayout.size(ofValue: addr.sun_path) else { throw IPCError.invalid("runtime socket path is too long") }
    withUnsafeMutableBytes(of: &addr.sun_path) { $0.copyBytes(from: bytes) }
    return addr
}
private func makeSocket() -> Int32 {
#if canImport(Darwin)
    return socket(AF_UNIX, SOCK_STREAM, 0)
#else
    return socket(AF_UNIX, Int32(SOCK_STREAM.rawValue), 0)
#endif
}
private struct PeerCredentials { var pid: Int32 = 0; var uid: UInt32 = 0; var gid: UInt32 = 0 }
@discardableResult private func verifyPeer(_ fd: Int32) throws -> ControllerPeer {
#if canImport(Darwin)
    var uid: uid_t = 0; var gid: gid_t = 0
    guard getpeereid(fd, &uid, &gid) == 0, uid == getuid() else { throw IPCError.invalid("controller peer has a different user identity") }
    var pid: Int32 = 0; var length = socklen_t(MemoryLayout<Int32>.size)
    guard getsockopt(fd, SOL_LOCAL, LOCAL_PEERPID, &pid, &length) == 0 else { throw IPCError.invalid("controller peer process unavailable") }
    return ControllerPeer(uid: uid, pid: pid)
#else
    var cred = PeerCredentials(); var length = socklen_t(MemoryLayout<PeerCredentials>.size)
    guard getsockopt(fd, SOL_SOCKET, SO_PEERCRED, &cred, &length) == 0, cred.uid == getuid() else { throw IPCError.invalid("controller peer has a different user identity") }
    return ControllerPeer(uid: cred.uid, pid: cred.pid)
#endif
}
private func configure(_ fd: Int32) {
    var timeout = timeval(tv_sec: 2, tv_usec: 0)
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
#if canImport(Darwin)
    var on: Int32 = 1; setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
#endif
    _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
}
private func receiveExactly(_ fd: Int32, count: Int) throws -> Data {
    let deadline = Date().addingTimeInterval(2)
    var bytes = [UInt8](repeating: 0, count: count); var offset = 0
    while offset < count {
        guard Date() < deadline else { throw IPCError.invalid("controller frame deadline exceeded") }
        let n = bytes.withUnsafeMutableBytes { buffer in recv(fd, buffer.baseAddress!.advanced(by: offset), count - offset, 0) }
        if n < 0 && errno == EINTR { continue }
        guard n > 0 else { throw IPCError.invalid("controller connection ended or timed out") }
        offset += n
    }
    return Data(bytes)
}
private func sendAll(_ fd: Int32, data: Data) throws {
    var offset = 0
    while offset < data.count {
        let n = data.withUnsafeBytes { buffer -> Int in
#if canImport(Darwin)
            return send(fd, buffer.baseAddress!.advanced(by: offset), data.count - offset, 0)
#else
            return send(fd, buffer.baseAddress!.advanced(by: offset), data.count - offset, Int32(MSG_NOSIGNAL))
#endif
        }
        if n < 0 && errno == EINTR { continue }
        guard n > 0 else { throw systemError("send controller frame") }; offset += n
    }
}
public final class ControllerClient: Sendable {
    public let runtimeDirectory: URL
    public init(runtimeDirectory: URL = NightrPaths.runtime) { self.runtimeDirectory = runtimeDirectory }
    public func request(_ request: ControllerRequest) throws -> ControllerResponse {
        var info = stat()
        if lstat(runtimeDirectory.path, &info) != 0 {
            if errno == ENOENT { throw ControllerUnavailableError(message: "private controller runtime is unavailable or unsafe") }
            throw IPCError.invalid("private controller runtime is unavailable or unsafe")
        }
        guard info.st_uid == getuid(), (info.st_mode & S_IFMT) == S_IFDIR,
              (info.st_mode & 0o777) == 0o700 else { throw IPCError.invalid("private controller runtime is unavailable or unsafe") }
        let path = runtimeDirectory.appendingPathComponent("controller.sock").path
        if lstat(path, &info) != 0 {
            if errno == ENOENT { throw ControllerUnavailableError(message: "private controller socket is unavailable or unsafe") }
            throw IPCError.invalid("private controller socket is unavailable or unsafe")
        }
        guard info.st_uid == getuid(), (info.st_mode & S_IFMT) == S_IFSOCK,
              (info.st_mode & 0o777) == 0o600 else { throw IPCError.invalid("private controller socket is unavailable or unsafe") }
        let fd = makeSocket(); guard fd >= 0 else { throw systemError("socket") }; defer { close(fd) }; configure(fd)
        var addr = try address(path)
        let result = withUnsafePointer(to: &addr) { ptr in ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
        if result != 0 {
            if errno == ECONNREFUSED || errno == ENOENT { throw ControllerUnavailableError(message: systemError("connect controller").localizedDescription) }
            throw systemError("connect controller")
        }
        try verifyPeer(fd)
        let frame = try FrameCodec.encode(request)
        do {
            try sendAll(fd, data: frame)
            let count = try FrameCodec.payloadLength(receiveExactly(fd, count: 4))
            let response = try JSONDecoder().decode(ControllerResponse.self, from: receiveExactly(fd, count: count))
            guard response.version == ControllerRequest.version else { throw IPCError.invalid("incompatible controller protocol; update Nightr") }
            return response
        } catch {
            // After sending starts, a lost/invalid reply cannot prove Start failed.
            if request.command == .start { throw ControllerStartUncertainError(message: error.localizedDescription) }
            throw error
        }
    }
}

final class ControllerSocket: @unchecked Sendable {
    private let path: String
    private var listener: Int32 = -1
    private let stateLock = NSLock()
    private var stopped = false
    private let slots = DispatchSemaphore(value: 4)
    init(directory: URL, handler: @escaping @Sendable (ControllerRequest, ControllerPeer) async -> ControllerResponse) throws {
        path = directory.appendingPathComponent("controller.sock").path
        var info = stat()
        if lstat(path, &info) == 0 {
            guard info.st_uid == getuid(), (info.st_mode & S_IFMT) == S_IFSOCK else { throw IPCError.invalid("refusing unsafe stale controller socket") }
            guard unlink(path) == 0 else { throw systemError("remove stale controller socket") }
        } else if errno != ENOENT { throw systemError("inspect controller socket") }
        listener = makeSocket(); guard listener >= 0 else { throw systemError("socket") }
        _ = fcntl(listener, F_SETFD, FD_CLOEXEC)
        var addr = try address(path)
        let result = withUnsafePointer(to: &addr) { ptr in ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(listener, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
        guard result == 0 else { close(listener); listener = -1; throw systemError("bind controller socket") }
        guard chmod(path, 0o600) == 0, listen(listener, 4) == 0 else { close(listener); listener = -1; unlink(path); throw systemError("listen controller socket") }
        let listenFD = listener
        DispatchQueue.global(qos: .utility).async { [weak self] in
            while let self {
                self.stateLock.lock(); let done = self.stopped; self.stateLock.unlock(); if done { return }
                let fd = accept(listenFD, nil, nil)
                if fd < 0 { if errno == EINTR { continue }; return }
                guard self.slots.wait(timeout: .now()) == .success else { close(fd); continue }
                configure(fd)
                DispatchQueue.global(qos: .utility).async {
                    defer { close(fd); self.slots.signal() }
                    do {
                        let peer = try verifyPeer(fd)
                        let count = try FrameCodec.payloadLength(receiveExactly(fd, count: 4))
                        let request = try JSONDecoder().decode(ControllerRequest.self, from: receiveExactly(fd, count: count))
                        guard request.version == ControllerRequest.version else {
                            try sendAll(fd, data: FrameCodec.encode(ControllerResponse(error: "incompatible controller protocol; update Nightr"))); return
                        }
                        let completion = DispatchSemaphore(value: 0)
                        let box = ResponseBox()
                        Task { box.value = await handler(request, peer); completion.signal() }
                        guard completion.wait(timeout: .now() + 5) == .success, let response = box.value else { return }
                        try sendAll(fd, data: FrameCodec.encode(response))
                    } catch { /* Malformed and unauthenticated peers receive no details. */ }
                }
            }
        }
    }
    func stop() {
        stateLock.lock(); defer { stateLock.unlock() }
        if !stopped { stopped = true; if listener >= 0 { shutdown(listener, Int32(SHUT_RDWR)); close(listener); listener = -1 }; unlink(path) }
    }
    deinit { stop() }
}
private final class ResponseBox: @unchecked Sendable { var value: ControllerResponse? }
