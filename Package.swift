// swift-tools-version: 5.9
import PackageDescription
import Foundation

var products: [Product] = [
    .library(name: "NightrCore", targets: ["NightrCore"]),
    .library(name: "NightrController", targets: ["NightrController"]),
    .library(name: "NightrMCP", targets: ["NightrMCP"]),
    .executable(name: "nightr-native", targets: ["NightrCLI"]),
    .executable(name: "NightrApp", targets: ["NightrApp"]),
    .executable(name: "NightrNetworkWorker", targets: ["NightrNetworkWorker"])
]
var targets: [Target] = [
    .target(name: "NightrCore"),
    .target(name: "NightrInstallProtocol"),
    .testTarget(name: "NightrInstallerTests", dependencies: ["NightrInstallProtocol"], path: "native-tests/NightrInstallerTests"),
    .target(name: "NightrController", dependencies: ["NightrCore"]),
    .target(name: "NightrMCP"),
    .target(name: "NightrMCPController", dependencies: ["NightrMCP", "NightrCore", "NightrController"]),
    .testTarget(name: "NightrMCPTests", dependencies: ["NightrMCP", "NightrMCPController", "NightrCore", "NightrController"], path: "native-tests/NightrMCPTests"),
    .target(name: "NightrPowerProtocol"),
    .target(name: "NightrPowerClient", dependencies: ["NightrPowerProtocol"]),
    .target(name: "NightrPlatform", dependencies: ["NightrCore", "NightrController", "NightrPowerClient", "NightrPowerProtocol"]),
    .executableTarget(name: "NightrApp", dependencies: ["NightrCore", "NightrController", "NightrPlatform", "NightrPowerClient"]),
    .executableTarget(name: "NightrNetworkWorker", dependencies: ["NightrPlatform"]),
    .executableTarget(name: "NightrCLI", dependencies: ["NightrCore", "NightrController", "NightrPlatform", "NightrMCP", "NightrMCPController", "NightrPowerClient"]),
    .testTarget(name: "NightrPlatformTests", dependencies: ["NightrPlatform", "NightrCore"], path: "native-tests/NightrPlatformTests"),
    .testTarget(name: "NightrPowerTests", dependencies: ["NightrPowerProtocol", "NightrPowerClient"], path: "native-tests/NightrPowerTests"),
    .testTarget(name: "NightrCoreTests", dependencies: ["NightrCore", "NightrController"], path: "native-tests/NightrCoreTests")
]
#if os(macOS)
let helperInfo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("packaging/helper-Info.plist").path
products.append(.executable(name: "NightrPowerHelper", targets: ["NightrPowerHelper"]))
products.append(.executable(name: "NightrInstallerGuard", targets: ["NightrInstallerGuard"]))
targets.append(.executableTarget(name: "NightrInstallerGuard", dependencies: ["NightrInstallProtocol"]))
targets.append(.executableTarget(name: "NightrPowerHelper", dependencies: ["NightrPowerProtocol", "NightrPowerClient"], linkerSettings: [
    .unsafeFlags(["-Xlinker", "-sectcreate", "-Xlinker", "__TEXT", "-Xlinker", "__info_plist", "-Xlinker", helperInfo])
]))
#endif
let package = Package(name: "Nightr", platforms: [.macOS(.v13)], products: products, targets: targets)
