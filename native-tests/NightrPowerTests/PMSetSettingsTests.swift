import XCTest
import NightrPowerProtocol

final class PMSetSettingsTests: XCTestCase {
    func testCapturedGlobalSettingsZeroAndOne() throws {
        for value in [0, 1] {
            let captured = """
            System-wide power settings:
            Currently in use:
             SleepDisabled\t\t\(value)
             sleep                10
             disksleep            10
            """
            XCTAssertEqual(try PMSetSettings.sleepDisabled(in: captured), value)
        }
    }
    func testRejectMissingAmbiguousAndMalformedObservations() {
        for output in ["disablesleep 1", "sleep 1", "SleepDisabled 2", "SleepDisabled no", "SleepDisabled", "SleepDisabled 0 1", "SleepDisabled 0\nSleepDisabled 1"] {
            XCTAssertThrowsError(try PMSetSettings.sleepDisabled(in: output))
        }
    }
}
