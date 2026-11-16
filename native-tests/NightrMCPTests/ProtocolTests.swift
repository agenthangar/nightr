import XCTest
@testable import NightrMCP

final class OutputFrames: @unchecked Sendable {
    private let lock = NSLock()
    private var frames: [JSON] = []
    @discardableResult func append(_ bytes: Data) -> Bool { lock.lock(); defer { lock.unlock() }; frames.append(try! JSONDecoder().decode(JSON.self, from: bytes)); return true }
    var values: [JSON] { lock.lock(); defer { lock.unlock() }; return frames }
    func wait(_ count: Int) async {
        for _ in 0..<200 { if values.count >= count { return }; try? await Task.sleep(nanoseconds: 5_000_000) }
    }
}
actor FixtureBackend: MCPBackend {
    private(set) var calls: [MCPTool] = []
    var blocked = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func block() { blocked = true }
    func release() { blocked = false; let callbacks = waiters; waiters = []; callbacks.forEach { $0.resume() } }
    func execute(_ tool: MCPTool) async -> MCPToolResult {
        calls.append(tool)
        if blocked { await withCheckedContinuation { waiters.append($0) } }
        return .init("Synthetic result", data: ["sample": .bool(true)])
    }
}
final class ProtocolTests: XCTestCase {
    let meta: JSON = .object(["io.modelcontextprotocol/protocolVersion": .string(MCPConnection.modernVersion), "io.modelcontextprotocol/clientCapabilities": .object([:])])
    func request(_ method: String, id: JSON = .integer(1), params: [String: JSON] = [:], modern: Bool = true) throws -> Data {
        var params = params; if modern { params["_meta"] = meta }
        return try JSON.object(["jsonrpc": .string("2.0"), "id": id, "method": .string(method), "params": .object(params)]).encoded()
    }
    func testModernDiscoveryAndToolsNeedNoInitializationOrBackend() async throws {
        let output = OutputFrames(), backend = FixtureBackend()
        let connection = MCPConnection(backend: backend, version: "test") { output.append($0) }
        try await connection.receive(request("server/discover"))
        try await connection.receive(request("tools/list", id: .string("tools")))
        XCTAssertEqual(output.values.count, 2)
        let result = output.values[0].object?["result"]?.object
        XCTAssertEqual(result?["resultType"], .string("complete"))
        XCTAssertEqual(result?["capabilities"], .object(["tools": .object([:])]))
        let tools = output.values[1].object?["result"]?.object?["tools"]
        guard case .array(let definitions) = tools else { return XCTFail("missing tools") }
        XCTAssertEqual(definitions.count, 8)
        XCTAssertEqual(definitions.first?.object?["inputSchema"]?.object?["additionalProperties"], .bool(false))
        let calls = await backend.calls; XCTAssertTrue(calls.isEmpty)
        await connection.close()
    }
    func testLegacyHandshakeAndToolResult() async throws {
        let output = OutputFrames(), backend = FixtureBackend()
        let connection = MCPConnection(backend: backend, version: "test") { output.append($0) }
        try await connection.receive(request("tools/list", modern: false))
        XCTAssertNotNil(output.values[0].object?["error"])
        try await connection.receive(request("initialize", params: ["protocolVersion": .string("2025-11-25"), "capabilities": .object([:]), "clientInfo": .object(["name": .string("fixture"), "version": .string("1")])], modern: false))
        XCTAssertEqual(output.values[1].object?["result"]?.object?["protocolVersion"], .string("2025-11-25"))
        XCTAssertNil(output.values[1].object?["result"]?.object?["resultType"])
        await connection.receive(Data(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#.utf8))
        try await connection.receive(request("tools/call", id: .integer(2), params: ["name": .string("nightr_status"), "arguments": .object([:])], modern: false))
        await output.wait(3)
        XCTAssertEqual(output.values[2].object?["result"]?.object?["structuredContent"], .object(["sample": .bool(true)]))
        XCTAssertNil(output.values[2].object?["result"]?.object?["resultType"])
        await connection.close()
    }
    func testMalformedEnvelopesIDsDuplicateKeysAndOversizeNeverDispatch() async throws {
        let output = OutputFrames(), backend = FixtureBackend()
        let connection = MCPConnection(backend: backend, version: "test") { output.append($0) }
        for frame in ["[1]", "{}", "{", #"{"jsonrpc":"2.0","id":true,"method":"ping"}"#,
                      #"{"jsonrpc":"2.0","id":null,"method":"ping"}"#, #"{"jsonrpc":"2.0","id":1.5,"method":"ping"}"#,
                      #"{"jsonrpc":"2.0","id":1,"id":2,"method":"ping"}"#,
                      #"{"jsonrpc":"2.0","id":1,"method":"ping","params":[]}"#] {
            await connection.receive(Data(frame.utf8))
        }
        await connection.receive(Data(repeating: 32, count: 65_537))
        XCTAssertEqual(output.values.count, 9)
        XCTAssertTrue(output.values.allSatisfy { $0.object?["error"] != nil })
        let calls = await backend.calls; XCTAssertTrue(calls.isEmpty)
        await connection.close()
    }
    func testUnsupportedVersionAndStrictArguments() async throws {
        let output = OutputFrames(), backend = FixtureBackend()
        let connection = MCPConnection(backend: backend, version: "test") { output.append($0) }
        let badMeta: JSON = .object(["io.modelcontextprotocol/protocolVersion": .string("1900-01-01"), "io.modelcontextprotocol/clientCapabilities": .object([:])])
        try await connection.receive(request("tools/list", params: ["_meta": badMeta], modern: false))
        XCTAssertEqual(output.values[0].object?["error"]?.object?["code"], .integer(-32022))
        let invalidParams: [[String: JSON]] = [["name": .string("no_such_tool")], ["name": .string("nightr_start"), "arguments": .object(["force": .bool(true)])], ["name": .string("nightr_start"), "arguments": .null], ["name": .string("nightr_stop"), "extra": .bool(true)]]
        for params in invalidParams {
            try await connection.receive(request("tools/call", params: params))
        }
        XCTAssertEqual(output.values.count, 5)
        let calls = await backend.calls; XCTAssertTrue(calls.isEmpty)
        await connection.close()
    }
    func testNotificationsAreSilentAndCannotMutate() async throws {
        let output = OutputFrames(), backend = FixtureBackend()
        let connection = MCPConnection(backend: backend, version: "test") { output.append($0) }
        for method in ["tools/call", "unknown", "notifications/cancelled"] {
            let message = JSON.object(["jsonrpc": .string("2.0"), "method": .string(method), "params": .object(["name": .string("nightr_start"), "arguments": .object([:])])])
            await connection.receive(try message.encoded())
        }
        for frame in [#"{"jsonrpc":"2.0","method":"tools/call","params":[]}"#, #"{"jsonrpc":"2.0","method":"unknown","extra":true}"#] {
            await connection.receive(Data(frame.utf8))
        }
        let calls = await backend.calls; XCTAssertTrue(calls.isEmpty)
        XCTAssertTrue(output.values.isEmpty)
        await connection.close()
    }
    func testCancellationRetainsOccupancyAndSuppressesLateResponses() async throws {
        let output = OutputFrames(), backend = FixtureBackend(); await backend.block()
        let connection = MCPConnection(backend: backend, version: "test") { output.append($0) }
        for id in 1...4 {
            try await connection.receive(request("tools/call", id: .integer(id), params: ["name": .string("nightr_start")]))
        }
        for _ in 0..<200 { if await backend.calls.count == 4 { break }; await Task.yield() }
        for id in 1...4 {
            await connection.receive(try JSON.object(["jsonrpc": .string("2.0"), "method": .string("notifications/cancelled"), "params": .object(["requestId": .integer(id)])]).encoded())
        }
        try await connection.receive(request("tools/call", id: .integer(5), params: ["name": .string("nightr_start")]))
        XCTAssertEqual(output.values.first?.object?["error"]?.object?["code"], .integer(1001))
        await backend.release()
        try await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertEqual(output.values.count, 1)
        await connection.close()
        let calls = await backend.calls; XCTAssertEqual(calls.count, 4)
    }
    func testEOFDoesNotWaitOrStopAndDropsLateReplies() async throws {
        let output = OutputFrames(), backend = FixtureBackend(); await backend.block()
        let connection = MCPConnection(backend: backend, version: "test") { output.append($0) }
        try await connection.receive(request("tools/call", params: ["name": .string("nightr_start")]))
        for _ in 0..<200 { if await backend.calls.count == 1 { break }; await Task.yield() }
        await connection.close(); await backend.release()
        try await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertTrue(output.values.isEmpty)
        let calls = await backend.calls; XCTAssertFalse(calls.contains(.stop))
    }
    func testFramingIsFragmentedBoundedAndRecovers() {
        var framer = NDJSONFramer()
        XCTAssertEqual(framer.append(Data("{\"a\":".utf8)), [])
        XCTAssertEqual(framer.append(Data("1}\n{}\n".utf8)), [.line(Data("{\"a\":1}".utf8)), .line(Data("{}".utf8))])
        XCTAssertEqual(framer.append(Data(repeating: 32, count: 65_537)), [.invalid])
        XCTAssertEqual(framer.append(Data("ignored\n{}\n".utf8)), [.line(Data("{}".utf8))])
        XCTAssertEqual(framer.append(Data("partial".utf8)), [])
        XCTAssertEqual(framer.finish(), [.invalid])
    }
    func testLossyNumericIDsNeverDispatch() async {
        let output = OutputFrames(), backend = FixtureBackend()
        let connection = MCPConnection(backend: backend, version: "test") { output.append($0) }
        for id in ["1.00000000000000001", "9007199254740991.1", "1e-999", "1e0", "9007199254740992"] {
            let frame = "{\"jsonrpc\":\"2.0\",\"id\":\(id),\"method\":\"tools/call\",\"params\":{\"name\":\"nightr_start\",\"_meta\":{\"io.modelcontextprotocol/protocolVersion\":\"2026-07-28\",\"io.modelcontextprotocol/clientCapabilities\":{}}}}"
            await connection.receive(Data(frame.utf8))
        }
        XCTAssertEqual(output.values.count, 5)
        XCTAssertTrue(output.values.allSatisfy { $0.object?["error"]?.object?["code"] == .integer(-32600) })
        let calls = await backend.calls; XCTAssertTrue(calls.isEmpty)
        await connection.close()
    }
    func testFailedOutputClosesConnectionBeforeAnyMoreTools() async throws {
        let backend = FixtureBackend()
        let connection = MCPConnection(backend: backend, version: "test") { _ in false }
        try await connection.receive(request("tools/list"))
        try await connection.receive(request("tools/call", params: ["name": .string("nightr_start")]))
        await Task.yield()
        let calls = await backend.calls; XCTAssertTrue(calls.isEmpty)
    }
    func testLossyCancellationIDCannotCancelAnotherIntegerRequest() async throws {
        let output = OutputFrames(), backend = FixtureBackend(); await backend.block()
        let connection = MCPConnection(backend: backend, version: "test") { output.append($0) }
        try await connection.receive(request("tools/call", params: ["name": .string("nightr_status")]))
        for _ in 0..<200 { if await backend.calls.count == 1 { break }; await Task.yield() }
        for id in ["1.00000000000000001", "1e0", "1e-999"] {
            await connection.receive(Data("{\"jsonrpc\":\"2.0\",\"method\":\"notifications/cancelled\",\"params\":{\"requestId\":\(id)}}".utf8))
        }
        XCTAssertTrue(output.values.isEmpty)
        await backend.release(); await output.wait(1)
        XCTAssertEqual(output.values.count, 1)
        XCTAssertNotNil(output.values.first?.object?["result"])
        await connection.close()
    }
    func testLegacyInitializationAcceptsOnlyObjectMetadata() async throws {
        let output = OutputFrames(), backend = FixtureBackend()
        let connection = MCPConnection(backend: backend, version: "test") { output.append($0) }
        var params: [String: JSON] = ["protocolVersion": .string("2025-11-25"), "capabilities": .object([:]), "clientInfo": .object(["name": .string("fixture"), "version": .string("1")]), "_meta": .array([])]
        try await connection.receive(request("initialize", params: params, modern: false))
        XCTAssertNotNil(output.values[0].object?["error"])
        params["_meta"] = .object([:])
        try await connection.receive(request("initialize", params: params, modern: false))
        XCTAssertNotNil(output.values[1].object?["result"])
        await connection.receive(Data(#"{"jsonrpc":"2.0","method":"notifications/initialized","params":{"_meta":[]}}"#.utf8))
        try await connection.receive(request("tools/list", modern: false))
        XCTAssertNotNil(output.values[2].object?["error"])
        await connection.receive(Data(#"{"jsonrpc":"2.0","method":"notifications/initialized","params":{"_meta":{}}}"#.utf8))
        try await connection.receive(request("tools/list", modern: false))
        XCTAssertNotNil(output.values[3].object?["result"])
        await connection.close()
    }
}
