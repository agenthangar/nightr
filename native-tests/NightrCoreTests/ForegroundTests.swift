import XCTest
import Foundation
import NightrCore
@testable import NightrController

private actor ForegroundPlatform: ControllerPlatform {
    var releases = 0
    func acquireProtection(settings: Settings) async throws {}
    func releaseProtection() async { releases += 1 }
    func verifyInternet(timeout: TimeInterval) async -> Bool { false }
    func joinHotspot(ssid: String, timeout: TimeInterval) async -> JoinResult { .failed }
    func sample() async -> MachineSample { MachineSample() }
}
private final class HandoffAttempts: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func next() -> Int { lock.lock(); defer { lock.unlock() }; count += 1; return count }
    var value: Int { lock.lock(); defer { lock.unlock() }; return count }
}

final class ForegroundTests: XCTestCase {
    func testSnapshotIgnoresTimestampsAndEmitsUnavailableAndRecoveryOnce() {
        var engine = MonitorEngine()
        _ = engine.handle(.start, now: Date(timeIntervalSince1970: 10))
        let first = ForegroundStatus.snapshot(.init(status: .init(engine: engine)))
        _ = engine.handle(.tick(MachineSample()), now: Date(timeIntervalSince1970: 11))
        let second = ForegroundStatus.snapshot(.init(status: .init(engine: engine)))
        XCTAssertEqual(first, second)
        var output = ForegroundStatusOutput(isTTY: false, noColor: false)
        XCTAssertEqual(output.render(first), first + "\n")
        XCTAssertNil(output.render(second))
        let unavailable = ForegroundStatus.snapshot(.init(error: "handoff"))
        XCTAssertNotNil(output.render(unavailable)); XCTAssertNil(output.render(unavailable))
        XCTAssertEqual(output.render(first), first + "\n")
        XCTAssertFalse(first.contains("\u{1B}")); XCTAssertEqual(output.restoration, "")
        var noColor = ForegroundStatusOutput(isTTY: true, noColor: true)
        XCTAssertFalse(noColor.render(first)!.contains("\u{1B}")); XCTAssertEqual(noColor.restoration, "")
        var tty = ForegroundStatusOutput(isTTY: true, noColor: false)
        let interactive = tty.render(first)!
        XCTAssertTrue(interactive.contains("\u{1B}[?25l")); XCTAssertEqual(tty.restoration, "\u{1B}[?25h")
        XCTAssertTrue(interactive.contains("\u{1B}[36mNightr"))
        XCTAssertTrue(interactive.contains("\u{1B}[36mAgent:"))
        XCTAssertTrue(interactive.contains("\u{1B}[32m On"))
        XCTAssertTrue(tty.render(unavailable)!.contains("\u{1B}[31mNightr status unavailable:"))
    }
    func testEarlySignalIsBufferedAndPreventsDelayedStart() async {
        let signal = ForegroundStopSignal()
        signal.request()
        XCTAssertTrue(signal.requested)
        var starts = 0
        let response = signal.startIfPending {
            starts += 1
            return ControllerResponse(status: .init(engine: MonitorEngine()))
        }
        XCTAssertNil(response)
        var received = false
        for await _ in signal.events { received = true; break }
        signal.finish()
        XCTAssertTrue(received); XCTAssertEqual(starts, 0)
    }
    func testAcceptedStartWithLostReplyRequiresDurableCleanupWithoutSignal() async throws {
        let root = URL(fileURLWithPath: "/tmp/nf-" + UUID().uuidString.prefix(8))
        defer { try? FileManager.default.removeItem(at: root) }
        let runtime = root.appendingPathComponent("run")
        let service = try ControllerService(platform: ForegroundPlatform(), settingsStore: .init(url: root.appendingPathComponent("config.json")), runtimeDirectory: runtime)
        try await service.start()
        let signal = ForegroundStopSignal()
        let client = ControllerClient(runtimeDirectory: runtime)
        do {
            _ = try signal.startIfPending {
                let accepted = try client.request(.init(command: .start))
                XCTAssertTrue(accepted.status!.state.desiredEnabled)
                // Fault injection at the transport boundary: the owner accepted
                // and persisted Start, but the foreground caller lost the reply.
                throw ControllerStartUncertainError(message: "reply timed out")
            }
            XCTFail("lost reply must fail Start")
        } catch {}
        XCTAssertFalse(signal.requested)
        XCTAssertTrue(signal.requiresStopOnFailure)
        XCTAssertTrue(try StateJournal.load(directory: runtime).desiredEnabled)
        if signal.requiresStopOnFailure { _ = try await StopRecovery.stop(runtimeDirectory: runtime) }
        XCTAssertFalse(try StateJournal.load(directory: runtime).desiredEnabled)
        await service.shutdown(preserveIntent: true)
        signal.finish()
    }
    func testDefinitePreflightFailureAndApplicationRejectionDoNotStopExistingOwner() {
        let preflight = ForegroundStopSignal()
        XCTAssertThrowsError(try preflight.startIfPending { throw IPCError.invalid("unsafe endpoint") })
        XCTAssertFalse(preflight.requiresStopOnFailure)
        let rejected = ForegroundStopSignal()
        let response = rejected.startIfPending { ControllerResponse(error: "different settings") }
        XCTAssertNotNil(response?.error)
        XCTAssertFalse(rejected.requiresStopOnFailure)
        let invalid = ForegroundStopSignal()
        _ = invalid.startIfPending { ControllerResponse() }
        XCTAssertTrue(invalid.requiresStopOnFailure)
        preflight.finish(); rejected.finish(); invalid.finish()
    }
    func testStopDoesNotTreatRejectionOrUnconfirmedStateAsEndpointAbsence() async {
        let offline = HandoffAttempts()
        for response in [ControllerResponse(error: "journal failed"), ControllerResponse(), ControllerResponse(status: .init(engine: enabledEngine()))] {
            do {
                _ = try await StopRecovery.confirm(send: { response }, offline: { _ = offline.next() })
                XCTFail("must fail without a durable Off confirmation")
            } catch {}
        }
        XCTAssertEqual(offline.value, 0)
        do {
            _ = try await StopRecovery.confirm(send: { throw IPCError.invalid("unsafe endpoint") }, offline: { _ = offline.next() })
            XCTFail("unsafe endpoint must not invoke offline mutation")
        } catch {}
        XCTAssertEqual(offline.value, 0)
    }
    func testBoundedHandoffRetriesCurrentEndpointAndOfflineLockOnly() async throws {
        let request = HandoffAttempts(), offline = HandoffAttempts()
        let stopped = ControllerResponse(status: .init(engine: MonitorEngine()))
        let result = try await StopRecovery.confirm(send: {
            if request.next() == 1 { throw ControllerUnavailableError() }
            return stopped
        }, offline: { _ = offline.next(); throw RuntimeOwnershipBusyError() }, pause: {})
        XCTAssertFalse(result!.state.desiredEnabled)
        XCTAssertEqual(request.value, 2); XCTAssertEqual(offline.value, 1)
        let busy = HandoffAttempts()
        do {
            _ = try await StopRecovery.confirm(attempts: 3, send: { throw ControllerUnavailableError() }, offline: { _ = busy.next(); throw RuntimeOwnershipBusyError() }, pause: {})
            XCTFail("handoff must have a bound")
        } catch { XCTAssertTrue(error.localizedDescription.contains("handoff")) }
        XCTAssertEqual(busy.value, 3)
    }
    func testReplacementOwnerReceivesStopAfterOriginalShutdown() async throws {
        let root = URL(fileURLWithPath: "/tmp/nf-" + UUID().uuidString.prefix(8))
        defer { try? FileManager.default.removeItem(at: root) }
        let runtime = root.appendingPathComponent("run")
        let store = SettingsStore(url: root.appendingPathComponent("config.json"))
        let original = try ControllerService(platform: ForegroundPlatform(), settingsStore: store, runtimeDirectory: runtime)
        try await original.start()
        _ = await original.request(.init(command: .start))
        await original.shutdown(preserveIntent: true)
        let replacement = try ControllerService(platform: ForegroundPlatform(), settingsStore: store, runtimeDirectory: runtime)
        try await replacement.start()
        _ = await replacement.request(.init(command: .start))
        let stopped = try await StopRecovery.stop(runtimeDirectory: runtime)
        await original.shutdown(preserveIntent: true)
        XCTAssertFalse(stopped!.state.desiredEnabled)
        let replacementStatus = await replacement.status()
        XCTAssertFalse(replacementStatus.state.desiredEnabled)
        XCTAssertFalse(try StateJournal.load(directory: runtime).desiredEnabled)
        await replacement.shutdown(preserveIntent: true)
        _ = try await StopRecovery.stop(runtimeDirectory: runtime)
        XCTAssertFalse(try StateJournal.load(directory: runtime).desiredEnabled)
    }
    func testStopPersistenceFailureIsAnErrorAndReleasesProtection() async throws {
        let root = URL(fileURLWithPath: "/tmp/nf-" + UUID().uuidString.prefix(8))
        defer { try? FileManager.default.removeItem(at: root) }
        let runtime = root.appendingPathComponent("run")
        let platform = ForegroundPlatform()
        let service = try ControllerService(platform: platform, settingsStore: .init(url: root.appendingPathComponent("config.json")), runtimeDirectory: runtime)
        try await service.start()
        _ = await service.request(.init(command: .start))
        XCTAssertTrue(try StateJournal.load(directory: runtime).desiredEnabled)
        // A directory at the destination makes journal rename fail without touching
        // permissions or relying on whether tests run as root.
        let journal = runtime.appendingPathComponent("state.json")
        try FileManager.default.removeItem(at: journal)
        try FileManager.default.createDirectory(at: journal, withIntermediateDirectories: false)
        let response = await service.request(.init(command: .stop))
        XCTAssertNotNil(response.error)
        XCTAssertFalse(response.status!.state.desiredEnabled)
        await service.shutdown(preserveIntent: true)
        let releases = await platform.releases
        XCTAssertGreaterThan(releases, 0)
    }
    private func enabledEngine() -> MonitorEngine {
        var engine = MonitorEngine(); _ = engine.handle(.start, now: Date()); return engine
    }
}
