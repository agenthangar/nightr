import XCTest
import Foundation
import NightrCore
import NightrController
@testable import NightrPlatform

final class BatterySleepTests: XCTestCase {
    func testRestorationMustBeConfirmedBeforeSleep() {
        XCTAssertTrue(BatterySleepCommand.restorationAllowsSleep(active: false, blocked: false))
        XCTAssertFalse(BatterySleepCommand.restorationAllowsSleep(active: true, blocked: false))
        XCTAssertFalse(BatterySleepCommand.restorationAllowsSleep(active: false, blocked: true))
    }

    func testFreshPowerReadingRejectsACUnknownAndRecoveredBattery() {
        XCTAssertFalse(BatterySleepCommand.shouldSleep(onBattery: false, percent: 9, cutoff: 10))
        XCTAssertFalse(BatterySleepCommand.shouldSleep(onBattery: true, percent: nil, cutoff: 10))
        XCTAssertFalse(BatterySleepCommand.shouldSleep(onBattery: true, percent: 10, cutoff: 10))
        XCTAssertFalse(BatterySleepCommand.shouldSleep(onBattery: true, percent: 11, cutoff: 10))
        XCTAssertFalse(BatterySleepCommand.shouldSleep(onBattery: true, percent: -1, cutoff: 10))
    }

    func testDisabledCutoffAndStopNeverRequestSleep() {
        var settings = Settings()
        settings.forever = true
        settings.batteryProtection = false
        var engine = MonitorEngine(settings: settings)
        let now = Date()
        _ = engine.handle(.start, now: now)
        XCTAssertFalse(engine.handle(.tick(.init(onBattery: true, batteryPercent: 1)), now: now).contains(.releaseHoldForBattery(cutoff: 20)))
        _ = engine.handle(.stop, now: now)
        XCTAssertFalse(engine.handle(.tick(.init(onBattery: true, batteryPercent: 1)), now: now).contains(.releaseHoldForBattery(cutoff: 20)))
    }
}

private actor RecordingBatteryPlatform: ControllerPlatform {
    var sampleValue = MachineSample(onBattery: true, batteryPercent: 11)
    var commands: [[String]] = []
    var helperFailed = false
    func acquireProtection(settings: Settings) async throws {}
    private var releaseGate: CheckedContinuation<Void, Never>?
    private var releaseWaiter: CheckedContinuation<Void, Never>?
    private var delayRelease = false
    var sleepAttempts = 0
    var releases = 0
    func delayNextRelease() { delayRelease = true }
    func failHelper() { helperFailed = true }
    func waitForRelease() async {
        if releaseGate != nil { return }
        await withCheckedContinuation { releaseWaiter = $0 }
    }
    func completeRelease() { releaseGate?.resume(); releaseGate = nil }
    func releaseProtection() async {
        if delayRelease {
            delayRelease = false
            await withCheckedContinuation {
                releaseGate = $0
                releaseWaiter?.resume(); releaseWaiter = nil
            }
        }
        releases += 1
    }
    func requestBatterySleep(below cutoff: Int) async {
        sleepAttempts += 1
        try? await BatterySleepCommand.request(
            below: cutoff,
            restoration: { (false, self.helperFailed) },
            hasLease: { false },
            battery: { (self.sampleValue.onBattery, self.sampleValue.batteryPercent) },
            execute: { executable, arguments, timeout in
                XCTAssertEqual(timeout, 3)
                self.commands.append([executable.path] + arguments)
            }
        )
    }
    func sample() async -> MachineSample { sampleValue }
    func update(_ sample: MachineSample) { sampleValue = sample }
    func verifyInternet(timeout: TimeInterval) async -> Bool { false }
    func joinHotspot(ssid: String, timeout: TimeInterval) async -> JoinResult { .failed }
}

extension BatterySleepTests {
    func testControllerServiceReachesTheProductionCommandRecorder() async throws {
        let directory = URL(fileURLWithPath: "/tmp/nb-" + UUID().uuidString.prefix(8))
        defer { try? FileManager.default.removeItem(at: directory) }
        var settings = Settings()
        settings.forever = true
        settings.batteryBelow = 10
        let store = SettingsStore(url: directory.appendingPathComponent("config.json"))
        try store.save(settings, expected: nil)
        let platform = RecordingBatteryPlatform()
        let controller = try ControllerService(platform: platform, settingsStore: store, runtimeDirectory: directory.appendingPathComponent("run"))
        try await controller.start()
        await controller.send(.start)
        for _ in 0..<100 {
            if await controller.status().holding { break }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        let holding = await controller.status().holding
        XCTAssertTrue(holding)
        for percent in [11, 10, 9] {
            let sample = MachineSample(onBattery: true, batteryPercent: percent)
            await platform.update(sample)
            await controller.send(.tick(sample))
            let status = await controller.status()
            XCTAssertEqual(status.holding, percent >= 10)
        }
        for _ in 0..<100 {
            if await platform.commands.count == 1 { break }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        let atNine = await platform.commands
        XCTAssertEqual(atNine, [["/usr/bin/pmset", "sleepnow"]])
        let lower = MachineSample(onBattery: true, batteryPercent: 8)
        await platform.update(lower)
        await controller.send(.tick(lower))
        await controller.shutdown()
        let final = await platform.commands
        XCTAssertEqual(final, atNine)
    }
}

extension BatterySleepTests {
    func testACDuringReleaseSuppressesSystemSleep() async throws { try await checkReleaseInterruption("ac") }
    func testOptOutDuringReleaseSuppressesSystemSleep() async throws { try await checkReleaseInterruption("optout") }
    func testHelperFailureDuringReleaseSuppressesSystemSleep() async throws { try await checkReleaseInterruption("helper") }

    private func checkReleaseInterruption(_ kind: String) async throws {
        let directory = URL(fileURLWithPath: "/tmp/nb-" + UUID().uuidString.prefix(8))
        defer { try? FileManager.default.removeItem(at: directory) }
        var settings = Settings()
        settings.forever = true
        settings.batteryBelow = 10
        let store = SettingsStore(url: directory.appendingPathComponent("config.json"))
        try store.save(settings, expected: nil)
        let platform = RecordingBatteryPlatform()
        let controller = try ControllerService(platform: platform, settingsStore: store, runtimeDirectory: directory.appendingPathComponent("run"))
        try await controller.start()
        await controller.send(.start)
        for _ in 0..<100 {
            if await controller.status().holding { break }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        let holding = await controller.status().holding
        XCTAssertTrue(holding)
        await platform.delayNextRelease()
        let low = MachineSample(onBattery: true, batteryPercent: 9)
        await platform.update(low)
        await controller.send(.tick(low))
        await platform.waitForRelease()
        switch kind {
        case "ac":
            await platform.update(.init(onBattery: false, batteryPercent: 9))
        case "optout":
            settings.batteryProtection = false
            await controller.send(.settings(settings))
        default:
            await platform.failHelper()
        }
        await platform.completeRelease()
        // Shutdown drains the serial executor. For guard tests, wait until the
        // request is attempted so shutdown cancellation cannot hide a regression.
        if kind == "optout" {
            for _ in 0..<100 {
                if await platform.releases >= 2 { break }
                try await Task.sleep(nanoseconds: 5_000_000)
            }
            let attempts = await platform.sleepAttempts
            let releases = await platform.releases
            XCTAssertEqual(attempts, 0)
            XCTAssertGreaterThanOrEqual(releases, 2)
        } else {
            for _ in 0..<100 {
                if await platform.sleepAttempts == 1 { break }
                try await Task.sleep(nanoseconds: 5_000_000)
            }
            let attempts = await platform.sleepAttempts
            XCTAssertEqual(attempts, 1)
        }
        await controller.shutdown()
        let commands = await platform.commands
        XCTAssertTrue(commands.isEmpty)
    }
}
