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
        .package(path: "../AIProxySwift-MultiPlatform"),
        .package(path: "../KeepTalkingSFU"),
        .package(url: "https://github.com/StevenRCE0/swift-libjuice.git", from: "1.7.1"),
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.65.0"),
        .package(url: "https://github.com/apple/swift-nio-http2.git", from: "1.30.0"),
        .package(url: "https://github.com/apple/swift-nio-ssl.git", from: "2.27.0"),
        .package(url: "https://github.com/apple/swift-certificates.git", from: "1.0.0"),
        .package(url: "https://github.com/apple/swift-asn1.git", from: "1.0.0"),
        // swift-crypto is the canonical crypto layer so the SDK is Apple-free.
        .package(url: "https://github.com/apple/swift-crypto.git", from: "3.0.0"),
        // swift-uuidv7: time-ordered (RFC 9562 v7) UUID generation used for
        // default primary keys on newly created entities. See Helpers/UUIDv7.swift.
        .package(url: "https://github.com/mhayes853/swift-uuidv7.git", from: "0.6.1"),
        // DocC catalog build: `swift package generate-documentation`.
        .package(url: "https://github.com/apple/swift-docc-plugin", from: "1.0.0"),
    ],
    targets: [
        .target(
            name: "KeepTalkingSDK",
            dependencies: [
                .product(name: "Crypto", package: "swift-crypto"),
                .product(name: "FluentKit", package: "fluent-kit"),
                .product(
                    name: "FluentSQLiteDriver",
                    package: "fluent-sqlite-driver"
                ),
                .product(name: "MCP", package: "swift-sdk"),
                .product(name: "AIProxy", package: "AIProxySwift-MultiPlatform"),
                .product(name: "KeepTalkingSFUClient", package: "KeepTalkingSFU"),
                .product(name: "KeepTalkingSFUProtocol", package: "KeepTalkingSFU"),
                .product(name: "SwiftJUICE", package: "swift-libjuice"),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "NIOFoundationCompat", package: "swift-nio"),
                .product(name: "NIOHTTP2", package: "swift-nio-http2"),
                .product(name: "NIOHPACK", package: "swift-nio-http2"),
                .product(name: "NIOSSL", package: "swift-nio-ssl"),
                .product(name: "X509", package: "swift-certificates"),
                .product(name: "SwiftASN1", package: "swift-asn1"),
                .product(name: "UUIDV7", package: "swift-uuidv7"),
            ],
            path: "Sources/KeepTalking"
        ),
        .executableTarget(
            name: "KeepTalking",
            dependencies: [
                "KeepTalkingSDK",
                .product(name: "MCP", package: "swift-sdk"),
            ],
            path: "Sources/KeepTalkingCLI"
        ),
        .testTarget(
            name: "KeepTalkingSDKTests",
            dependencies: [
                .product(name: "Crypto", package: "swift-crypto"),
                "KeepTalkingSDK",
            ],
            path: "Tests/KeepTalkingSDKTests"
        ),
    ]
)
