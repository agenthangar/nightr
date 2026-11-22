import Foundation

public enum AgentObservation: String, Codable, Sendable {
    case checking, active, idle
}

public enum LocalRuntime: String, Codable, CaseIterable, Sendable {
    case ollama, lmStudio = "lm-studio", llamaCPP = "llama.cpp", mlx

    public var displayName: String {
        switch self {
        case .ollama: return "Ollama"
        case .lmStudio: return "LM Studio"
        case .llamaCPP: return "llama.cpp"
        case .mlx: return "MLX"
        }
    }
}

public enum ModelResidency: String, Codable, Sendable {
    case loaded, available, unknown
}

public enum ModelActivity: String, Codable, Sendable {
    case generating, processing, idle, unknown

    public var isInference: Bool { self == .generating || self == .processing }
}

public struct LocalModelObservation: Codable, Equatable, Sendable {
    public var id: String
    public var name: String?
    public var residency: ModelResidency
    public var activity: ModelActivity
    public var contextTokens: Int?
    public var memoryBytes: Int64?
    public var startedAt: Date?
    public var tokensPerSecond: Double?
    public var inferenceExpiresAt: Date?

    public init(id: String, name: String? = nil, residency: ModelResidency = .unknown,
                activity: ModelActivity = .unknown, contextTokens: Int? = nil, memoryBytes: Int64? = nil,
                startedAt: Date? = nil, tokensPerSecond: Double? = nil, inferenceExpiresAt: Date? = nil) {
        self.id = id
        self.name = name
        self.residency = residency
        self.activity = activity
        self.contextTokens = contextTokens
        self.memoryBytes = memoryBytes
        self.startedAt = startedAt
        self.tokensPerSecond = tokensPerSecond
        self.inferenceExpiresAt = inferenceExpiresAt
    }

    public var displayName: String { name ?? id }

    public func observedActivity(at now: Date) -> ModelActivity {
        guard activity.isInference else { return activity }
        guard let inferenceExpiresAt, inferenceExpiresAt > now else { return .unknown }
        return activity
    }
}

public struct RuntimeObservation: Codable, Equatable, Sendable {
    public static let freshness: TimeInterval = 15
    public static let maximumModels = 16

    public var runtime: LocalRuntime
    public var version: String?
    public var observedAt: Date
    public var models: [LocalModelObservation]

    public init(runtime: LocalRuntime, version: String? = nil, observedAt: Date, models: [LocalModelObservation]) {
        self.runtime = runtime
        self.version = version
        self.observedAt = observedAt
        self.models = models
    }

    public func isFresh(at now: Date) -> Bool {
        let age = now.timeIntervalSince(observedAt)
        return age >= 0 && age < Self.freshness
    }
}

public struct ActivityObservation: Codable, Equatable, Sendable {
    public var cpuPercent: Int?
    public var gpuPercent: Int?
    public var runtimes: [RuntimeObservation]

    public init(cpuPercent: Int? = nil, gpuPercent: Int? = nil, runtimes: [RuntimeObservation] = []) {
        self.cpuPercent = cpuPercent
        self.gpuPercent = gpuPercent
        self.runtimes = runtimes
    }

    public func hasActiveInference(at now: Date) -> Bool {
        runtimes.contains { runtime in
            runtime.isFresh(at: now) && runtime.models.contains { model in
                guard let expiry = model.inferenceExpiresAt else { return false }
                return expiry.timeIntervalSince(runtime.observedAt) <= RuntimeObservation.freshness &&
                    model.observedActivity(at: now).isInference
            }
        }
    }
}
