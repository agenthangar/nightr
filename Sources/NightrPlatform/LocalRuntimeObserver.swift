import Foundation
import CoreFoundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if os(macOS)
import Security
#endif
import NightrCore

/// The allowlist is deliberately closed: no configured URLs, discovery scan,
/// credentials, redirects, model operations or inference requests.
enum RuntimeEndpoint: CaseIterable, Sendable {
    case ollamaVersion, ollamaModels, lmStudioModels, llamaModels, mlxModels
    var url: URL {
        let location: (Int, String)
        switch self {
        case .ollamaVersion: location = (11434, "/api/version")
        case .ollamaModels: location = (11434, "/api/ps")
        case .lmStudioModels: location = (1234, "/api/v1/models")
        case .llamaModels: location = (8080, "/models")
        case .mlxModels: location = (8080, "/v1/models")
        }
        return URL(string: "http://127.0.0.1:\(location.0)\(location.1)")!
    }
}

struct RuntimeHTTPResponse: Sendable {
    var status: Int
    var server: String?
    var body: Data
}

/// Streaming byte limit and a wall-clock deadline also bound chunked responses.
/// Each request owns its session; failures never log response bodies or auth state.
final class RuntimeHTTPRequest: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    static let maximumBytes = 256 * 1024
    static let timeout: TimeInterval = 0.8
    private let lock = NSLock()
    private var continuation: CheckedContinuation<RuntimeHTTPResponse, Error>?
    private var session: URLSession?
    private var task: URLSessionDataTask?
    private var response: HTTPURLResponse?
    private var body = Data()
    private var finished = false
    private let protocolClasses: [AnyClass]

    init(protocolClasses: [AnyClass] = []) { self.protocolClasses = protocolClasses }

    func fetch(_ endpoint: RuntimeEndpoint) async throws -> RuntimeHTTPResponse {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                lock.lock()
                guard !finished else { lock.unlock(); continuation.resume(throwing: NativeOperationError.cancelled); return }
                self.continuation = continuation
                let configuration = URLSessionConfiguration.ephemeral
                if !protocolClasses.isEmpty { configuration.protocolClasses = protocolClasses }
                configuration.timeoutIntervalForRequest = Self.timeout
                configuration.timeoutIntervalForResource = Self.timeout
                configuration.httpCookieStorage = nil
                configuration.urlCredentialStorage = nil
                configuration.urlCache = nil
                configuration.connectionProxyDictionary = [:]
                configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
                let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
                var request = URLRequest(url: endpoint.url)
                request.httpMethod = "GET"
                request.setValue("application/json", forHTTPHeaderField: "Accept")
                self.session = session
                let task = session.dataTask(with: request); self.task = task
                lock.unlock()
                task.resume()
                DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + Self.timeout) { [weak self] in
                    self?.finish(.failure(NativeOperationError.timedOut))
                }
            }
        } onCancel: { self.finish(.failure(NativeOperationError.cancelled)) }
    }
    private func finish(_ result: Result<RuntimeHTTPResponse, Error>) {
        lock.lock()
        guard !finished else { lock.unlock(); return }
        finished = true
        let continuation = self.continuation, session = self.session
        self.continuation = nil; self.session = nil; task = nil
        lock.unlock()
        session?.invalidateAndCancel()
        continuation?.resume(with: result)
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
    func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        completionHandler(.cancelAuthenticationChallenge, nil)
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let http = response as? HTTPURLResponse, http.url == dataTask.originalRequest?.url,
              response.expectedContentLength <= Self.maximumBytes else {
            completionHandler(.cancel); finish(.failure(NativeOperationError.malformed)); return
        }
        lock.lock(); self.response = http; lock.unlock()
        completionHandler(.allow)
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.lock()
        let exceeds = data.count > Self.maximumBytes - body.count
        if !exceeds { body.append(data) }
        lock.unlock()
        if exceeds { finish(.failure(NativeOperationError.malformed)) }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock(); let response = self.response, body = self.body; lock.unlock()
        if let error { finish(.failure(error)) }
        else if let response {
            finish(.success(RuntimeHTTPResponse(status: response.statusCode, server: response.value(forHTTPHeaderField: "Server"), body: body)))
        } else { finish(.failure(NativeOperationError.malformed)) }
    }
}

struct LocalRuntimeObserver: Sendable {
    typealias Fetch = @Sendable (RuntimeEndpoint) async throws -> RuntimeHTTPResponse
    var fetch: Fetch = { try await RuntimeHTTPRequest().fetch($0) }
    var lmStudioProcesses: @Sendable () async -> Data? = { await LMStudioProcesses.read() }

    func observe(now: Date, mlxListenerVerified: Bool = false) async -> [RuntimeObservation] {
        await withTaskGroup(of: RuntimeObservation?.self) { group in
            group.addTask { await ollama(now: now) }
            group.addTask { await models(.lmStudioModels, runtime: .lmStudio, now: now) }
            // Port 8080 is shared by many servers. MLX needs independently
            // verified listener ownership; llama.cpp has its own server header.
            group.addTask { await models(mlxListenerVerified ? .mlxModels : .llamaModels,
                                         runtime: mlxListenerVerified ? .mlx : .llamaCPP, now: now) }
            var observations: [RuntimeObservation] = []
            for await observation in group { if let observation { observations.append(observation) } }
            return LocalRuntime.allCases.compactMap { runtime in observations.first { $0.runtime == runtime } }
        }
    }
    private func ollama(now: Date) async -> RuntimeObservation? {
        guard let versionResponse = try? await fetch(.ollamaVersion),
              let versionObject = Self.object(versionResponse), let version = Self.label(versionObject["version"]),
              version.range(of: #"^[0-9]+\.[0-9]+\.[0-9]+(?:[-+][A-Za-z0-9.-]+)?$"#, options: .regularExpression) != nil,
              let response = try? await fetch(.ollamaModels), let object = Self.object(response),
              let rows = object["models"] as? [[String: Any]] else { return nil }
        let models = rows.prefix(RuntimeObservation.maximumModels).compactMap { row -> LocalModelObservation? in
            guard row["remote_host"] == nil, row["remote_model"] == nil else { return nil }
            guard let id = Self.modelID(row["model"] ?? row["name"]) else { return nil }
            // expires_at is an unload deadline, not inference evidence. size
            // is not reliably resident memory; size_vram is explicitly VRAM.
            return LocalModelObservation(id: id, residency: .loaded, contextTokens: Self.positiveInt(row["context_length"]),
                                         memoryBytes: Self.positiveInt64(row["size_vram"]))
        }
        return RuntimeObservation(runtime: .ollama, version: version, observedAt: now, models: models)
    }
    private func models(_ endpoint: RuntimeEndpoint, runtime: LocalRuntime, now: Date) async -> RuntimeObservation? {
        guard let response = try? await fetch(endpoint), let object = Self.object(response) else { return nil }
        if runtime == .llamaCPP && response.server != "llama.cpp" { return nil }
        guard let rows = object[runtime == .lmStudio ? "models" : "data"] as? [[String: Any]] else { return nil }
        // Native LM Studio's required loaded_instances distinguishes its API
        // from generic OpenAI lists. Never use size_bytes as resident memory.
        if runtime == .lmStudio && rows.contains(where: { $0["loaded_instances"] as? [[String: Any]] == nil }) { return nil }
        let sortedRows = runtime == .lmStudio ? rows.filter(Self.lmStudioLoaded) + rows.filter { !Self.lmStudioLoaded($0) } : rows
        var models = sortedRows.prefix(RuntimeObservation.maximumModels).compactMap { row -> LocalModelObservation? in
            guard let id = Self.modelID(row[runtime == .lmStudio ? "key" : "id"]) else { return nil }
            var residency: ModelResidency = .available
            var context: Int?
            if runtime == .lmStudio {
                let instances = row["loaded_instances"] as? [[String: Any]] ?? []
                residency = instances.isEmpty ? .available : .loaded
                context = (instances.first?["config"] as? [String: Any]).flatMap { Self.positiveInt($0["context_length"]) }
            } else if runtime == .llamaCPP {
                let status = (row["status"] as? [String: Any])?["value"] as? String
                residency = status == "loaded" ? .loaded : (["unloaded", "sleeping"].contains(status ?? "") ? .available : .unknown)
            }
            return LocalModelObservation(id: id, name: runtime == .lmStudio ? Self.modelID(row["display_name"]) : nil,
                                         residency: residency, contextTokens: context)
        }
        if runtime == .lmStudio, models.contains(where: { $0.residency == .loaded }),
           let data = await lmStudioProcesses() {
            LMStudioProcesses.apply(data, to: &models, observedAt: now)
        }
        return RuntimeObservation(runtime: runtime, observedAt: now, models: models)
    }
    private static func lmStudioLoaded(_ row: [String: Any]) -> Bool {
        (row["loaded_instances"] as? [[String: Any]])?.isEmpty == false
    }
    static func object(_ response: RuntimeHTTPResponse) -> [String: Any]? {
        guard response.status == 200, response.body.count <= RuntimeHTTPRequest.maximumBytes else { return nil }
        return (try? JSONSerialization.jsonObject(with: response.body)) as? [String: Any]
    }
    static func label(_ value: Any?) -> String? {
        guard let value = value as? String, !value.isEmpty, value.utf8.count <= 160,
              !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else { return nil }
        return value
    }
    static func modelID(_ value: Any?) -> String? {
        guard let id = label(value), !id.hasPrefix("/"), !id.hasPrefix("~"), !id.contains("://"),
              !id.contains("\\"), !id.split(separator: "/").contains("..") else { return nil }
        return id
    }
    static func positiveInt64(_ value: Any?) -> Int64? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue.isFinite, number.doubleValue > 0, number.doubleValue < Double(Int64.max),
              number.doubleValue.rounded(.towardZero) == number.doubleValue else { return nil }
        return number.int64Value
    }
    static func positiveInt(_ value: Any?) -> Int? { positiveInt64(value).flatMap(Int.init(exactly:)) }
}

/// Use the vendor's read-only listing against the server already observed on
/// loopback. Explicit host and port disable CLI discovery and server startup.
private enum LMStudioProcesses {
    static func read() async -> Data? {
        #if os(macOS)
        return await Task.detached(priority: .utility) {
            let binary = URL(fileURLWithPath: "/Applications/LM Studio.app/Contents/Resources/app/.webpack/lms")
            var code: SecStaticCode?
            var requirement: SecRequirement?
            let expression = #"anchor apple generic and identifier "lms" and certificate leaf[subject.OU] = "D65G88RHWN""#
            guard SecStaticCodeCreateWithPath(binary as CFURL, [], &code) == errSecSuccess, let code,
                  SecRequirementCreateWithString(expression as CFString, [], &requirement) == errSecSuccess,
                  let requirement,
                  SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSStrictValidate), requirement) == errSecSuccess else { return nil }
            return try? BoundedProcess().run(executable: binary, arguments: ["ps", "--json", "--host", "127.0.0.1", "--port", "1234"],
                                             timeout: 1.5, environment: ["PATH": "/usr/bin:/bin", "NO_COLOR": "1"])
        }.value
        #else
        return nil
        #endif
    }

    static func apply(_ data: Data, to models: inout [LocalModelObservation], observedAt: Date) {
        guard data.count <= RuntimeHTTPRequest.maximumBytes,
              let rows = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else { return }
        let rank: [String: Int] = ["idle": 1, "processingPrompt": 2, "generating": 3]
        let activity: [ModelActivity] = [.unknown, .idle, .processing, .generating]
        var states: [String: Int] = [:]
        for row in rows {
            guard row["type"] as? String == "llm", row["deviceIdentifier"] is NSNull,
                  let key = LocalRuntimeObserver.modelID(row["modelKey"]),
                  let status = row["status"] as? String else { continue }
            states[key] = max(states[key, default: 0], rank[status, default: 0])
        }
        for i in models.indices where models[i].residency == .loaded {
            let observed = activity[states[models[i].id, default: 0]]
            models[i].activity = observed
            if observed.isInference {
                models[i].inferenceExpiresAt = observedAt.addingTimeInterval(RuntimeObservation.freshness)
            }
        }
    }
}
