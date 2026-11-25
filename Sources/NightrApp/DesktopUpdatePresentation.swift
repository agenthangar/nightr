#if os(macOS)
import Foundation

struct DesktopUpdatePresentation {
    enum Phase: Equatable {
        case idle, checking, downloading, ready(String), current, offline, unpublished, failed(String), opening

        var busy: Bool { self == .checking || self == .downloading || self == .opening }
        var readyVersion: String? {
            if case let .ready(version) = self { return version }
            return nil
        }
        var detail: String? {
            if case let .failed(message) = self { return message }
            return nil
        }
        var label: String {
            switch self {
            case .idle: "Not checked yet"
            case .checking: "Checking…"
            case .downloading: "Downloading…"
            case .ready: "Update Ready"
            case .current: "Up to date"
            case .offline: "Couldn’t connect"
            case .unpublished: "No published release"
            case .failed: "Couldn’t prepare update"
            case .opening: "Opening Terminal…"
            }
        }
    }

    let version: String
    let build: String?
    var phase: Phase = .idle
    var supported = true
    static let sample = Self(version: "0.1.0", build: "8a41c2d")
}
#endif
