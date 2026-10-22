// swift-tools-version: 6.2
import PackageDescription

// Core logic (history migration, provider configuration, portable sync merge)
// is compiled directly into the iOS app and tested here on macOS.
let package = Package(
    name: "PocketAgentCore",
    platforms: [.macOS(.v15), .iOS(.v26)],
    products: [.library(name: "PocketAgentCore", targets: ["PocketAgentCore"])],
    dependencies: [
        .package(url: "https://github.com/Borealin/AgentKit.git",
                 revision: "e1c81c911564c39d5f78ccec6808ba96c1acd2e8"),
    ],
    targets: [
        .target(
            name: "PocketAgentCore",
            dependencies: [.product(name: "AgentKit", package: "AgentKit")],
            path: "App/Core",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "PocketAgentCoreTests",
            dependencies: ["PocketAgentCore"],
            path: "Tests/PocketAgentCoreTests",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
