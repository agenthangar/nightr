import Foundation
import Darwin
import MachO
import Security
import NightrPowerProtocol
import NightrPowerClient

final class Peer: NSObject, NightrPowerXPC {
    let identity: UUID
    let uid: UInt32
    let engine: PowerLeaseEngine
    let queue: DispatchQueue
    init(uid: UInt32, engine: PowerLeaseEngine, queue: DispatchQueue) {
        self.uid = uid; self.engine = engine; self.queue = queue; identity = UUID()
    }
    func acquire(_ threshold: Int, reply: @escaping (String?, String?) -> Void) {
        queue.async { do { reply(try self.engine.acquire(uid: self.uid, connection: self.identity, batteryThreshold: threshold).generation.uuidString, nil) } catch { reply(nil, String(describing: error)) } }
    }
    private func token(_ generation: String) throws -> LeaseIdentity {
        guard let id = UUID(uuidString: generation) else { throw PowerError.staleLease }
        return LeaseIdentity(uid: uid, connection: identity, generation: id)
    }
    func renew(_ generation: String, threshold: Int, reply: @escaping (String?) -> Void) {
        queue.async { do { try self.engine.renew(self.token(generation), batteryThreshold: threshold == -1 ? nil : threshold); reply(nil) } catch { reply(String(describing: error)) } }
    }
    func release(_ generation: String, reply: @escaping (String?) -> Void) {
        queue.async { do { try self.engine.release(self.token(generation)); reply(nil) } catch { reply(String(describing: error)) } }
    }
    func status(reply: @escaping (String) -> Void) {
        queue.async {
            // Status never renews a lease or changes a power setting.
            let value = PowerReply(active: self.engine.activeLease != nil, restorationBlocked: self.engine.restorationBlocked)
            reply(String(data: (try? JSONEncoder().encode(value)) ?? Data(), encoding: .utf8) ?? "{}")
        }
    }
}
final class Listener: NSObject, NSXPCListenerDelegate {
    let engine: PowerLeaseEngine
    let queue = DispatchQueue(label: "ai.nightr.powerhelper.serial")
    let requirement: String
    init(engine: PowerLeaseEngine, teamID: String) throws {
        self.engine = engine
        requirement = try SigningPolicy.requirement(teamID: teamID, identifiers: ["ai.nightr.app", "ai.nightr.controller"])
    }
    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        connection.setCodeSigningRequirement(requirement)
        let peer = Peer(uid: connection.effectiveUserIdentifier, engine: engine, queue: queue)
        connection.exportedInterface = NSXPCInterface(with: NightrPowerXPC.self)
        connection.exportedObject = peer
        connection.invalidationHandler = { [weak self] in self?.queue.async { try? self?.engine.disconnected(peer.identity) } }
        connection.interruptionHandler = { [weak self] in self?.queue.async { try? self?.engine.disconnected(peer.identity) } }
        connection.resume()
        return true
    }
}
// Only ServiceManagement launches this daemon. Its Apple signing gate owns the
// shared /Applications namespace boundary; there is no sudo or caller-path mode.
func canonicalExecutableIsProtected() -> Bool {
    var count: UInt32 = 4096
    var bytes = [CChar](repeating: 0, count: Int(count))
    guard _NSGetExecutablePath(&bytes, &count) == 0 else { return false }
    let path = String(cString: bytes)
    guard path == "/Applications/Nightr.app/Contents/MacOS/nightr-powerhelper" else { return false }
    var current = URL(fileURLWithPath: path)
    while current.path != "/Applications" {
        var metadata = stat()
        guard lstat(current.path, &metadata) == 0, metadata.st_uid == 0,
              metadata.st_mode & 0o022 == 0, metadata.st_mode & S_IFMT != S_IFLNK else { return false }
        current.deleteLastPathComponent()
    }
    return true
}
// This binary has no caller-controlled privileged modes, commands or file paths.
func signedTeam() -> String? {
    var code: SecCode?
    guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return nil }
    var staticCode: SecStaticCode?
    guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return nil }
    var information: CFDictionary?
    guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess,
          let values = information as? [String: Any],
          values[kSecCodeInfoIdentifier as String] as? String == "ai.nightr.powerhelper",
          let team = values[kSecCodeInfoTeamIdentifier as String] as? String,
          let expression = try? SigningPolicy.requirement(teamID: team, identifiers: ["ai.nightr.powerhelper"]) else { return nil }
    var requirement: SecRequirement?
    guard SecRequirementCreateWithString(expression as CFString, [], &requirement) == errSecSuccess,
          SecCodeCheckValidity(code, [], requirement) == errSecSuccess else { return nil }
    return team
}
guard geteuid() == 0, canonicalExecutableIsProtected(), CommandLine.arguments.count == 1,
      let team = signedTeam() else { exit(78) }
do {
    let journal = try SecureJournal()
    let globalLock = try journal.lock()
    let engine = PowerLeaseEngine(backend: SystemPower(), journal: journal, now: continuousSeconds)
    try engine.recover()
    let delegate = try Listener(engine: engine, teamID: team)
    let listener = NSXPCListener(machServiceName: "ai.nightr.powerhelper")
    listener.delegate = delegate
    let timer = DispatchSource.makeTimerSource(queue: delegate.queue)
    timer.schedule(deadline: .now(), repeating: 1)
    timer.setEventHandler { try? engine.tick() }; timer.resume(); listener.resume()
    withExtendedLifetime((globalLock, delegate, timer, journal)) { dispatchMain() }
} catch { exit(78) }
