import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

public struct NDJSONFramer {
    public enum Frame: Equatable { case line(Data), invalid }
    private var buffer = Data()
    private var discarding = false
    public init() {}
    public mutating func append(_ data: Data) -> [Frame] {
        var frames: [Frame] = []
        for byte in data {
            if byte == 10 {
                if !discarding { frames.append(.line(buffer)) }
                buffer.removeAll(keepingCapacity: true); discarding = false
            } else if !discarding {
                if buffer.count == MCPConnection.maximumFrameBytes {
                    buffer.removeAll(keepingCapacity: true); discarding = true; frames.append(.invalid)
                } else { buffer.append(byte) }
            }
        }
        return frames
    }
    public mutating func finish() -> [Frame] {
        defer { buffer.removeAll(); discarding = false }
        return !buffer.isEmpty && !discarding ? [.invalid] : []
    }
}

/// Writes on one serialized connection actor; a blocked reader cannot pin shutdown.
private final class StdioWriter: @unchecked Sendable {
    private let descriptor: Int32
    private let previousFlags: Int32
    private let lock = NSLock()
    private var failed = false
    init(_ descriptor: Int32) {
        self.descriptor = descriptor; previousFlags = fcntl(descriptor, F_GETFL)
        if previousFlags >= 0 { _ = fcntl(descriptor, F_SETFL, previousFlags | O_NONBLOCK) }
    }
    deinit { if previousFlags >= 0 { _ = fcntl(descriptor, F_SETFL, previousFlags) } }
    var healthy: Bool { lock.lock(); defer { lock.unlock() }; return !failed }
    func writeFrame(_ data: Data) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !failed else { return false }
        let deadline = ProcessInfo.processInfo.systemUptime + 2
        var offset = 0
        while offset < data.count {
            let remaining = deadline - ProcessInfo.processInfo.systemUptime
            guard remaining > 0 else { failed = true; return false }
            var descriptor = pollfd(fd: self.descriptor, events: Int16(POLLOUT), revents: 0)
            let ready = poll(&descriptor, 1, Int32(remaining * 1000))
            if ready < 0 && errno == EINTR { continue }
            guard ready > 0, descriptor.revents & Int16(POLLOUT) != 0 else { failed = true; return false }
            let count = data.withUnsafeBytes { bytes in
#if canImport(Darwin)
                Darwin.write(self.descriptor, bytes.baseAddress!.advanced(by: offset), data.count - offset)
#else
                Glibc.write(self.descriptor, bytes.baseAddress!.advanced(by: offset), data.count - offset)
#endif
            }
            if count < 0 && [EINTR, EAGAIN].contains(errno) { continue }
            guard count > 0 else { failed = true; return false }; offset += count
        }
        return true
    }
}
public enum MCPStdio {
    public static func run(backend: any MCPBackend, version: String) async {
        let oldPipe = signal(SIGPIPE, SIG_IGN)
        defer { signal(SIGPIPE, oldPipe) }
        let writer = StdioWriter(STDOUT_FILENO)
        let connection = MCPConnection(backend: backend, version: version) { writer.writeFrame($0) }
        var framer = NDJSONFramer()
        while !Task.isCancelled && writer.healthy {
            let chunk: InputChunk = await withCheckedContinuation { continuation in
                DispatchQueue.global(qos: .utility).async {
                    var descriptor = pollfd(fd: STDIN_FILENO, events: Int16(POLLIN), revents: 0)
                    let ready = poll(&descriptor, 1, 100)
                    if ready == 0 || (ready < 0 && errno == EINTR) { continuation.resume(returning: .idle); return }
                    guard ready > 0 else { continuation.resume(returning: .eof); return }
                    var bytes = [UInt8](repeating: 0, count: 4096)
#if canImport(Darwin)
                    let count = Darwin.read(STDIN_FILENO, &bytes, bytes.count)
#else
                    let count = Glibc.read(STDIN_FILENO, &bytes, bytes.count)
#endif
                    continuation.resume(returning: count > 0 ? .data(Data(bytes.prefix(count))) : .eof)
                }
            }
            guard writer.healthy else { break }
            if case .idle = chunk { continue }
            guard case .data(let data) = chunk else { break }
            for frame in framer.append(data) {
                switch frame {
                case .line(let line): await connection.receive(line)
                case .invalid: await connection.invalidFrame()
                }
            }
        }
        for _ in framer.finish() { await connection.invalidFrame() }
        await connection.close()
    }
    private enum InputChunk: Sendable { case data(Data), idle, eof }
}
