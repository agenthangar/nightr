import Foundation

/// Private metadata only: no prompts, paths, caller timestamps, or caller expiry.
/// Producers begin once, renew every five seconds, and end on completion. The
/// controller grants at most 15 seconds from monotonic receipt time.
public struct InferenceMetadata: Codable, Equatable, Sendable {
    public var runtime: LocalRuntime
    public var model: String
    public var activity: ModelActivity
    public init(runtime: LocalRuntime, model: String, activity: ModelActivity = .generating) {
        self.runtime = runtime; self.model = model; self.activity = activity
    }
    public func validate() throws {
        guard (1...128).contains(model.utf8.count),
              !model.unicodeScalars.contains(where: { $0.properties.generalCategory == .control || $0.properties.isWhitespace }),
              !model.hasPrefix("/"), !model.hasPrefix("~"), !model.contains("\\"), !model.contains("://"),
              !["file:", "http:", "https:", "ftp:", "ssh:", "mailto:", "data:"].contains(where: { model.lowercased().hasPrefix($0) }),
              model.components(separatedBy: "/").allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }),
              activity == .generating || activity == .processing else { throw IPCError.invalid("inference requires a bounded model identifier and active processing state") }
    }
}
