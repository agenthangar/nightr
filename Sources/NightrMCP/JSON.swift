import Foundation

/// Deliberately small JSON boundary: no Foundation `Any` crosses concurrent work.
public enum JSON: Codable, Equatable, Sendable {
    case object([String: JSON]), array([JSON]), string(String), number(Double), bool(Bool), null
    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let value = try? c.decode(Bool.self) { self = .bool(value) }
        else if let value = try? c.decode(String.self) { self = .string(value) }
        else if let value = try? c.decode(Double.self) { self = .number(value) }
        else if let value = try? c.decode([String: JSON].self) { self = .object(value) }
        else { self = .array(try c.decode([JSON].self)) }
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .object(let value): try c.encode(value)
        case .array(let value): try c.encode(value)
        case .string(let value): try c.encode(value)
        case .number(let value): try c.encode(value)
        case .bool(let value): try c.encode(value)
        case .null: try c.encodeNil()
        }
    }
    public var object: [String: JSON]? { if case .object(let value) = self { return value }; return nil }
    public var string: String? { if case .string(let value) = self { return value }; return nil }
    public static func integer(_ value: Int) -> JSON { .number(Double(value)) }
    public func encoded() throws -> Data { let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]; return try encoder.encode(self) }
}

enum RequestID: Hashable, Sendable {
    case string(String), number(Double)
    init?(_ value: JSON?) {
        switch value {
        case .string(let text): self = .string(text)
        case .number(let number) where number.isFinite && number.rounded() == number && abs(number) <= 9_007_199_254_740_991: self = .number(number)
        default: return nil
        }
    }
    var json: JSON { switch self { case .string(let value): return .string(value); case .number(let value): return .number(value) } }
}
