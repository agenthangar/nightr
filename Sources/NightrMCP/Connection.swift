import Foundation

/// One connection has only protocol state. Controller ownership never belongs to it.
public actor MCPConnection {
    public static let modernVersion = "2026-07-28"
    public static let legacyVersion = "2025-11-25"
    public static let maximumFrameBytes = 65_536
    public static let maximumConcurrentRequests = 4
    private let backend: any MCPBackend
    private let output: @Sendable (Data) -> Bool
    private let version: String
    private var legacyInitialized = false
    private var legacyReady = false
    private var closed = false
    private struct Pending { let token: UUID; let task: Task<Void, Never>; var cancelled = false }
    private var pending: [RequestID: Pending] = [:]
    public init(backend: any MCPBackend, version: String, output: @escaping @Sendable (Data) -> Bool) {
        self.backend = backend; self.version = version; self.output = output
    }
    public func close() {
        closed = true; pending.values.forEach { $0.task.cancel() }; pending.removeAll()
        // No Stop: another client may still need the shared per-user protection.
    }
    public func invalidFrame() { if !closed { error(nil, -32700, "Invalid or oversized JSON frame") } }
    public func receive(_ bytes: Data) {
        guard !closed else { return }
        guard bytes.count <= Self.maximumFrameBytes else { invalidFrame(); return }
        let value: JSON
        do { value = try Self.decode(bytes) }
        catch is InvalidCancellationIdentifier { return }
        catch is InvalidRequestIdentifier { error(nil, -32600, "Invalid request ID"); return }
        catch { self.error(nil, -32700, "Parse error"); return }
        guard let object = value.object else { error(nil, -32600, "Invalid request"); return }
        let id = RequestID(object["id"])
        let notification = object["id"] == nil && object["jsonrpc"] == .string("2.0") && object["method"]?.string != nil
        guard object["jsonrpc"] == .string("2.0"), let method = object["method"]?.string,
              !method.isEmpty, Set(object.keys).isSubset(of: ["jsonrpc", "id", "method", "params"]),
              object["id"] == nil || id != nil,
              object["params"] == nil || object["params"]?.object != nil else {
            if !notification { error(id, -32600, "Invalid request") }; return
        }
        let params = object["params"]?.object ?? [:]
        // Notifications never invoke tools or receive a reply, including unknown ones.
        guard let id else {
            if method == "notifications/initialized", legacyInitialized, Self.only(params, ["_meta"]),
               params["_meta"] == nil || params["_meta"]?.object != nil { legacyReady = true }
            if method == "notifications/cancelled", let cancelled = RequestID(params["requestId"]) {
                pending[cancelled]?.cancelled = true
                pending[cancelled]?.task.cancel()
            }
            return
        }
        guard pending[id] == nil else { error(id, -32600, "Request ID is already in flight"); return }
        if method == "initialize" {
            guard !legacyInitialized, Set(params.keys).isSubset(of: ["protocolVersion", "capabilities", "clientInfo", "_meta"]),
                  params["protocolVersion"]?.string != nil, params["capabilities"]?.object != nil,
                  params["_meta"] == nil || params["_meta"]?.object != nil,
                  Self.validImplementation(params["clientInfo"]) else { error(id, -32602, "Invalid initialize parameters"); return }
            legacyInitialized = true
            send(id, .object(["protocolVersion": .string(Self.legacyVersion), "capabilities": capabilities,
                              "serverInfo": serverInfo, "instructions": .string(Self.instructions)]), modern: false)
            return
        }
        let modern: Bool
        if let meta = params["_meta"]?.object, let requested = meta["io.modelcontextprotocol/protocolVersion"]?.string {
            guard requested == Self.modernVersion else {
                error(id, -32022, "Unsupported protocol version", data: ["supported": .array([.string(Self.modernVersion), .string(Self.legacyVersion)]), "requested": .string(requested)]); return
            }
            guard meta["io.modelcontextprotocol/clientCapabilities"]?.object != nil,
                  meta["io.modelcontextprotocol/clientInfo"] == nil || Self.validImplementation(meta["io.modelcontextprotocol/clientInfo"]) else {
                error(id, -32602, "Invalid request metadata"); return
            }
            modern = true
        } else {
            guard legacyReady else { error(id, -32600, "Initialize the legacy connection or include modern request metadata"); return }
            // A malformed modern metadata field must not silently inherit legacy state.
            if let meta = params["_meta"], meta.object == nil || meta.object?["io.modelcontextprotocol/protocolVersion"] != nil {
                error(id, -32602, "Invalid request metadata"); return
            }
            modern = false
        }
        switch method {
        case "server/discover":
            guard modern, Self.only(params, ["_meta"]) else { error(id, -32602, "Invalid discovery parameters"); return }
            send(id, .object(["supportedVersions": .array([.string(Self.modernVersion), .string(Self.legacyVersion)]),
                              "capabilities": capabilities, "instructions": .string(Self.instructions)]), modern: true)
        case "ping":
            guard Self.only(params, ["_meta"]) else { error(id, -32602, "Invalid ping parameters"); return }
            send(id, .object([:]), modern: modern)
        case "tools/list":
            guard Self.only(params, ["_meta"]) else { error(id, -32602, "Pagination is not supported"); return }
            send(id, .object(["tools": .array(MCPTool.allCases.map(\.definition))]), modern: modern)
        case "tools/call":
            guard Self.only(params, ["_meta", "name", "arguments"]), let name = params["name"]?.string,
                  params["arguments"] == nil || params["arguments"] == .object([:]) else { error(id, -32602, "Tools accept only an empty arguments object"); return }
            guard let tool = MCPTool(rawValue: name) else { error(id, -32602, "Unknown tool"); return }
            guard pending.count < Self.maximumConcurrentRequests else { error(id, 1001, "Too many in-flight requests; wait for a result"); return }
            let token = UUID(), backend = self.backend
            let task = Task { [weak self] in
                let result: MCPToolResult
                if Task.isCancelled { result = .failure("cancelled", "Cancelled before dispatch.", remediation: "Read status before further mutations.") }
                else { result = await backend.execute(tool) }
                await self?.completed(id, token: token, result: result, modern: modern)
            }
            pending[id] = Pending(token: token, task: task)
        default: error(id, -32601, "Method not found")
        }
    }
    private func completed(_ id: RequestID, token: UUID, result: MCPToolResult, modern: Bool) {
        guard !closed, pending[id]?.token == token else { return }
        let cancelled = pending[id]?.cancelled == true
        pending[id] = nil
        if !cancelled { send(id, result.json, modern: modern) }
    }
    private var capabilities: JSON { .object(["tools": .object([:])]) }
    private var serverInfo: JSON { .object(["name": .string("nightr"), "version": .string(version)]) }
    private static let instructions = "Nightr controls shared per-user Mac protection. Read status first. Connecting, listing tools, task completion, cancellation and disconnect never Start or Stop. Start and Stop require explicit user intent. An unavailable controller is not confirmed Off. Never automatically repeat a timed-out mutation: it may already have occurred."
    private static func only(_ params: [String: JSON], _ keys: Set<String>) -> Bool { Set(params.keys).isSubset(of: keys) }
    private static func validImplementation(_ value: JSON?) -> Bool { value?.object?["name"]?.string != nil && value?.object?["version"]?.string != nil }
    private func send(_ id: RequestID, _ result: JSON, modern: Bool) {
        var result = result.object ?? [:]
        if modern { result["resultType"] = .string("complete"); result["_meta"] = .object(["io.modelcontextprotocol/serverInfo": serverInfo]) }
        emit(.object(["jsonrpc": .string("2.0"), "id": id.json, "result": .object(result)]))
    }
    private func error(_ id: RequestID?, _ code: Int, _ message: String, data: [String: JSON]? = nil) {
        var detail: [String: JSON] = ["code": .integer(code), "message": .string(message)]
        if let data { detail["data"] = .object(data) }
        emit(.object(["jsonrpc": .string("2.0"), "id": id?.json ?? .null, "error": .object(detail)]))
    }
    private func emit(_ json: JSON) {
        guard !closed else { return }
        guard let data = try? json.encoded(), data.count <= Self.maximumFrameBytes else {
            let fallback = JSON.object(["jsonrpc": .string("2.0"), "id": json.object?["id"] ?? .null,
                                        "error": .object(["code": .integer(-32603), "message": .string("Response exceeds output limit")])])
            if let bounded = try? fallback.encoded() { _ = output(bounded + Data([10])) }
            close(); return
        }
        if !output(data + Data([10])) { close() }
    }
    /// Reject ambiguous duplicate object keys and excessive nesting before decoding.
    private struct InvalidRequestIdentifier: Error {}
    private struct InvalidCancellationIdentifier: Error {}
    private struct CancellationHeader: Decodable {
        let jsonrpc: String
        let method: String
        let hasID: Bool
        private enum CodingKeys: String, CodingKey { case jsonrpc, method, id }
        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            jsonrpc = try container.decode(String.self, forKey: .jsonrpc)
            method = try container.decode(String.self, forKey: .method)
            hasID = container.contains(.id)
        }
    }
    private static func decode(_ bytes: Data) throws -> JSON {
        let bytes = Array(bytes); var containers: [Set<String>?] = []; var index = 0
        var invalidCancellationID = false
        while index < bytes.count {
            let byte = bytes[index]
            if byte == 34 {
                let start = index; index += 1
                while index < bytes.count {
                    if bytes[index] == 92 { index += 2; continue }
                    if bytes[index] == 34 { break }; index += 1
                }
                guard index < bytes.count else { throw CocoaError(.coderReadCorrupt) }
                var next = index + 1
                while next < bytes.count, [9, 10, 13, 32].contains(bytes[next]) { next += 1 }
                if next < bytes.count, bytes[next] == 58, !containers.isEmpty, containers[containers.count - 1] != nil {
                    let key = try JSONDecoder().decode(String.self, from: Data(bytes[start...index]))
                    guard containers[containers.count - 1]!.insert(key).inserted else { throw CocoaError(.coderReadCorrupt) }
                    let rootID = containers.count == 1 && key == "id"
                    let cancellationID = containers.count == 2 && key == "requestId"
                    if rootID || cancellationID {
                        var begin = next + 1
                        while begin < bytes.count, [9, 10, 13, 32].contains(bytes[begin]) { begin += 1 }
                        if begin < bytes.count, bytes[begin] == 45 || (48...57).contains(bytes[begin]) {
                            var end = begin
                            while end < bytes.count, ![9, 10, 13, 32, 44, 125].contains(bytes[end]) { end += 1 }
                            // Inspect the wire token before Double decoding can round
                            // a fractional/underflow ID into a different integer.
                            let token = String(decoding: bytes[begin..<end], as: UTF8.self)
                            let valid = token.range(of: "^-?(0|[1-9][0-9]*)$", options: .regularExpression) != nil &&
                                Int64(token).map { (-9_007_199_254_740_991...9_007_199_254_740_991).contains($0) } == true
                            if !valid {
                                if rootID { throw InvalidRequestIdentifier() }
                                invalidCancellationID = true
                            }
                        }
                    }
                }
            } else if byte == 123 || byte == 91 {
                containers.append(byte == 123 ? Set<String>() : nil)
                guard containers.count <= 64 else { throw CocoaError(.coderReadCorrupt) }
            } else if byte == 125 || byte == 93 {
                guard !containers.isEmpty else { throw CocoaError(.coderReadCorrupt) }; containers.removeLast()
            }
            index += 1
        }
        if invalidCancellationID {
            // Decoding only the header validates the complete JSON syntax without
            // converting an ignored requestId such as 1e-999 to a lossy Double.
            let header = try JSONDecoder().decode(CancellationHeader.self, from: Data(bytes))
            if header.jsonrpc == "2.0", !header.hasID, header.method == "notifications/cancelled" { throw InvalidCancellationIdentifier() }
        }
        return try JSONDecoder().decode(JSON.self, from: Data(bytes))
    }
}
