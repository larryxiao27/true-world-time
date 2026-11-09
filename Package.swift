// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "TrueWorldTimeProbe",
    platforms: [.macOS(.v15)],
    products: [.library(name: "ClockCore", targets: ["ClockCore"]), .executable(name: "clock-probe", targets: ["ClockProbeCLI"])],
    targets: [
        .target(name: "ClockCore"),
        .executableTarget(name: "ClockProbeCLI", dependencies: ["ClockCore"]),
        .testTarget(name: "ClockCoreTests", dependencies: ["ClockCore"])
    ]
)
