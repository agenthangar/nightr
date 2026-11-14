import XCTest
@testable import NightrPowerClient

final class BoundedReplyTests: XCTestCase {
    func testTimeoutRetiresBeforeReturningAndDiscardsLateAcquireToken() {
        var timeout: (() -> Void)?
        var events: [String] = []
        let reply = BoundedReply<String>({ result in
            if case .failure = result { events.append("failed") } else { events.append("late token") }
        }, onFailure: { events.append("retired") }, schedule: { timeout = $0 })
        timeout?()
        reply.finish(.success("late-acquire-generation"))
        timeout?()
        XCTAssertEqual(events, ["retired", "failed"])
    }
    func testSuccessfulReplyDoesNotRetireButErrorRetiresExactlyOnce() {
        var timeout: (() -> Void)?
        var results = 0, retirements = 0
        let success = BoundedReply<String>({ _ in results += 1 }, onFailure: { retirements += 1 }, schedule: { timeout = $0 })
        success.finish(.success("lease")); timeout?()
        XCTAssertEqual(results, 1); XCTAssertEqual(retirements, 0)
        let failed = BoundedReply<String>({ _ in results += 1 }, onFailure: { retirements += 1 }, schedule: { _ in })
        failed.finish(.failure(NSError(domain: "test", code: 1)))
        failed.finish(.success("ignored"))
        XCTAssertEqual(results, 2); XCTAssertEqual(retirements, 1)
    }
}
