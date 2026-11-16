import XCTest
@testable import NightrCore

final class DesktopRegistrationTests: XCTestCase {
    @MainActor func testEnabledAndPendingAreIdempotent() async throws {
        let enabled = FakeDesktopService("main", .enabled), pending = FakeDesktopService("agent", .requiresApproval)
        let receipt = try DesktopRegistrationReceipt.enable([enabled, pending])
        XCTAssertEqual(receipt.pending, ["agent"])
        XCTAssertEqual(enabled.actions + pending.actions, [])
        try receipt.rollback()
        XCTAssertEqual(enabled.status, .enabled); XCTAssertEqual(pending.status, .requiresApproval)
    }
    @MainActor func testPartialFailureOnlyUndoesNewEnabledRegistration() async {
        let main = FakeDesktopService("main", .notRegistered), agent = FakeDesktopService("agent", .notRegistered)
        agent.registerFailure = true
        XCTAssertThrowsError(try DesktopRegistrationReceipt.enable([main, agent]))
        XCTAssertEqual(main.actions, ["register", "unregister"])
        XCTAssertEqual(main.status, .notRegistered)
        let existing = FakeDesktopService("existing", .enabled)
        XCTAssertThrowsError(try DesktopRegistrationReceipt.enable([existing, agent]))
        XCTAssertEqual(existing.actions, [])
    }
    @MainActor func testThrownRegisterWithPendingPostStatusIsNotFailureOrRollback() async throws {
        let pending = FakeDesktopService("main", .notRegistered), agent = FakeDesktopService("agent", .notRegistered)
        pending.registerFailure = true; pending.afterRegister = .requiresApproval
        let receipt = try DesktopRegistrationReceipt.enable([pending, agent])
        XCTAssertEqual(receipt.pending, ["main"])
        try receipt.rollback()
        XCTAssertEqual(pending.actions, ["register"])
        XCTAssertEqual(pending.status, .requiresApproval)
        XCTAssertEqual(agent.actions, ["register", "unregister"])
    }
    @MainActor func testNewPendingApprovalSurvivesLaterFailure() async {
        let pending = FakeDesktopService("main", .notRegistered), failed = FakeDesktopService("agent", .unavailable)
        pending.afterRegister = .requiresApproval
        XCTAssertThrowsError(try DesktopRegistrationReceipt.enable([pending, failed]))
        XCTAssertEqual(pending.status, .requiresApproval)
        XCTAssertEqual(pending.actions, ["register"])
    }
    @MainActor func testRollbackFailureIsReported() async {
        let main = FakeDesktopService("main", .notRegistered), failed = FakeDesktopService("agent", .unavailable)
        main.unregisterFailure = true
        XCTAssertThrowsError(try DesktopRegistrationReceipt.enable([main, failed])) {
            XCTAssertTrue($0.localizedDescription.contains("Could not undo"))
        }
    }
    @MainActor func testDisableIsOrderedAndSkipsAbsentServices() async throws {
        var order: [String] = []
        let main = FakeDesktopService("main", .enabled), agent = FakeDesktopService("agent", .requiresApproval)
        main.onUnregister = { order.append("main") }; agent.onUnregister = { order.append("agent") }
        try DesktopRegistrationReceipt.disable([main, agent])
        XCTAssertEqual(order, ["main", "agent"])
        try DesktopRegistrationReceipt.disable([main, agent])
        XCTAssertEqual(order, ["main", "agent"])
    }
}
@MainActor private final class FakeDesktopService: DesktopServiceRegistration {
    let name: String
    var status: DesktopServiceStatus
    var actions: [String] = []
    var afterRegister = DesktopServiceStatus.enabled
    var registerFailure = false
    var unregisterFailure = false
    var onUnregister: () -> Void = {}
    init(_ name: String, _ status: DesktopServiceStatus) { self.name = name; self.status = status }
    func register() throws {
        actions.append("register")
        if !registerFailure || afterRegister == .requiresApproval { status = afterRegister }
        if registerFailure { throw DesktopServiceError("Synthetic register failure") }
    }
    func unregister() throws {
        actions.append("unregister"); onUnregister()
        if unregisterFailure { throw DesktopServiceError("Synthetic unregister failure") }
        status = .notRegistered
    }
}
