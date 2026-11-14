import Foundation

public enum PMSetSettings {
    /// `pmset -g` exposes the global `disablesleep` mutation as `SleepDisabled`.
    /// Reject missing, malformed or duplicate observations rather than guessing.
    public static func sleepDisabled(in output: String) throws -> Int {
        let matches = output.split(separator: "\n").compactMap { line -> [Substring]? in
            let fields = line.split(whereSeparator: { $0.isWhitespace })
            return fields.first == "SleepDisabled" ? fields : nil
        }
        guard matches.count == 1, matches[0].count == 2,
              let value = Int(matches[0][1]), value == 0 || value == 1 else {
            throw PowerError.externalChange
        }
        return value
    }
}
