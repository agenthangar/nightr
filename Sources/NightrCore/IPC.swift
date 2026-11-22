import Foundation

public enum ControllerCommand: String, Codable, Sendable { case status, start, stop, beginForce, endForce, applySettings, retryNow, tryAgain, skipFallback, prepareUpdate, inferenceBegin, inferenceHeartbeat, inferenceEnd }
public struct ControllerRequest: Codable, Sendable {
    public static let version = 1
    public var version: Int = Self.version
    public var command: ControllerCommand
    public var settings: Settings?
    public var inference: InferenceMetadata?
    public var inferenceToken: UUID?
    public init(command: ControllerCommand, settings: Settings? = nil, inference: InferenceMetadata? = nil, inferenceToken: UUID? = nil) {
        self.command = command; self.settings = settings; self.inference = inference; self.inferenceToken = inferenceToken
    }
}
public struct ControllerStatus: Codable, Sendable {
    public var state: ControllerState
    public var settings: Settings
    public var forceMode: Bool?
    public var holding: Bool
    public var verificationEligible: Bool
    public var sample: MachineSample
    public var message: String?
    public init(engine: MonitorEngine, message: String? = nil, holding: Bool? = nil) {
        forceMode = engine.forceMode
        state = engine.state; settings = engine.settings; self.holding = holding ?? engine.holding
        verificationEligible = engine.verificationEligible; sample = engine.sample; self.message = message
    }
}
public struct ControllerResponse: Codable, Sendable {
    public var version: Int = ControllerRequest.version
    public var status: ControllerStatus?
    public var error: String?
    public var inferenceToken: UUID?
    public init(status: ControllerStatus? = nil, error: String? = nil, inferenceToken: UUID? = nil) { self.status = status; self.error = error; self.inferenceToken = inferenceToken }
}
public enum IPCError: Error, LocalizedError {
    case invalid(String)
    public var errorDescription: String? { if case .invalid(let text) = self { return text }; return nil }
}
/// Four byte network-order length prefix, with a strict 64 KiB maximum.
public enum FrameCodec {
    public static let maximumBytes = 65_536
    public static func encode<T: Encodable>(_ value: T) throws -> Data {
        let json = try JSONEncoder().encode(value)
        guard json.count > 0, json.count <= maximumBytes else { throw IPCError.invalid("IPC frame is too large") }
        var size = UInt32(json.count).bigEndian
        var data = withUnsafeBytes(of: &size) { Data($0) }; data.append(json); return data
    }
    public static func payloadLength(_ header: Data) throws -> Int {
        guard header.count == 4 else { throw IPCError.invalid("invalid IPC frame header") }
        let length = header.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        guard length > 0 && length <= UInt32(maximumBytes) else { throw IPCError.invalid("invalid IPC frame length") }
        return Int(length)
    }
}
