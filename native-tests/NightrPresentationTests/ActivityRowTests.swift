#if os(macOS)
import XCTest
import NightrCore
@testable import NightrApp

/// Pure formatting contracts. Does not create windows, services or observers.
final class ActivityRowTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_000)
    func testFreshInferenceRanksBeforeLoadedAndInventory() {
        let observation = ActivityObservation(runtimes: [
            .init(runtime: .mlx, observedAt: now, models: [.init(id: "inventory", residency: .available)]),
            .init(runtime: .lmStudio, observedAt: now, models: [.init(id: "idle", residency: .loaded, activity: .idle)]),
            .init(runtime: .ollama, observedAt: now, models: [.init(id: "working", residency: .loaded, activity: .generating, startedAt: now.addingTimeInterval(-42), inferenceExpiresAt: now.addingTimeInterval(15))])
        ])
        let rows = ActivityModelRow.rows(observation, now: now)
        XCTAssertEqual(rows.map(\.name), ["working", "idle", "inventory"])
        XCTAssertEqual(rows[0].elapsedSeconds, 42)
        XCTAssertTrue(rows[0].inference)
        XCTAssertEqual(rows[0].memoryLabel, "GPU memory")
        XCTAssertEqual(rows[1].state, "Loaded, idle")
        XCTAssertEqual(rows[2].state, "Inventory only")
    }
    func testExpiredRuntimeNeverPresentsCurrentMemoryOrInference() {
        let observation = ActivityObservation(runtimes: [
            .init(runtime: .ollama, observedAt: now.addingTimeInterval(-15), models: [.init(id: "old", residency: .loaded, activity: .generating, contextTokens: 8_192, memoryBytes: 100, tokensPerSecond: 30, inferenceExpiresAt: now.addingTimeInterval(5))])
        ])
        let row = ActivityModelRow.rows(observation, now: now)[0]
        XCTAssertEqual(row.state, "Activity unknown")
        XCTAssertFalse(row.inference)
        XCTAssertNil(row.contextTokens)
        XCTAssertNil(row.memoryBytes)
        XCTAssertNil(row.tokensPerSecond)
    }
    func testMissingExpiredAndUnboundedLeaseCannotImplyGenerating() {
        for expiry in [nil, now, now.addingTimeInterval(16)] as [Date?] {
            let observation = ActivityObservation(runtimes: [
                .init(runtime: .mlx, observedAt: now, models: [.init(id: "unverified", activity: .processing, tokensPerSecond: 40, inferenceExpiresAt: expiry)])
            ])
            let row = ActivityModelRow.rows(observation, now: now)[0]
            XCTAssertFalse(row.inference)
            XCTAssertNil(row.tokensPerSecond)
            XCTAssertEqual(row.state, "Loaded state unknown")
        }
    }
    func testUnavailableModelAndEmptyRuntimeAreDistinctFromNoObservations() {
        XCTAssertTrue(ActivityModelRow.rows(nil, now: now).isEmpty)
        let observation = ActivityObservation(runtimes: [.init(runtime: .llamaCPP, observedAt: now, models: [])])
        let row = ActivityModelRow.rows(observation, now: now)[0]
        XCTAssertEqual(row.runtime, "llama.cpp")
        XCTAssertEqual(row.state, "No models reported")
        XCTAssertFalse(row.inference)
    }
    func testRuntimeAndExactModelIdentityArePreservedWithoutDuplicateRows() {
        let name = "sample/<model & \"quoted\"> · exact"
        let model = LocalModelObservation(id: name, name: name, residency: .loaded, activity: .unknown)
        let observation = ActivityObservation(runtimes: [
            .init(runtime: .ollama, observedAt: now, models: [model, model]),
            .init(runtime: .lmStudio, observedAt: now, models: [model])
        ])
        let rows = ActivityModelRow.rows(observation, now: now)
        XCTAssertEqual(rows.count, 2)
        XCTAssertNotEqual(rows[0].id, rows[1].id)
        XCTAssertEqual(rows[0].name, name)
        XCTAssertEqual(rows[0].state, "Loaded, activity unknown")
        XCTAssertEqual(rows[0].unverified.state, "Activity and loaded state unknown")
        XCTAssertFalse(rows[0].unverified.inference)
    }
}
#endif
