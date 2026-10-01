// swift-tools-version: 6.1
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "KeepTalking",
    platforms: [
        // 17.5 / 14.5 are the vendored iroh xcframework's floors (IrohLib).
        .iOS("17.5"),
        .macOS("14.5"),
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
        // Already transitive through the driver; declared so the SDK can name
        // `SQLDatabase` (the wrapper must conform, see DatabaseActivity.swift)
        // and run raw SQL for indexes and pragmas.
        .package(url: "https://github.com/vapor/sql-kit.git", from: "3.34.0"),
        .package(
            url: "https://github.com/modelcontextprotocol/swift-sdk.git",
            from: "0.12.0"
        ),
        .package(path: "../AIProxySwift-MultiPlatform"),
        .package(path: "../KeepTalkingSFU"),
        // Vendored iroh-ffi (fork StevenRCE0/iroh-ffi, main): Swift bindings plus a
        // locally built xcframework (`RUSTUP_TOOLCHAIN=stable ./make_swift.sh`).
        // Apple-only, so the SDK takes it conditionally; see Transport/Iroh.
        .package(path: "../iroh-ffi"),
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
                .product(name: "SQLKit", package: "sql-kit"),
                .product(name: "MCP", package: "swift-sdk"),
                .product(name: "AIProxy", package: "AIProxySwift-MultiPlatform"),
                .product(name: "KeepTalkingSFUClient", package: "KeepTalkingSFU"),
                .product(name: "KeepTalkingSFUProtocol", package: "KeepTalkingSFU"),
                .product(name: "SwiftJUICE", package: "swift-libjuice"),
                .product(
                    name: "IrohLib",
                    package: "iroh-ffi",
                    condition: .when(platforms: [.iOS, .macOS])
                ),
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
                .product(name: "FluentKit", package: "fluent-kit"),
            ],
            path: "Sources/KeepTalkingCLI"
        ),
        // Internal tooling, not a public product: regenerates
        // Schemas/keeptalking-provision.schema.json from KeepTalkingProvisionBundle.
        // Run with `swift run GenerateProvisionSchema`.
        .executableTarget(
            name: "GenerateProvisionSchema",
            dependencies: ["KeepTalkingSDK"],
            path: "Sources/GenerateProvisionSchema"
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
