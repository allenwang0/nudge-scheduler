// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "nudge-scheduler",
    platforms: [.macOS(.v13), .iOS(.v16)],
    products: [
        .library(name: "NudgeScheduler", targets: ["NudgeScheduler"]),
        .executable(name: "nudge-sim", targets: ["nudge-sim"]),
    ],
    targets: [
        .target(name: "NudgeScheduler"),
        .executableTarget(name: "nudge-sim", dependencies: ["NudgeScheduler"]),
        .testTarget(name: "NudgeSchedulerTests", dependencies: ["NudgeScheduler"]),
    ]
)
