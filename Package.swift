// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AgentAwake",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "AgentAwake", targets: ["AgentAwake"]),
        .executable(name: "agent-awake-hook", targets: ["AgentAwakeHook"]),
        .executable(name: "agent-awake-helper", targets: ["AgentAwakeHelper"])
    ],
    targets: [
        .target(name: "ProcessSupport"),
        .target(name: "AwakeCore", dependencies: ["ProcessSupport"]),
        .executableTarget(name: "AgentAwake", dependencies: ["AwakeCore"]),
        .executableTarget(name: "AgentAwakeHook", dependencies: ["AwakeCore"]),
        .executableTarget(name: "AgentAwakeHelper", dependencies: ["AwakeCore"]),
        .executableTarget(name: "AwakeCoreChecks", dependencies: ["AwakeCore"], path: "Tests/AwakeCoreTests")
    ],
    swiftLanguageModes: [.v5]
)
