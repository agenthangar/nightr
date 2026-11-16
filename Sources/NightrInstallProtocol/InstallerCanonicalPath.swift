#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// Filesystem identity paths must retain POSIX spelling. Foundation may turn
/// /private/tmp back into the /tmp symlink while resolving or deleting parents.
public struct InstallerCanonicalPath {
    public let path: String
    public init(_ source: String) throws {
        guard source.hasPrefix("/"), !source.utf8.contains(0), let resolved = realpath(source, nil) else {
            throw InstallGuardError.unsafeFile
        }
        defer { free(resolved) }
        path = String(cString: resolved)
    }
    public var directory: String { Self.parent(path) }
    public var ancestors: [String] {
        var result: [String] = [], current = path
        while current != "/" {
            result.append(current)
            current = Self.parent(current)
        }
        return result
    }
    private static func parent(_ path: String) -> String {
        guard let slash = path.lastIndex(of: "/"), slash != path.startIndex else { return "/" }
        return String(path[..<slash])
    }
}
