import Foundation
#if os(macOS)
import Darwin
#else
import Glibc
#endif

public enum NativeOperationError: Error { case unavailable, timedOut, cancelled, failed, malformed }

private final class ProcessOutput: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    func set(_ value: Data) { lock.lock(); data = value; lock.unlock() }
    func get() -> Data { lock.lock(); defer { lock.unlock() }; return data }
}

// One owned process per operation. The worker does not launch descendants. Terminate,
// then kill and reap it before returning; cancellation never leaves a Wi-Fi join running.
public final class BoundedProcess: @unchecked Sendable {
    private let lock = NSLock()
    private var child: Process?
    private var cancelled = false
    public init() {}
    public func cancel() {
        lock.lock(); cancelled = true
        let running = child
        lock.unlock()
        if let running, running.isRunning { running.terminate() }
    }
    public func run(executable: URL, arguments: [String], input: Data = Data(), timeout: TimeInterval,
                    environment: [String: String]? = nil) throws -> Data {
        let process = Process()
        process.executableURL = executable; process.arguments = arguments
        process.environment = (environment ?? ProcessInfo.processInfo.environment).filter { !$0.key.hasPrefix("COV_CORE_") }
        let inbound = Pipe(), outbound = Pipe()
        process.standardInput = inbound; process.standardOutput = outbound
        process.standardError = FileHandle.nullDevice
        lock.lock()
        guard !cancelled else { lock.unlock(); throw NativeOperationError.cancelled }
        do { try process.run(); child = process; lock.unlock() }
        catch { lock.unlock(); throw NativeOperationError.unavailable }
        // Drain concurrently so a full pipe cannot deadlock a trusted worker.
        let output = ProcessOutput(), drained = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .utility).async {
            let handle = outbound.fileHandleForReading
            var data = Data()
            while let bytes = try? handle.read(upToCount: 64 * 1024), !bytes.isEmpty {
                if data.count <= 512 * 1024 { data.append(bytes) }
            }
            try? handle.close()
            output.set(data)
            drained.signal()
        }
        // Worker requests are small, bounded metadata. There are no credential bytes here.
        try? inbound.fileHandleForWriting.write(contentsOf: input)
        try? inbound.fileHandleForWriting.close()
        let deadline = Date().addingTimeInterval(max(0.1, min(timeout, 120)))
        var stopReason: NativeOperationError?
        while process.isRunning {
            lock.lock(); let stopped = cancelled; lock.unlock()
            if stopped { stopReason = .cancelled; break }
            if Date() >= deadline { stopReason = .timedOut; break }
            Thread.sleep(forTimeInterval: 0.02)
        }
        if stopReason != nil, process.isRunning {
            process.terminate()
            let grace = Date().addingTimeInterval(0.5)
            while process.isRunning && Date() < grace { Thread.sleep(forTimeInterval: 0.01) }
            if process.isRunning { _ = kill(process.processIdentifier, SIGKILL) }
        }
        process.waitUntilExit()
        lock.lock(); child = nil; lock.unlock()
        if let stopReason { throw stopReason }
        guard process.terminationStatus == 0 else { throw NativeOperationError.failed }
        drained.wait()
        let result = output.get()
        guard result.count <= 512 * 1024 else { throw NativeOperationError.malformed }
        return result
    }
}
