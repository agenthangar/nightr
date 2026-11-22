import Foundation

/// Released foreground options, including grouped compatibility switches.
public enum CLIOptions {
    public static func applying(_ arguments: [String], to original: Settings) throws -> Settings {
        var result = original
        var args: [String] = []
        for arg in arguments {
            if arg.hasPrefix("-") && !arg.hasPrefix("--") && arg.count > 2 && arg != "-dim" {
                var group = String(arg.dropFirst())
                while !group.isEmpty {
                    let flag = group.removeFirst()
                    if "dlc".contains(flag) && group.hasPrefix("=") { args.append("-" + String(flag) + group); break }
                    args.append("-" + String(flag))
                    if "egrb".contains(flag) {
                        if !group.isEmpty { args.append(group) }
                        break
                    }
                }
            } else { args.append(arg) }
        }
        var i = 0
        var dimRequested = false
        while i < args.count {
            let parts = args[i].split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
            let key = parts[0]
            func value() throws -> String {
                if parts.count == 2 { return parts[1] }
                guard i + 1 < args.count else { throw SettingsError.invalid("\(key) requires a value") }
                i += 1; return args[i]
            }
            func number() throws -> Int {
                let text = try value()
                guard !text.isEmpty, text.allSatisfy({ $0.isASCII && $0.isNumber }), let n = Int(text) else { throw SettingsError.invalid("\(key) requires an integer") }
                return n
            }
            func boolean() throws -> Bool {
                switch try value() { case "on": return true; case "off": return false
                default: throw SettingsError.invalid("\(key) takes on or off") }
            }
            switch key {
            case "-f", "--forever", "-C", "--no-checks": result.forever = true
            case "-F", "--no-forever": result.forever = false
            case "-a", "--agent": result.agent = true
            case "-A", "--no-agent": result.agent = false
            case "-i", "--internet": result.internet = true
            case "-I", "--no-internet": result.internet = false
            case "-c", "--checks":
                let mode = parts.count == 1 && (i + 1 == args.count || args[i + 1].hasPrefix("-")) ? "all" : try value()
                result.forever = false
                switch mode {
                case "all": result.agent = true; result.internet = true
                case "agent": result.agent = true; result.internet = false; result.forever = false
                case "internet": result.agent = false; result.internet = true; result.forever = false
                case "none": result.agent = false; result.internet = false
                default: throw SettingsError.invalid("--checks takes all, agent, internet, or none")
                }
            case "-d", "--display":
                if key == "-d" && parts.count == 1 && (i + 1 == args.count || args[i + 1].hasPrefix("-")) { result.displayOn = true; i += 1; continue }
                switch try value() {
                case "off": result.displayOn = false; result.dim = false
                case "on": result.displayOn = true; result.dim = false
                case "dim": result.displayOn = true; result.dim = true
                default: throw SettingsError.invalid("--display takes off, on, or dim")
                }
                dimRequested = false
            case "--display-on": result.displayOn = true
            case "-m", "--dim", "-dim": dimRequested = true
            case "-M", "--undim": result.dim = false
            case "-D", "--display-off", "--no-dim": result.displayOn = false; result.dim = false
            case "-L", "--no-lock": result.lock = false
            case "-l", "--lock":
                if parts.count == 1 && (i + 1 == args.count || args[i + 1].hasPrefix("-")) { result.lock = true }
                else { result.lock = try boolean() }
            case "--require":
                let text = try value()
                if text == "all" { result.requirement = .all }
                else if text == "none" { result.requirement = .none }
                else if let n = Int(text), n > 0 { result.requirement = .count(n) }
                else { throw SettingsError.invalid("--require takes all, none, or a positive count") }
            case "-g", "--grace": result.grace = try number()
            case "-e", "--every": result.every = try number()
            case "-r", "--retries": result.retries = try number()
            case "-b", "--backoff": result.backoff = try number()
            case "--local-inference": result.localInference = try boolean()
            case "--hotspot": result.hotspot = try boolean()
            case "--inactivity": result.inactivity = try number()
            default: throw SettingsError.invalid("unknown option: \(args[i])")
            }
            i += 1
        }
        if dimRequested { result.dim = true; result.displayOn = true }
        if case .count(let count) = result.requirement, count > [result.agent, result.internet].filter({ $0 }).count, !result.forever {
            throw SettingsError.invalid("--require exceeds the number of enabled checks")
        }
        try result.validate(); return result
    }
}
