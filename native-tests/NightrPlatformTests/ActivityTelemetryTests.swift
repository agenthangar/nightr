import XCTest
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import NightrCore
@testable import NightrPlatform

private func response(_ json: String, server: String? = nil, status: Int = 200) -> RuntimeHTTPResponse {
    RuntimeHTTPResponse(status: status, server: server, body: Data(json.utf8))
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func increment() -> Int { lock.lock(); defer { lock.unlock() }; value += 1; return value }
    func get() -> Int { lock.lock(); defer { lock.unlock() }; return value }
}

private final class SyntheticRuntimeProtocol: URLProtocol, @unchecked Sendable {
    enum Mode { case success, oversized, silent }
    private static let lock = NSLock()
    private static var mode: Mode = .success
    private static var captured: URLRequest?
    static func configure(_ mode: Mode) { lock.lock(); self.mode = mode; captured = nil; lock.unlock() }
    static func request() -> URLRequest? { lock.lock(); defer { lock.unlock() }; return captured }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock(); let mode = Self.mode; Self.captured = request; Self.lock.unlock()
        if mode == .silent { return }
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Server": "synthetic", "Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        let bytes = mode == .oversized ? Data(repeating: 32, count: RuntimeHTTPRequest.maximumBytes + 1) : Data(#"{"version":"1.2.3"}"#.utf8)
        client?.urlProtocol(self, didLoad: bytes)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

final class ActivityTelemetryTests: XCTestCase {
    func testCPUDeltasNeedBaselineAndBoundAcrossTickRollover() {
        var cpu = CPULoad()
        XCTAssertNil(cpu.observe(CPUTicks(user: 100, system: 100, idle: 800, nice: 0)))
        XCTAssertEqual(cpu.observe(CPUTicks(user: 120, system: 110, idle: 870, nice: 0)), 30)
        XCTAssertNil(cpu.observe(CPUTicks(user: 120, system: 110, idle: 870, nice: 0)))
        XCTAssertNil(cpu.observe(nil))
        XCTAssertNil(cpu.observe(CPUTicks(user: UInt32.max - 9, system: 0, idle: 10, nice: 0)))
        XCTAssertEqual(cpu.observe(CPUTicks(user: 0, system: 0, idle: 20, nice: 0)), 50)
    }

    func testGPUOnlyAcceptsFiniteMeasuredPercentages() {
        XCTAssertNil(SystemActivityMetrics.gpuPercentage(nil))
        XCTAssertNil(SystemActivityMetrics.gpuPercentage("72"))
        XCTAssertNil(SystemActivityMetrics.gpuPercentage(true))
        XCTAssertNil(SystemActivityMetrics.gpuPercentage(Double.nan))
        XCTAssertNil(SystemActivityMetrics.gpuPercentage(101))
        XCTAssertNil(SystemActivityMetrics.gpuPercentage(-1))
        XCTAssertEqual(SystemActivityMetrics.gpuPercentage(0), 0)
        XCTAssertEqual(SystemActivityMetrics.gpuPercentage(42.8), 43)
    }

    func testFailedProbePreservesBoundedStaleRosterWithoutRenewingEvidence() {
        let now = Date()
        let prior = RuntimeObservation(runtime: .ollama, observedAt: now,
                                      models: [LocalModelObservation(id: "synthetic", residency: .loaded)])
        let stale = ActivityTelemetry.retainingRecent(runtimes: [], previous: [prior], now: now.addingTimeInterval(20))
        XCTAssertEqual(stale, [prior]); XCTAssertFalse(stale[0].isFresh(at: now.addingTimeInterval(20)))
        XCTAssertTrue(ActivityTelemetry.retainingRecent(runtimes: [], previous: [prior], now: now.addingTimeInterval(60)).isEmpty)
        let empty = RuntimeObservation(runtime: .ollama, observedAt: now.addingTimeInterval(5), models: [])
        XCTAssertEqual(ActivityTelemetry.retainingRecent(runtimes: [empty], previous: [prior], now: now.addingTimeInterval(5)), [empty])
    }

    func testOllamaResidencyNeverImpliesInferenceAndOnlyVRAMIsMemory() async throws {
        let now = Date()
        let observer = LocalRuntimeObserver(fetch: { endpoint in
            switch endpoint {
            case .ollamaVersion: return response(#"{"version":"0.12.6"}"#)
            case .ollamaModels: return response(#"{"models":[{"model":"synthetic:7b","size":999,"size_vram":4096,"context_length":8192,"expires_at":"2099-01-01T00:00:00Z"},{"name":"cpu-only","size":123},{"name":"remote","remote_host":"https://example.invalid"}]}"#)
            default: throw NativeOperationError.unavailable
            }
        })
        let result = await observer.observe(now: now)
        let runtime = try XCTUnwrap(result.first)
        XCTAssertEqual(runtime.runtime, .ollama); XCTAssertEqual(runtime.version, "0.12.6")
        XCTAssertEqual(runtime.models.count, 2)
        XCTAssertEqual(runtime.models[0].residency, .loaded)
        XCTAssertEqual(runtime.models[0].memoryBytes, 4096)
        XCTAssertEqual(runtime.models[0].contextTokens, 8192)
        XCTAssertNil(runtime.models[1].memoryBytes)
        XCTAssertTrue(runtime.models.allSatisfy { $0.activity == .unknown && $0.inferenceExpiresAt == nil && $0.tokensPerSecond == nil && $0.startedAt == nil })
    }

    func testLMStudioLoadedInstancesAndContextDoNotUseDiskSize() async throws {
        let observer = LocalRuntimeObserver(fetch: { endpoint in
            guard endpoint == .lmStudioModels else { throw NativeOperationError.unavailable }
            return response(#"{"models":[{"key":"synthetic/loaded","display_name":"Synthetic Loaded","size_bytes":9000,"max_context_length":100000,"loaded_instances":[{"id":"private-instance","config":{"context_length":4096}}]},{"key":"synthetic/available","size_bytes":8000,"loaded_instances":[]}]}"#)
        })
        let result = await observer.observe(now: Date())
        let runtime = try XCTUnwrap(result.first)
        XCTAssertEqual(runtime.runtime, .lmStudio)
        XCTAssertEqual(runtime.models.map(\.residency), [.loaded, .available])
        XCTAssertEqual(runtime.models[0].contextTokens, 4096)
        XCTAssertEqual(runtime.models[0].name, "Synthetic Loaded")
        XCTAssertTrue(runtime.models.allSatisfy { $0.memoryBytes == nil && $0.activity == .unknown })
    }

    func testLlamaInventoryRequiresIdentityAndIgnoresPromptsPathsAndArguments() async throws {
        let observer = LocalRuntimeObserver(fetch: { endpoint in
            guard endpoint == .llamaModels else { throw NativeOperationError.unavailable }
            return response(#"{"data":[{"id":"synthetic","status":{"value":"loaded","args":["private arguments"]},"path":"/Users/private/model","prompt":"private prompt"},{"id":"sleeping","status":{"value":"sleeping"}},{"id":"/Users/private/model","status":{"value":"loaded"}}]}"#, server: "llama.cpp")
        })
        let result = await observer.observe(now: Date())
        let runtime = try XCTUnwrap(result.first)
        XCTAssertEqual(runtime.models.map(\.id), ["synthetic", "sleeping"])
        XCTAssertEqual(runtime.models.map(\.residency), [.loaded, .available])
        XCTAssertTrue(runtime.models.allSatisfy { $0.activity == .unknown })
        let wrongServer = LocalRuntimeObserver(fetch: { _ in response(#"{"data":[{"id":"synthetic"}]}"#, server: "Other") })
        let rejected = await wrongServer.observe(now: Date())
        XCTAssertTrue(rejected.isEmpty)
    }

    func testMLXNeedsVerifiedListenerAndInventoryIsNotLoaded() async throws {
        let requests = Counter()
        let observer = LocalRuntimeObserver(fetch: { endpoint in
            guard endpoint == .mlxModels else { throw NativeOperationError.unavailable }
            _ = requests.increment()
            return response(#"{"data":[{"id":"synthetic/mlx"},{"id":"/Users/private/model"}]}"#)
        })
        let unverified = await observer.observe(now: Date())
        XCTAssertTrue(unverified.isEmpty); XCTAssertEqual(requests.get(), 0)
        let verified = await observer.observe(now: Date(), mlxListenerVerified: true)
        let runtime = try XCTUnwrap(verified.first)
        XCTAssertEqual(runtime.runtime, .mlx); XCTAssertEqual(runtime.models.count, 1)
        XCTAssertEqual(runtime.models[0].residency, .available)
        XCTAssertEqual(runtime.models[0].activity, .unknown)
        XCTAssertFalse(ActivityTelemetry.mlxListenerVerified(listeners: "p100", processes: "100 1 /usr/bin/python3"))
        XCTAssertTrue(ActivityTelemetry.mlxListenerVerified(listeners: "p100", processes: "100 1 /bin/mlx_lm.server"))
        XCTAssertFalse(ActivityTelemetry.mlxListenerVerified(listeners: "p100\np200", processes: "100 1 /bin/mlx_lm.server"))
    }

    func testMalformedOversizedUnauthorizedAndTimeoutResponsesFailClosed() async {
        for bad in [response("{"), response("[]"), response(#"{"models":[]}"#, status: 401),
                    RuntimeHTTPResponse(status: 200, body: Data(repeating: 32, count: RuntimeHTTPRequest.maximumBytes + 1))] {
            let observer = LocalRuntimeObserver(fetch: { _ in bad })
            let result = await observer.observe(now: Date())
            XCTAssertTrue(result.isEmpty)
        }
        let observer = LocalRuntimeObserver(fetch: { _ in throw NativeOperationError.timedOut })
        let result = await observer.observe(now: Date())
        XCTAssertTrue(result.isEmpty)
        XCTAssertNil(LocalRuntimeObserver.positiveInt(true))
        XCTAssertNil(LocalRuntimeObserver.positiveInt(2.5))
        XCTAssertNil(LocalRuntimeObserver.modelID("private\ntext"))
        XCTAssertNil(LocalRuntimeObserver.modelID("../private"))
    }

    func testRuntimeRecordLimitAndEndpointAllowlist() async throws {
        let rows = (0..<100).map { #"{"key":"synthetic-\#($0)","loaded_instances":[]}"# }.joined(separator: ",")
        let body = response("{\"models\":[\(rows)]}")
        let observer = LocalRuntimeObserver(fetch: { endpoint in
            guard endpoint == .lmStudioModels else { throw NativeOperationError.unavailable }
            return body
        })
        let result = await observer.observe(now: Date())
        XCTAssertEqual(result.first?.models.count, RuntimeObservation.maximumModels)
        for endpoint in RuntimeEndpoint.allCases {
            XCTAssertEqual(endpoint.url.scheme, "http"); XCTAssertEqual(endpoint.url.host, "127.0.0.1")
            XCTAssertNil(endpoint.url.query); XCTAssertNil(endpoint.url.user); XCTAssertNil(endpoint.url.password)
            XCTAssertTrue([11434, 1234, 8080].contains(endpoint.url.port!))
        }
    }

    func testTransportStreamsWithLimitTimeoutAndNoCredentials() async throws {
        SyntheticRuntimeProtocol.configure(.success)
        let success = try await RuntimeHTTPRequest(protocolClasses: [SyntheticRuntimeProtocol.self]).fetch(.ollamaVersion)
        XCTAssertEqual(success.status, 200)
        XCTAssertEqual(success.server, "synthetic")
        let request = try XCTUnwrap(SyntheticRuntimeProtocol.request())
        XCTAssertEqual(request.url, RuntimeEndpoint.ollamaVersion.url)
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertNil(request.httpBody)
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
        XCTAssertNil(request.value(forHTTPHeaderField: "Cookie"))
        SyntheticRuntimeProtocol.configure(.oversized)
        do {
            _ = try await RuntimeHTTPRequest(protocolClasses: [SyntheticRuntimeProtocol.self]).fetch(.ollamaModels)
            XCTFail("An oversized streaming body must fail")
        } catch {}
        SyntheticRuntimeProtocol.configure(.silent)
        let started = Date()
        do {
            _ = try await RuntimeHTTPRequest(protocolClasses: [SyntheticRuntimeProtocol.self]).fetch(.ollamaModels)
            XCTFail("A silent response must time out")
        } catch {}
        XCTAssertLessThan(Date().timeIntervalSince(started), 2)
    }

    func testTransportRejectsRedirect() {
        let operation = RuntimeHTTPRequest()
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let task = session.dataTask(with: RuntimeEndpoint.ollamaVersion.url)
        let redirect = HTTPURLResponse(url: RuntimeEndpoint.ollamaVersion.url, statusCode: 302, httpVersion: "HTTP/1.1", headerFields: ["Location": "https://example.invalid/"])!
        var called = false
        operation.urlSession(session, task: task, willPerformHTTPRedirection: redirect,
                             newRequest: URLRequest(url: URL(string: "https://example.invalid/")!)) { redirected in
            called = true; XCTAssertNil(redirected)
        }
        XCTAssertTrue(called)
    }

    func testAgentStartsCheckingAndCoalescesHangingObservationWithoutBlocking() async {
        let gate = DispatchSemaphore(value: 0), calls = Counter()
        let monitor = AgentActivityMonitor(probe: {
            _ = calls.increment(); gate.wait()
            return AgentProbe(processes: "100 1 /usr/local/bin/codex\n200 1 /bin/zsh", assertions: "", network: "")
        })
        let now = Date(), started = Date()
        let first = await monitor.snapshot(now: now)
        let second = await monitor.snapshot(now: now.addingTimeInterval(5))
        XCTAssertEqual(first, .checking); XCTAssertEqual(second, .checking)
        XCTAssertLessThan(Date().timeIntervalSince(started), 0.5)
        gate.signal()
        var observed: AgentObservation = .checking
        for _ in 0..<1000 {
            observed = await monitor.snapshot(now: now)
            if observed != .checking { break }
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTAssertEqual(observed, .idle); XCTAssertEqual(calls.get(), 1)
        let stale = await monitor.snapshot(now: now.addingTimeInterval(16))
        XCTAssertEqual(stale, .checking)
        gate.signal()
    }

    func testPausedAgentMonitorSkipsProbesAndDiscardsAnInflightResult() async {
        let calls = Counter(), gate = DispatchSemaphore(value: 0)
        let monitor = AgentActivityMonitor(probe: {
            let first = calls.increment() == 1
            if first { gate.wait() }
            return AgentProbe(processes: "", assertions: first ? "pid 123(Claude): PreventSystemSleep named" : "", network: "")
        })
        let now = Date()
        _ = await monitor.snapshot(enabled: false, now: now)
        XCTAssertEqual(calls.get(), 0)
        _ = await monitor.snapshot(now: now)
        _ = await monitor.snapshot(enabled: false, now: now)
        gate.signal()
        var resumed = AgentObservation.checking
        for _ in 0..<1000 {
            resumed = await monitor.snapshot(now: now)
            if resumed != .checking { break }
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTAssertEqual(resumed, .idle)
        XCTAssertEqual(calls.get(), 2)
    }

    func testAgentFailedObservationDoesNotBecomeIdle() async {
        let calls = Counter()
        let monitor = AgentActivityMonitor(probe: { _ = calls.increment(); return nil })
        let now = Date()
        _ = await monitor.snapshot(now: now)
        for _ in 0..<100 {
            if calls.get() > 0 { break }
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        let result = await monitor.snapshot(now: now)
        XCTAssertEqual(result, .checking); XCTAssertEqual(calls.get(), 1)
    }

    func testTelemetryReturnsImmediatelyAndCoalescesSlowRuntime() async {
        let gate = DispatchSemaphore(value: 0), calls = Counter()
        let telemetry = ActivityTelemetry(runtimeObserver: LocalRuntimeObserver(fetch: { _ in throw NativeOperationError.unavailable }), metrics: {
            _ = calls.increment(); gate.wait(); return (nil, 42)
        }, mlxIdentity: { false })
        let now = Date(), start = Date()
        let first = await telemetry.snapshot(now: now)
        let second = await telemetry.snapshot(now: now.addingTimeInterval(5))
        XCTAssertNil(first.gpuPercent); XCTAssertNil(second.gpuPercent)
        XCTAssertLessThan(Date().timeIntervalSince(start), 0.5)
        gate.signal()
        var observed = ActivityObservation()
        for _ in 0..<1000 {
            observed = await telemetry.snapshot(now: now)
            if observed.gpuPercent != nil { break }
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTAssertEqual(observed.gpuPercent, 42); XCTAssertEqual(calls.get(), 1)
        let stale = await telemetry.snapshot(now: now.addingTimeInterval(16))
        XCTAssertNil(stale.gpuPercent)
        gate.signal()
    }
}
