import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

public enum FixedCommandLink {
    public static func validate(atPath path: String, canonicalTarget: String) throws {
        var info = stat()
        if lstat(path, &info) != 0 {
            if errno == ENOENT { return }
            throw InstallGuardError.unsafeFile
        }
        guard info.st_mode & S_IFMT == S_IFLNK,
              try FileManager.default.destinationOfSymbolicLink(atPath: path) == canonicalTarget else {
            throw InstallGuardError.unrelatedCommand
        }
    }
}
