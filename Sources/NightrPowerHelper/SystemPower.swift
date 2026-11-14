import Foundation
import Darwin
import IOKit.ps
import NightrPowerProtocol

struct SystemPower: PowerBackend {
    func readDisabledSleep() throws -> Int {
        try PMSetSettings.sleepDisabled(in: pmset(["-g"]))
    }
    func setDisabledSleep(_ disabled: Bool) throws { _ = try pmset(["-a", "disablesleep", disabled ? "1" : "0"]) }
    func batteryIsSafe(threshold: Int) throws -> Bool {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef] else { throw PowerError.unsafeBattery }
        for source in list {
            guard let description = IOPSGetPowerSourceDescription(blob, source)?.takeUnretainedValue() as? [String: Any] else { throw PowerError.unsafeBattery }
            if description[kIOPSTypeKey] as? String != kIOPSInternalBatteryType { continue }
            if description[kIOPSPowerSourceStateKey] as? String == kIOPSACPowerValue { return true }
            guard let current = description[kIOPSCurrentCapacityKey] as? Int,
                  let maximum = description[kIOPSMaxCapacityKey] as? Int, maximum > 0 else { throw PowerError.unsafeBattery }
            return current * 100 >= threshold * maximum
        }
        return true // Desktop with no internal battery.
    }
    private func pmset(_ arguments: [String]) throws -> String {
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        process.arguments = arguments; process.environment = ["PATH": "/usr/bin:/bin", "LC_ALL": "C"]
        let pipe = Pipe(); process.standardOutput = pipe; process.standardError = FileHandle.nullDevice
        // Fixed pmset output is small; cap reading and bound every execution.
        let done = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in done.signal() }
        try process.run()
        if done.wait(timeout: .now() + 5) == .timedOut { process.terminate(); usleep(100_000); if process.isRunning { kill(process.processIdentifier, SIGKILL) }; process.waitUntilExit(); throw PowerError.restoreFailed }
        let data = pipe.fileHandleForReading.readData(ofLength: 16385)
        guard process.terminationStatus == 0, data.count <= 16384, let result = String(data: data, encoding: .utf8) else { throw PowerError.restoreFailed }
        return result
    }
}
func continuousSeconds() -> TimeInterval {
    var timebase = mach_timebase_info_data_t(); mach_timebase_info(&timebase)
    return Double(mach_continuous_time()) * Double(timebase.numer) / Double(timebase.denom) / 1_000_000_000
}
