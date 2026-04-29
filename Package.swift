// swift-tools-version: 6.1
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "KeepTalking",
    platforms: [
        .iOS(.v17),
        .macOS(.v13),
        .visionOS(.v1),
    ],
    products: [
        .library(name: "KeepTalkingSDK", targets: ["KeepTalkingSDK"]),
        .executable(name: "KeepTalking", targets: ["KeepTalking"]),
    ],
    dependencies: [
        .package(
            url: "https://github.com/livekit/webrtc-xcframework.git",
            exact: "137.7151.12"
        ),
        .package(
            url: "https://github.com/vapor/fluent-kit.git",
            from: "1.55.0"
        ),
        .package(
            url: "https://github.com/vapor/fluent-sqlite-driver.git",
            from: "4.6.0"
        ),
        .package(
            url: "https://github.com/modelcontextprotocol/swift-sdk.git",
            from: "0.12.0"
        ),
        // KeepTalking-only fork of AIProxySwift, slimmed for multiplatform use.
        // See ./MIGRATION_AIPROXY.md for context. Local path during the migration;
        // switch to a Git URL + tag before any release.
        .package(
            name: "AIProxyMultiPlatform",
            path: "../AIProxySwift-MultiPlatform"
        ),
    ],
    targets: [
        .target(
            name: "KeepTalkingSDK",
            dependencies: [
                .product(name: "LiveKitWebRTC", package: "webrtc-xcframework"),
                .product(name: "FluentKit", package: "fluent-kit"),
                .product(
                    name: "FluentSQLiteDriver",
                    package: "fluent-sqlite-driver"
                ),
                .product(name: "MCP", package: "swift-sdk"),
                .product(name: "AIProxy", package: "AIProxyMultiPlatform"),
            ],
            path: "Sources/KeepTalking"
        ),
        .executableTarget(
            name: "KeepTalking",
            dependencies: [
                "KeepTalkingSDK"
            ],
            path: "Sources/KeepTalkingCLI"
        ),
        .testTarget(
            name: "KeepTalkingSDKTests",
            dependencies: [
                "KeepTalkingSDK"
            ],
            path: "Tests/KeepTalkingSDKTests"
        ),
    ]
)
