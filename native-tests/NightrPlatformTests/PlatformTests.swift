import XCTest
@testable import NightrPlatform

final class MemoryCredentials: CredentialStore {
    var entries: [Data: Data] = [:]
    var failWrite = false
    var failRollback = false
    func read(ssid: String) throws -> Data? { entries[ssidIdentity(ssid)] }
    func write(ssid: String, password: Data) throws {
        if failWrite { throw TestFailure.failure }
        entries[ssidIdentity(ssid)] = password
    }
    func remove(ssid: String) throws { entries.removeValue(forKey: ssidIdentity(ssid)) }
    func savedSSIDs() throws -> [String] { [] }
}
enum TestFailure: Error { case failure }

final class PlatformTests: XCTestCase {
    func testSSIDValidationPreservesSpacesAndCanonicalSpellings() {
        XCTAssertTrue(validSSID("   "))
        XCTAssertTrue(validSSID(" Network "))
        XCTAssertFalse(validSSID(""))
        XCTAssertFalse(validSSID("bad\nname"))
        XCTAssertFalse(validSSID(String(repeating: "é", count: 17)))
        XCTAssertFalse(sameSSID("é", "e\u{301}"))
        XCTAssertFalse(sameSSID("Network", "network"))
    }
    func testCompleteFreshScanIsRequiredForNotSeen() {
        let now = Date()
        for state in [DiscoveryState.failed, .permission, .denied, .disabled, .off, .unavailable] {
            XCTAssertEqual(NetworkObservation(state: state, observedAt: now).availability(of: "test", now: now), "Availability unknown")
        }
        let observed = NetworkObservation(state: .complete, observedAt: now)
        XCTAssertEqual(observed.availability(of: "test", now: now), "Not seen")
        XCTAssertEqual(observed.availability(of: "test", now: now.addingTimeInterval(31)), "Availability unknown")
    }
    func testNetworksDeduplicateExactBytesAndSortCurrentThenSignal() {
        let input = [NetworkRecord(ssid: "a", signal: -10), NetworkRecord(ssid: "a", signal: -20),
                     NetworkRecord(ssid: "A", signal: -30), NetworkRecord(ssid: " a", signal: -40),
                     NetworkRecord(ssid: "current", signal: -90, current: true),
                     NetworkRecord(ssid: "é", signal: -50), NetworkRecord(ssid: "e\u{301}", signal: -60)]
        let sorted = NetworkObservation.ordered(input)
        XCTAssertEqual(sorted.count, 6)
        XCTAssertEqual(sorted.first?.ssid, "current")
        XCTAssertEqual(sorted[1].signal, -10)
        XCTAssertEqual(Set(sorted.map(\.id)).count, 6)
    }
    func testCredentialFailureDoesNotCommitConfiguration() throws {
        let store = MemoryCredentials(); store.failWrite = true
        var saved = false
        XCTAssertThrowsError(try CredentialTransaction(store: store).commit(edit: .password(ssid: " test ", data: Data("secret".utf8))) { saved = true })
        XCTAssertFalse(saved)
        XCTAssertTrue(store.entries.isEmpty)
    }
    func testConfigurationFailureRollsCredentialBack() throws {
        let store = MemoryCredentials(); store.entries[ssidIdentity("test")] = Data("old".utf8)
        XCTAssertThrowsError(try CredentialTransaction(store: store).commit(edit: .password(ssid: "test", data: Data("new".utf8))) { throw TestFailure.failure })
        XCTAssertEqual(store.entries[ssidIdentity("test")], Data("old".utf8))
        XCTAssertThrowsError(try CredentialTransaction(store: store).commit(edit: .explicitOpen(ssid: "test")) { throw TestFailure.failure })
        XCTAssertEqual(store.entries[ssidIdentity("test")], Data("old".utf8))
    }
    func testUnchangedSelectionNeverMutatesCredentials() throws {
        let store = MemoryCredentials(); store.failWrite = true
        var saved = false
        try CredentialTransaction(store: store).commit(edit: .unchanged) { saved = true }
        XCTAssertTrue(saved)
        XCTAssertTrue(store.entries.isEmpty)
    }
    func testActivityRequiresWorkRatherThanProcessOrCPU() {
        let now = Date(); var detector = AgentActivity()
        let process = "100 1 /usr/local/bin/codex\n200 1 /bin/zsh"
        XCTAssertFalse(detector.observe(processes: process, assertions: "", network: "codex.100,0,0\ntcp4 socket,100,100", now: now))
        XCTAssertFalse(detector.observe(processes: process, assertions: "", network: "codex.100,0,0\ntcp4 socket,200,200", now: now.addingTimeInterval(5)))
        XCTAssertTrue(detector.observe(processes: process, assertions: "", network: "codex.100,0,0\ntcp4 socket,50000,50000", now: now.addingTimeInterval(10)))
        XCTAssertFalse(AgentActivity.isAgent("/Applications/Other.app/Contents/MacOS/codex"))
        XCTAssertTrue(AgentActivity.isAgent("/Applications/ChatGPT.app/Contents/MacOS/codex"))
    }
    func testClaudeChildAndDesktopAssertionsCount() {
        var detector = AgentActivity()
        XCTAssertTrue(detector.observe(processes: "10 1 /bin/claude\n20 10 /usr/bin/caffeinate", assertions: "", network: "", now: Date()))
        XCTAssertTrue(detector.observe(processes: "", assertions: "pid 12(Claude): [0x0] 00:01:01 PreventUserIdleSystemSleep named: Electron", network: "", now: Date()))
        XCTAssertFalse(detector.observe(processes: "", assertions: "pid 12(ChatGPT): [0x0] PreventUserIdleDisplaySleep named: Capturing", network: "", now: Date()))
    }
    func testActivitySamplingAboveNettopFilterLimitIncludesEveryAgent() throws {
        let twenty = (100..<120).map { "\($0) 1 /usr/local/bin/codex" }.joined(separator: "\n")
        let processes = twenty + "\n120 1 /usr/local/bin/codex\n200 1 /usr/bin/curl"
        XCTAssertNil(AgentActivity.networkSampleArguments(processes: "200 1 /usr/bin/curl"))
        let filtered = try XCTUnwrap(AgentActivity.networkSampleArguments(processes: twenty))
        XCTAssertEqual(filtered.filter { $0 == "-p" }.count, 20)
        let unfiltered = try XCTUnwrap(AgentActivity.networkSampleArguments(processes: processes))
        XCTAssertEqual(unfiltered, ["-x", "-n", "-s", "1", "-L", "1", "-J", "bytes_in,bytes_out"])

        func sample(agent: Int, unrelated: Int) -> String {
            "codex.120,,,\ntcp4 agent,\(agent),0,\ncurl.200,,,\ntcp4 unrelated,\(unrelated),0,"
        }
        var detector = AgentActivity()
        let now = Date()
        XCTAssertFalse(detector.observe(processes: processes, assertions: "", network: sample(agent: 100, unrelated: 100), now: now))
        XCTAssertFalse(detector.observe(processes: processes, assertions: "", network: sample(agent: 100, unrelated: 60_000), now: now.addingTimeInterval(5)))
        XCTAssertTrue(detector.observe(processes: processes, assertions: "", network: sample(agent: 60_000, unrelated: 60_000), now: now.addingTimeInterval(10)))
    }
    func testMetadataFailureRollsBackAndRetainsExactSecurityClassifications() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = NetworkSecurityStore(url: directory.appendingPathComponent("security.json"))
        try store.replacing(ssid: "é", security: .password) {}
        try store.replacing(ssid: "e\u{301}", security: .open) {}
        XCTAssertEqual(try store.load().count, 2)
        XCTAssertEqual(try store.security(ssid: "é"), .password)
        XCTAssertEqual(try store.security(ssid: "e\u{301}"), .open)
        XCTAssertThrowsError(try store.replacing(ssid: "é", security: .open) { throw TestFailure.failure })
        XCTAssertEqual(try store.security(ssid: "é"), .password)
    }
    func testOwnedProcessTimeoutAndCancellationAreBounded() throws {
        let started = Date()
        XCTAssertThrowsError(try BoundedProcess().run(executable: URL(fileURLWithPath: "/bin/sleep"), arguments: ["5"], timeout: 0.1))
        XCTAssertLessThan(Date().timeIntervalSince(started), 2)
        let process = BoundedProcess()
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.1) { process.cancel() }
        let cancelled = Date()
        XCTAssertThrowsError(try process.run(executable: URL(fileURLWithPath: "/bin/sleep"), arguments: ["5"], timeout: 5))
        XCTAssertLessThan(Date().timeIntervalSince(cancelled), 2)
    }

    func testCredentialAccessPolicyTrustsOnlyThreeFixedSignedPrograms() throws {
        var inspected: [URL] = []
        let paths = try CredentialAccessPolicy.trustedPrograms(teamID: "ABCDE12345") { path in
            inspected.append(path)
            let identity = path == CredentialAccessPolicy.application ? "ai.nightr.app" : (path == CredentialAccessPolicy.worker ? "ai.nightr.networkworker" : "ai.nightr.controller")
            return .init(identifier: identity, teamID: "ABCDE12345", validDeveloperID: true)
        }
        XCTAssertEqual(paths, [CredentialAccessPolicy.application, CredentialAccessPolicy.worker, CredentialAccessPolicy.controller])
        XCTAssertEqual(inspected, paths)
        XCTAssertFalse(paths.contains(URL(fileURLWithPath: "/usr/bin/security")))
        XCTAssertThrowsError(try CredentialAccessPolicy.trustedPrograms(teamID: "untrusted") { _ in XCTFail("Invalid team must fail before inspection"); throw TestFailure.failure })
        for invalid in [CredentialProgramSignature(identifier: "ai.nightr.app", teamID: "ZZZZZ99999", validDeveloperID: true),
                        .init(identifier: "other.app", teamID: "ABCDE12345", validDeveloperID: true),
                        .init(identifier: "ai.nightr.app", teamID: "ABCDE12345", validDeveloperID: false)] {
            XCTAssertThrowsError(try CredentialAccessPolicy.trustedPrograms(teamID: "ABCDE12345") { _ in invalid })
        }
    }
    func testAccessPolicyFailurePreventsCredentialCreationAndConfigCommit() {
        var created = false, configSaved = false
        final class AccessFailureStore: CredentialStore {
            var create: () -> Void
            init(create: @escaping () -> Void) { self.create = create }
            func read(ssid: String) throws -> Data? { nil }
            func write(ssid: String, password: Data) throws {
                try CredentialWritePolicy.write(updateExisting: { false }, createAccess: { () throws -> Int in throw CredentialAccessFailure.invalidTrustedApplication }) { _ in self.create() }
            }
            func remove(ssid: String) throws {}
            func savedSSIDs() throws -> [String] { [] }
        }
        let store = AccessFailureStore { created = true }
        XCTAssertThrowsError(try CredentialTransaction(store: store).commit(edit: .password(ssid: "exact ", data: Data("synthetic".utf8))) { configSaved = true })
        XCTAssertFalse(created); XCTAssertFalse(configSaved)
    }
    func testExistingPasswordWriteDoesNotSilentlyExpandLegacyACL() throws {
        var updated = false, shared = false
        try CredentialWritePolicy.write(updateExisting: { updated = true; return true }, createAccess: { shared = true; return 1 }) { _ in XCTFail("Existing item must not be recreated") }
        XCTAssertTrue(updated); XCTAssertFalse(shared)
        var repaired = false
        try CredentialWritePolicy.repair(createAccess: { shared = true; return 1 }) { _ in repaired = true }
        XCTAssertTrue(shared); XCTAssertTrue(repaired)
    }
    func testSavedWiFiPasswordFallbackRequiresAbsentNightrCredential() throws {
        var lookedUp = false
        let first = try SavedCredentialPolicy.password(primary: { Data("nightr".utf8) }, savedWiFi: { lookedUp = true; return Data("system".utf8) })
        XCTAssertEqual(first, Data("nightr".utf8)); XCTAssertFalse(lookedUp)
        let fallback = try SavedCredentialPolicy.password(primary: { nil }, savedWiFi: { lookedUp = true; return Data("system".utf8) })
        XCTAssertEqual(fallback, Data("system".utf8)); XCTAssertTrue(lookedUp)
        lookedUp = false
        XCTAssertThrowsError(try SavedCredentialPolicy.password(primary: { throw TestFailure.failure }, savedWiFi: { lookedUp = true; return nil }))
        XCTAssertFalse(lookedUp)
    }

}
