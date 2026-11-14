import Foundation
import NightrPlatform
#if os(macOS)
let encoder = JSONEncoder()
let operation = CommandLine.arguments.dropFirst().first
let data: Data
switch operation {
case "scan": data = (try? encoder.encode(NativeNetworkWorker().scan())) ?? Data()
case "join":
    let input = FileHandle.standardInput.readDataToEndOfFile()
    guard input.count <= 256, let ssid = try? JSONDecoder().decode(String.self, from: input), validSSID(ssid) else { exit(2) }
    data = (try? encoder.encode(NativeNetworkWorker().join(ssid: ssid))) ?? Data()
case "credential-status":
    let input = FileHandle.standardInput.readDataToEndOfFile()
    guard input.count <= 256, let ssid = try? JSONDecoder().decode(String.self, from: input), validSSID(ssid) else { exit(2) }
    data = (try? encoder.encode(NativeNetworkWorker().credentialStatus(ssid: ssid))) ?? Data()
default: exit(2)
}
try FileHandle.standardOutput.write(contentsOf: data)
#else
exit(2)
#endif
