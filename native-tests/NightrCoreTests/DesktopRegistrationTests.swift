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
    @MainActor func testUnavailableStatusDoesNotClaimInstallationIsDamaged() async {
        let service = FakeDesktopService("Nightr menu bar app", .unavailable)
        XCTAssertThrowsError(try DesktopRegistrationReceipt.enable([service])) {
            XCTAssertTrue($0.localizedDescription.contains("System Settings → General → Login Items"))
            XCTAssertFalse($0.localizedDescription.contains("Reinstall"))
            XCTAssertFalse($0.localizedDescription.contains("Repair"))
        }
        XCTAssertEqual(service.actions, [])
    }
    @MainActor func testMissingBundleFilesGivesInstallationGuidance() async {
        let service = FakeDesktopService("Power helper", .missingBundleFiles)
        XCTAssertThrowsError(try DesktopRegistrationReceipt.enable([service])) {
            XCTAssertTrue($0.localizedDescription.contains("missing required files"))
            XCTAssertTrue($0.localizedDescription.contains("Reinstall Nightr"))
        }
        XCTAssertEqual(service.actions, [])
    }
    @MainActor func testEnableFailureNamesServiceAndActionWhileRollingBack() async {
        let main = FakeDesktopService("menu bar app", .notRegistered), agent = FakeDesktopService("background controller", .notRegistered)
        agent.registerFailure = true
        XCTAssertThrowsError(try DesktopRegistrationReceipt.enable([main, agent])) {
            XCTAssertTrue($0.localizedDescription.contains("Could not enable background controller"))
            XCTAssertTrue($0.localizedDescription.contains("Synthetic register failure"))
            XCTAssertTrue($0.localizedDescription.contains("Login Items, then retry"))
        }
        XCTAssertEqual(main.status, .notRegistered)
        XCTAssertEqual(agent.actions, ["register"])
    }
    @MainActor func testRegistrationMustBecomeEnabledOrPending() async {
        let service = FakeDesktopService("menu bar app", .notRegistered)
        service.afterRegister = .notRegistered
        XCTAssertThrowsError(try DesktopRegistrationReceipt.enable([service])) {
            XCTAssertTrue($0.localizedDescription.contains("macOS did not confirm registration"))
        }
    }
    @MainActor func testDisableFailureNamesServiceAndActionAndStopsBeforeController() async {
        let main = FakeDesktopService("menu bar app", .enabled), agent = FakeDesktopService("background controller", .enabled)
        main.unregisterFailure = true
        XCTAssertThrowsError(try DesktopRegistrationReceipt.disable([main, agent])) {
            XCTAssertTrue($0.localizedDescription.contains("Could not disable menu bar app"))
            XCTAssertTrue($0.localizedDescription.contains("Synthetic unregister failure"))
            XCTAssertTrue($0.localizedDescription.contains("System Settings → General → Login Items"))
        }
        XCTAssertEqual(agent.actions, [])
    }
    @MainActor func testDisableMustConfirmRemoval() async {
        let main = FakeDesktopService("menu bar app", .enabled)
        main.afterUnregister = .enabled
        XCTAssertThrowsError(try DesktopRegistrationReceipt.disable([main])) {
            XCTAssertTrue($0.localizedDescription.contains("macOS did not confirm removal"))
        }
    }
    @MainActor func testRollbackReportsUnconfirmedRemoval() async throws {
        let main = FakeDesktopService("menu bar app", .notRegistered)
        let receipt = try DesktopRegistrationReceipt.enable([main])
        main.afterUnregister = .enabled
        XCTAssertThrowsError(try receipt.rollback()) {
            XCTAssertTrue($0.localizedDescription.contains("Could not undo new registrations: menu bar app"))
        }
    }
    @MainActor func testNotFoundAttemptsRegistrationButNeverClaimsReadyWithoutConfirmation() async {
        let service = FakeDesktopService("menu bar app", .notFound)
        service.afterRegister = .notFound
        XCTAssertThrowsError(try DesktopRegistrationReceipt.enable([service])) {
            XCTAssertTrue($0.localizedDescription.contains("macOS did not confirm registration"))
            XCTAssertFalse($0.localizedDescription.contains("Reinstall"))
        }
        XCTAssertEqual(service.actions, ["register"])
    }
    @MainActor func testNotFoundDisableRequiresSuccessfulRemoval() async throws {
        let service = FakeDesktopService("menu bar app", .notFound)
        service.unregisterFailure = true
        XCTAssertThrowsError(try DesktopRegistrationReceipt.disable([service]))
        XCTAssertEqual(service.actions, ["unregister"])
        service.unregisterFailure = false; service.afterUnregister = .notFound
        try DesktopRegistrationReceipt.disable([service])
        XCTAssertEqual(service.actions, ["unregister", "unregister"])
    }
    @MainActor func testThrownRegisterThatEnabledServiceIsRolledBack() async {
        let service = FakeDesktopService("menu bar app", .notRegistered)
        service.registerFailure = true; service.mutateBeforeRegisterFailure = true
        XCTAssertThrowsError(try DesktopRegistrationReceipt.enable([service]))
        XCTAssertEqual(service.actions, ["register", "unregister"])
        XCTAssertEqual(service.status, .notRegistered)
    }
    @MainActor func testRollbackDoesNotTreatLookupFailureAsRemoval() async throws {
        let service = FakeDesktopService("menu bar app", .notRegistered)
        let receipt = try DesktopRegistrationReceipt.enable([service])
        service.status = .notFound; service.unregisterFailure = true
        XCTAssertThrowsError(try receipt.rollback())
        XCTAssertEqual(service.actions, ["register", "unregister"])
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
    var mutateBeforeRegisterFailure = false
    var unregisterFailure = false
    var afterUnregister = DesktopServiceStatus.notRegistered
    var onUnregister: () -> Void = {}
    init(_ name: String, _ status: DesktopServiceStatus) { self.name = name; self.status = status }
    func register() throws {
        actions.append("register")
        if !registerFailure || afterRegister == .requiresApproval || mutateBeforeRegisterFailure { status = afterRegister }
        if registerFailure { throw DesktopServiceError("Synthetic register failure") }
    }
    func unregister() throws {
        actions.append("unregister"); onUnregister()
        if unregisterFailure { throw DesktopServiceError("Synthetic unregister failure") }
        status = afterUnregister
    }
}
