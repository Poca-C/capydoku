// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Capydoku",
    platforms: [.iOS(.v15), .macOS(.v12)],
    products: [
        .library(name: "CapydokuCore", targets: ["CapydokuCore"]),
        .executable(name: "CapydokuLevelTool", targets: ["CapydokuLevelTool"])
    ],
    targets: [
        .target(name: "CapydokuCore"),
        .executableTarget(name: "CapydokuLevelTool", dependencies: ["CapydokuCore"]),
        .testTarget(name: "CapydokuCoreTests", dependencies: ["CapydokuCore"])
    ]
)
