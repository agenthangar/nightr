import Foundation
import Darwin
import Security
import MachO
import NightrInstallProtocol

let statePath = "/Library/Application Support/Nightr"
let appPath = "/Applications/Nightr.app"
let guardPath = "/Library/PrivilegedHelperTools/ai.nightr.installguard"
let markerName = "install-transaction.json"
func require(_ condition: @autoclosure () throws -> Bool) throws {
    if try !condition() { throw InstallGuardError.unsafeFile }
}
func metadata(_ fd: Int32, uid: uid_t, mode: mode_t, directory: Bool = false) throws {
    var s = stat(); try require(fstat(fd, &s) == 0)
    try require(s.st_uid == uid && s.st_mode & 0o7777 == mode)
    try require(s.st_mode & S_IFMT == (directory ? S_IFDIR : S_IFREG))
    if !directory { try require(s.st_nlink == 1) }
}
func protectedPath(_ path: String, stop: String = "/") throws {
    var current = URL(fileURLWithPath: path)
    while current.path != stop {
        var s = stat(); try require(lstat(current.path, &s) == 0)
        try require(s.st_uid == 0 && s.st_mode & 0o022 == 0 && s.st_mode & S_IFMT != S_IFLNK)
        current.deleteLastPathComponent()
    }
}
func readBounded(_ fd: Int32) throws -> Data {
    var s = stat(); try require(fstat(fd, &s) == 0 && s.st_size > 0 && s.st_size <= 16384)
    var bytes = [UInt8](repeating: 0, count: Int(s.st_size))
    let n = bytes.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
    try require(n == bytes.count); return Data(bytes)
}
final class RootStore {
    let directory: Int32
    let serial: Int32
    init() throws {
        try protectedPath("/Library/Application Support")
        if mkdir(statePath, 0o755) != 0 && errno != EEXIST { throw InstallGuardError.systemFailure }
        directory = open(statePath, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        try require(directory >= 0); try metadata(directory, uid: 0, mode: 0o755, directory: true)
        serial = openat(directory, "installer-guard.lock", O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
        try require(serial >= 0); try metadata(serial, uid: 0, mode: 0o600)
        try require(flock(serial, LOCK_EX | LOCK_NB) == 0)
    }
    deinit { close(serial); close(directory) }
    func lockFile(_ name: String) throws -> Int32 {
        var fd = openat(directory, name, O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o666)
        if fd >= 0 { try require(fchmod(fd, 0o666) == 0 && fsync(fd) == 0 && fsync(directory) == 0) }
        else { try require(errno == EEXIST); fd = openat(directory, name, O_RDWR | O_NOFOLLOW | O_CLOEXEC) }
        try require(fd >= 0); try metadata(fd, uid: 0, mode: 0o666); return fd
    }
    func load() throws -> InstallMarker? {
        let fd = openat(directory, markerName, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        if fd < 0 && errno == ENOENT { return nil }
        try require(fd >= 0); defer { close(fd) }
        try metadata(fd, uid: 0, mode: 0o600)
        return try JSONDecoder().decode(InstallMarker.self, from: readBounded(fd))
    }
    func save(_ marker: InstallMarker, replacing generation: UUID?) throws {
        let existing = try load()
        try require(existing?.generation == generation)
        let temporary = ".install-" + UUID().uuidString
        let fd = openat(directory, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        try require(fd >= 0); defer { close(fd); unlinkat(directory, temporary, 0) }
        let data = try JSONEncoder().encode(marker)
        let written = data.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
        try require(written == data.count && fsync(fd) == 0)
        if generation == nil { try require(renameatx_np(directory, temporary, directory, markerName, UInt32(RENAME_EXCL)) == 0) }
        else { try require(renameat(directory, temporary, directory, markerName) == 0) }
        try require(fsync(directory) == 0)
    }
    func clear(_ generation: UUID) throws {
        try require(try load()?.generation == generation)
        try require(unlinkat(directory, markerName, 0) == 0 && fsync(directory) == 0)
    }
}
func processInfo(_ pid: Int32) throws -> proc_bsdinfo {
    var result = proc_bsdinfo()
    try require(proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &result, Int32(MemoryLayout<proc_bsdinfo>.size)) == Int32(MemoryLayout<proc_bsdinfo>.size))
    try require(result.pbi_pid == UInt32(pid)); return result
}
func lockOwner(_ fd: Int32) throws -> InstallOwner? {
    var query = Darwin.flock(l_start: 0, l_len: 0, l_pid: 0, l_type: Int16(F_WRLCK), l_whence: Int16(SEEK_SET))
    try require(fcntl(fd, F_GETLK, &query) == 0)
    if query.l_type == Int16(F_UNLCK) { return nil }
    try require(query.l_type == Int16(F_WRLCK) && query.l_start == 0 && query.l_len == 0 && query.l_pid > 0)
    let info = try processInfo(query.l_pid)
    return InstallOwner(pid: query.l_pid, uid: info.pbi_uid)
}
func exclusiveRecordLock(_ fd: Int32) throws {
    var query = Darwin.flock(l_start: 0, l_len: 0, l_pid: 0, l_type: Int16(F_WRLCK), l_whence: Int16(SEEK_SET))
    try require(fcntl(fd, F_SETLK, &query) == 0)
}
func managedControllerIsExclusive(_ fd: Int32) -> Bool {
    if flock(fd, LOCK_SH | LOCK_NB) == 0 { flock(fd, LOCK_UN); return false }
    return errno == EWOULDBLOCK || errno == EAGAIN
}
func privateRequest(_ owner: InstallOwner) throws -> InstallRequest {
    guard let record = getpwuid(owner.uid), let home = record.pointee.pw_dir else { throw InstallGuardError.ownerMismatch }
    let path = String(cString: home) + "/Library/Application Support/Nightr"
    let directory = open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
    try require(directory >= 0); defer { close(directory) }
    try metadata(directory, uid: owner.uid, mode: 0o700, directory: true)
    let fd = openat(directory, "install-request.json", O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
    try require(fd >= 0); defer { close(fd) }
    try metadata(fd, uid: owner.uid, mode: 0o600)
    let request = try JSONDecoder().decode(InstallRequest.self, from: readBounded(fd))
    try require(request.owner == owner); return request
}
func requirement(_ identifier: String) -> SecRequirement? {
    let expression = "anchor apple generic and identifier \"\(identifier)\" and certificate leaf[subject.OU] = \"\(BuildPolicy.teamID)\""
    var result: SecRequirement?
    guard SecRequirementCreateWithString(expression as CFString, [], &result) == errSecSuccess else { return nil }
    return result
}
func verifyStatic(_ path: String, identifier: String) throws {
    var code: SecStaticCode?
    try require(SecStaticCodeCreateWithPath(URL(fileURLWithPath: path) as CFURL, [], &code) == errSecSuccess)
    guard let code, let req = requirement(identifier) else { throw InstallGuardError.invalidSignature }
    try require(SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSStrictValidate), req) == errSecSuccess)
}
func verifySelf() throws {
    try require(InstallPolicy.validTeam(BuildPolicy.teamID) && InstallPolicy.validVersion(BuildPolicy.version))
    var code: SecCode?
    try require(SecCodeCopySelf([], &code) == errSecSuccess)
    guard let code, let req = requirement("ai.nightr.installguard") else { throw InstallGuardError.invalidSignature }
    try require(SecCodeCheckValidity(code, [], req) == errSecSuccess)
}
func executablePath(_ pid: Int32) throws -> String {
    var bytes = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
    try require(proc_pidpath(pid, &bytes, UInt32(bytes.count)) > 0); return String(cString: bytes)
}
/// Bind both script stages to the same kernel-identified Apple PackageKit
/// invocation. Start fields are exact identity, never elapsed-time heuristics.
func installerInvocation() throws -> String {
    var pid = getppid()
    for _ in 0..<12 {
        let info = try processInfo(pid)
        let path = try executablePath(pid)
        if path.hasSuffix("/package_script_service") || path == "/System/Library/PrivateFrameworks/PackageKit.framework/Resources/installd" || path == "/System/Library/PrivateFrameworks/PackageKit.framework/Resources/system_installd" {
            var code: SecCode?; var req: SecRequirement?
            let attributes = [kSecGuestAttributePid as String: NSNumber(value: pid)] as CFDictionary
            try require(SecCodeCopyGuestWithAttributes(nil, attributes, [], &code) == errSecSuccess)
            try require(SecRequirementCreateWithString("anchor apple" as CFString, [], &req) == errSecSuccess)
            guard let code, let req else { throw InstallGuardError.invalidSignature }
            try require(SecCodeCheckValidity(code, [], req) == errSecSuccess && info.pbi_uid == 0)
            return "\(pid):\(info.pbi_start_tvsec):\(info.pbi_start_tvusec):\(path)"
        }
        try require(info.pbi_ppid > 1 && info.pbi_ppid != UInt32(pid)); pid = Int32(info.pbi_ppid)
    }
    throw InstallGuardError.invalidSignature
}
func run(_ executable: String, _ arguments: [String]) throws -> Data {
    let process = Process(); process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments; process.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LC_ALL": "C"]
    let pipe = Pipe(); process.standardOutput = pipe; process.standardError = FileHandle.nullDevice
    let done = DispatchSemaphore(value: 0); process.terminationHandler = { _ in done.signal() }
    try process.run()
    if done.wait(timeout: .now() + 15) == .timedOut { kill(process.processIdentifier, SIGKILL); process.waitUntilExit(); throw InstallGuardError.systemFailure }
    let data = pipe.fileHandleForReading.readData(ofLength: 65537)
    try require(process.terminationStatus == 0 && data.count <= 65536); return data
}
func installedVersion(receipt: Bool) throws -> String {
    try protectedPath(appPath, stop: "/Applications")
    let data = try Data(contentsOf: URL(fileURLWithPath: appPath + "/Contents/Info.plist"))
    guard let info = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
          let version = info["CFBundleShortVersionString"] as? String else { throw InstallGuardError.incompleteInstallation }
    try require(InstallPolicy.validVersion(version) && info["NightrTeamID"] as? String == BuildPolicy.teamID)
    try verifyStatic(appPath, identifier: "ai.nightr.app")
    for (name, identifier) in [("nightr-native", "ai.nightr.controller"), ("nightr-powerhelper", "ai.nightr.powerhelper"), ("NightrNetworkWorker", "ai.nightr.networkworker")] {
        let path = appPath + "/Contents/MacOS/" + name; try protectedPath(path, stop: "/Applications")
        try verifyStatic(path, identifier: identifier)
    }
    try protectedPath(guardPath); try verifyStatic(guardPath, identifier: "ai.nightr.installguard")
    for relative in ["Contents/Library/LaunchDaemons/ai.nightr.powerhelper.plist", "Contents/Library/LaunchAgents/ai.nightr.agent.plist", "Contents/Resources/libexec/nightr_install.py", "Contents/Resources/runtime/bin/python3"] {
        try protectedPath(appPath + "/" + relative, stop: "/Applications")
    }
    if receipt {
        let data = try run("/usr/sbin/pkgutil", ["--pkg-info-plist", "ai.nightr.package"])
        guard let result = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else { throw InstallGuardError.incompleteInstallation }
        try require(result["pkg-version"] as? String == version)
    }
    return version
}
func main() throws {
    try require(geteuid() == 0); try verifySelf()
    let args = Array(CommandLine.arguments.dropFirst())
    try require(!args.isEmpty)
    let operation = args[0]
    let scripted = operation == "begin" || operation == "complete"
    var invocation: String? = nil
    if scripted { try require(args.count == 3 && args[2] == "/"); invocation = try installerInvocation() }
    else { try require(try executablePath(getpid()) == guardPath); try protectedPath(guardPath) }
    let store = try RootStore()
    let update = try store.lockFile("update.lock"); defer { close(update) }
    let controller = try store.lockFile("controller.lock"); defer { close(controller) }
    let owner = try lockOwner(update)
    let request = try owner.map(privateRequest)
    let existing = try store.load()
    if operation == "begin" {
        let package = args[1]
        try require(package.hasPrefix("/") && URL(fileURLWithPath: package).standardizedFileURL.path == package)
        let output = try run("/usr/sbin/pkgutil", ["--check-signature", package])
        try require(String(data: output, encoding: .utf8)?.contains("(\(BuildPolicy.teamID))") == true)
        let exclusive: Bool
        if owner == nil { try exclusiveRecordLock(update); exclusive = flock(controller, LOCK_EX | LOCK_NB) == 0 }
        else { exclusive = managedControllerIsExclusive(controller) }
        let original: String?
        if existing != nil { original = existing?.originalVersion }
        else if FileManager.default.fileExists(atPath: appPath) { original = try installedVersion(receipt: true) }
        else { original = nil }
        try require(try lockOwner(update) == owner)
        var marker = try InstallPolicy.begin(existing: existing, owner: owner, request: request, packagePath: package, version: BuildPolicy.version, teamID: BuildPolicy.teamID, originalVersion: original, controllerExclusive: exclusive)
        marker.invocation = invocation
        try store.save(marker, replacing: existing?.generation)
    } else if operation == "complete" {
        guard let existing else { throw InstallGuardError.invalidPhase }
        try require(existing.invocation == invocation)
        if owner == nil { try exclusiveRecordLock(update); try require(flock(controller, LOCK_EX | LOCK_NB) == 0) }
        else { try require(managedControllerIsExclusive(controller)) }
        try require(try installedVersion(receipt: false) == BuildPolicy.version)
        try require(try lockOwner(update) == owner)
        let completed = try InstallPolicy.complete(existing, owner: owner, request: request, packagePath: args[1], version: BuildPolicy.version, teamID: BuildPolicy.teamID)
        if owner == nil { try store.clear(existing.generation) }
        else { try store.save(completed, replacing: existing.generation) }
    } else if operation == "finish" {
        try require(args.count == 2)
        guard let existing, let transaction = UUID(uuidString: args[1]) else { throw InstallGuardError.invalidRequest }
        try require(managedControllerIsExclusive(controller))
        let version = try installedVersion(receipt: true)
        try require(try lockOwner(update) == owner)
        try InstallPolicy.finish(existing, owner: owner, request: request, transaction: transaction, installedVersion: version, teamID: BuildPolicy.teamID)
        try store.clear(existing.generation)
    } else if operation == "repair" {
        try require(args.count == 1 && owner == nil)
        try exclusiveRecordLock(update); try require(flock(controller, LOCK_EX | LOCK_NB) == 0)
        guard let existing else { return }
        let version = try installedVersion(receipt: true)
        try InstallPolicy.repair(existing, installedVersion: version, teamID: BuildPolicy.teamID)
        try store.clear(existing.generation)
    } else { throw InstallGuardError.invalidRequest }
}
do { try main() } catch { fputs("Nightr installer guard refused the operation: \(error)\n", stderr); exit(78) }
