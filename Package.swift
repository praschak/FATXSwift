// swift-tools-version: 5.9
import PackageDescription
var products: [Product] = [
    .library(name: "FATXCore", targets: ["FATXCore"]),
    .executable(name: "fatx", targets: ["fatx"]),
    .executable(name: "fatxbridge", targets: ["fatxbridge"])
]
var targets: [Target] = [
    .target(name: "CFATXPlatform", linkerSettings: [.linkedLibrary("proc", .when(platforms: [.macOS]))]),
    .target(name: "FATXCore", dependencies: ["CFATXPlatform"]),
    .target(name: "FATXService", dependencies: ["FATXCore", "CFATXPlatform"]),
    .executableTarget(name: "fatx", dependencies: ["FATXCore", "FATXService"]),
    .executableTarget(name: "fatxbridge", dependencies: ["FATXService"]),
    .testTarget(name: "FATXCoreTests", dependencies: ["FATXCore"]),
    .testTarget(name: "FATXServiceTests", dependencies: ["FATXService", "FATXCore"])
]
#if os(macOS)
products.append(.executable(name: "FATXBrowser", targets: ["FATXBrowser"]))
products.append(.executable(name: "FATXSecurityProbe", targets: ["FATXSecurityProbe"]))
targets.append(.executableTarget(name: "FATXSecurityProbe", dependencies: ["FATXCore", "FATXService"], linkerSettings: [.linkedFramework("IOKit"), .linkedFramework("IOUSBHost")]))
targets.append(.executableTarget(name: "FATXBrowser", dependencies: ["FATXService"], linkerSettings: [.linkedFramework("Security")]))
#endif
let package = Package(
    name: "FATXSwift",
    platforms: [.macOS(.v13)],
    products: products,
    targets: targets
)
