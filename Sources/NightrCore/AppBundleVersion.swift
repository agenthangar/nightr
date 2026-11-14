import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// Read only bounded, regular bundle metadata; no app launch or setup is involved.
public enum AppBundleVersion {
    public static let maximumInfoBytes = 65_536
    public static func read(infoPlist: URL) -> String? {
        let fd = open(infoPlist.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
              info.st_size > 0, info.st_size <= off_t(maximumInfoBytes) else { return nil }
        var data = Data()
        var bytes = [UInt8](repeating: 0, count: 4096)
        while data.count <= maximumInfoBytes {
            let remaining = min(bytes.count, maximumInfoBytes + 1 - data.count)
#if canImport(Darwin)
            let count = Darwin.read(fd, &bytes, remaining)
#else
            let count = Glibc.read(fd, &bytes, remaining)
#endif
            if count < 0 && errno == EINTR { continue }
            guard count >= 0 else { return nil }
            if count == 0 { break }
            data.append(contentsOf: bytes.prefix(count))
        }
        guard data.count <= maximumInfoBytes,
              let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
              let dictionary = plist as? [String: Any],
              let version = dictionary["CFBundleShortVersionString"] as? String,
              version.range(of: "\\A[0-9]+\\.[0-9]+\\.[0-9]+\\z", options: .regularExpression) != nil else { return nil }
        return version
    }
}
