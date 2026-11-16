// A Foundation-only smoke harness for developer toolchains without XCTest.
// Compiled alongside Sources/NightrMCP/*.swift by scripts/check_mcp.py.
import Foundation

private final class Frames: @unchecked Sendable {
    let lock = NSLock()
    private var frames: [JSON] = []
    func append(_ data: Data) -> Bool { lock.lock(); defer { lock.unlock() }; frames.append(try! JSONDecoder().decode(JSON.self, from: data)); return true }
    var values: [JSON] { lock.lock(); defer { lock.unlock() }; return frames }
}
private actor FakeBackend: MCPBackend {
    var calls: [MCPTool] = []
    private var blocked = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func block() { blocked = true }
    func release() { blocked = false; waiters.forEach { $0.resume() }; waiters = [] }
    func execute(_ tool: MCPTool) async -> MCPToolResult {
        calls.append(tool)
        if blocked { await withCheckedContinuation { waiters.append($0) } }
        return .init("Synthetic result", data: ["sample": .bool(true)])
    }
}
@main struct MCPProtocolSmoke {
    static func require(_ value: Bool, _ message: String) { if !value { fatalError(message) } }
    static func request(_ method: String, id: Int = 1, params: [String: JSON] = [:], modern: Bool = true) -> Data {
        var params = params
        if modern { params["_meta"] = .object(["io.modelcontextprotocol/protocolVersion": .string("2026-07-28"), "io.modelcontextprotocol/clientCapabilities": .object([:])]) }
        return try! JSON.object(["jsonrpc": .string("2.0"), "id": .integer(id), "method": .string(method), "params": .object(params)]).encoded()
    }
    private static func waitCalls(_ backend: FakeBackend, _ count: Int) async {
        for _ in 0..<200 { if await backend.calls.count >= count { return }; try? await Task.sleep(nanoseconds: 1_000_000) }
        fatalError("backend did not dispatch")
    }
    static func main() async {
        let frames = Frames(), backend = FakeBackend()
        let connection = MCPConnection(backend: backend, version: "synthetic") { frames.append($0) }
        await connection.receive(request("server/discover"))
        await connection.receive(request("tools/list", id: 2))
        require(frames.values.count == 2, "modern discovery/list")
        require(frames.values[0].object?["result"]?.object?["resultType"] == .string("complete"), "modern result type")
        await connection.receive(request("initialize", params: ["protocolVersion": .string("2025-11-25"), "capabilities": .object([:]), "clientInfo": .object(["name": .string("synthetic"), "version": .string("1")])], modern: false))
        await connection.receive(Data(#"{"jsonrpc":"2.0","method":"notifications/initialized","params":{"_meta":[]}}"#.utf8))
        await connection.receive(request("tools/list", modern: false))
        require(frames.values.count == 4 && frames.values[3].object?["error"] != nil, "invalid initialization metadata must not ready")
        await connection.receive(Data(#"{"jsonrpc":"2.0","method":"notifications/initialized","params":{"_meta":{}}}"#.utf8))
        await connection.receive(request("tools/list", modern: false))
        require(frames.values.count == 5 && frames.values[4].object?["result"] != nil, "legacy handshake/list with optional metadata")
        require(frames.values[4].object?["result"]?.object?["resultType"] == nil, "legacy result type")
        let count = frames.values.count
        for frame in [#"{"jsonrpc":"2.0","method":"tools/call","params":[]}"#, #"{"jsonrpc":"2.0","method":"unknown","extra":true}"#,
                      #"{"jsonrpc":"2.0","method":"tools/call","params":{"name":"nightr_start"}}"#] {
            await connection.receive(Data(frame.utf8))
        }
        require(frames.values.count == count, "notification silence")
        for id in ["true", "null", "1.00000000000000001", "9007199254740991.1", "1e-999", "9007199254740992"] {
            let frame = "{\"jsonrpc\":\"2.0\",\"id\":\(id),\"method\":\"tools/call\",\"params\":{\"name\":\"nightr_start\",\"_meta\":{\"io.modelcontextprotocol/protocolVersion\":\"2026-07-28\",\"io.modelcontextprotocol/clientCapabilities\":{}}}}"
            await connection.receive(Data(frame.utf8))
        }
        await connection.receive(request("tools/call", params: ["name": .string("nightr_start"), "arguments": .object(["force": .bool(true)])]))
        await connection.receive(Data(#"{"jsonrpc":"2.0","id":1,"id":2,"method":"ping"}"#.utf8))
        require(frames.values.count == count + 8, "invalid boundary errors")
        let emptyCalls = await backend.calls; require(emptyCalls.isEmpty, "no invalid dispatch")
        let cancelFrames = Frames(), cancelBackend = FakeBackend(); await cancelBackend.block()
        let cancelConnection = MCPConnection(backend: cancelBackend, version: "synthetic") { cancelFrames.append($0) }
        await cancelConnection.receive(request("tools/call", params: ["name": .string("nightr_status")]))
        await waitCalls(cancelBackend, 1)
        for id in ["1.00000000000000001", "1e0", "1e-999"] {
            await cancelConnection.receive(Data("{\"jsonrpc\":\"2.0\",\"method\":\"notifications/cancelled\",\"params\":{\"requestId\":\(id)}}".utf8))
        }
        require(cancelFrames.values.isEmpty, "malformed cancellation stays silent")
        await cancelBackend.release(); try? await Task.sleep(nanoseconds: 20_000_000)
        require(cancelFrames.values.count == 1 && cancelFrames.values[0].object?["result"] != nil, "lossy cancellation cannot alias another ID")
        await cancelConnection.close()
        await backend.block()
        for id in 10...13 { await connection.receive(request("tools/call", id: id, params: ["name": .string("nightr_start")])) }
        await waitCalls(backend, 4)
        for id in 10...13 { await connection.receive(try! JSON.object(["jsonrpc": .string("2.0"), "method": .string("notifications/cancelled"), "params": .object(["requestId": .integer(id)])]).encoded()) }
        await connection.receive(request("tools/call", id: 14, params: ["name": .string("nightr_start")]))
        require(frames.values.last?.object?["error"]?.object?["code"] == .integer(1001), "cancel cannot refill occupancy")
        let beforeRelease = frames.values.count
        await backend.release(); try? await Task.sleep(nanoseconds: 20_000_000)
        require(frames.values.count == beforeRelease, "cancel suppresses late replies")
        await connection.close()
        let failed = MCPConnection(backend: backend, version: "synthetic") { _ in false }
        await failed.receive(request("tools/list"))
        await failed.receive(request("tools/call", params: ["name": .string("nightr_start")]))
        try? await Task.sleep(nanoseconds: 10_000_000)
        let calls = await backend.calls; require(calls.count == 4, "failed output closes before mutation")
        require(!calls.contains(.stop), "lifecycle must never Stop")
        var framer = NDJSONFramer()
        require(framer.append(Data("{".utf8)).isEmpty, "fragment buffering")
        require(framer.append(Data("}\n".utf8)) == [.line(Data("{}".utf8))], "fragment completion")
        require(framer.append(Data(repeating: 32, count: 65_537)) == [.invalid], "bounded frame")
        require(framer.append(Data("\n{}\n".utf8)) == [.line(Data("{}".utf8))], "frame recovery")
        print("MCP fake protocol smoke passed (no OS adapter or real mutations)")
    }
}
