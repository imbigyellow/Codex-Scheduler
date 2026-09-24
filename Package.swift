// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "CodexScheduler",
    platforms: [.macOS(.v13)],
    products: [.executable(name: "CodexScheduler", targets: ["CodexSchedulerApp"])],
    targets: [
        .target(name: "SchedulerCore"),
        .executableTarget(name: "CodexSchedulerApp", dependencies: ["SchedulerCore"]),
        .executableTarget(name: "SchedulerHelper", dependencies: ["SchedulerCore"]),
        .executableTarget(name: "SchedulerSelfTest", dependencies: ["SchedulerCore"])
    ]
)
