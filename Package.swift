// swift-tools-version: 6.1
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "KeepTalking",
    platforms: [
        // iOS 17.5 is the vendored iroh xcframework's floor (IrohLib); macOS 15
        // is gRPC Swift 2's, which the plugin host's wire needs.
        .iOS("17.5"),
        .macOS(.v15),
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
        // The transport. Vendored iroh-ffi (fork StevenRCE0/iroh-ffi, main): Swift
        // bindings plus a locally built xcframework
        // (`RUSTUP_TOOLCHAIN=stable ./make_swift.sh`). Apple-only, so the SDK
        // takes it conditionally; elsewhere clients get
        // `KeepTalkingTransport.unavailable`. See Transport/Iroh.
        .package(path: "../iroh-ffi"),
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.65.0"),
        // The plugin host's wire (KTPP v2): gRPC over a Unix domain socket with
        // a JSON codec — no protobuf. Desktop-only, so the SDK takes it
        // conditionally and iOS/visionOS never build or link it. See
        // Services/PluginHost/Wire.
        .package(url: "https://github.com/grpc/grpc-swift-2.git", from: "2.4.0"),
        .package(url: "https://github.com/grpc/grpc-swift-nio-transport.git", from: "2.10.0"),
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
                .product(
                    name: "IrohLib",
                    package: "iroh-ffi",
                    condition: .when(platforms: [.iOS, .macOS])
                ),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "UUIDV7", package: "swift-uuidv7"),
                .product(
                    name: "GRPCCore",
                    package: "grpc-swift-2",
                    condition: .when(platforms: [.macOS, .linux])
                ),
                .product(
                    name: "GRPCNIOTransportHTTP2Posix",
                    package: "grpc-swift-nio-transport",
                    condition: .when(platforms: [.macOS, .linux])
                ),
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
                .product(
                    name: "GRPCCore",
                    package: "grpc-swift-2",
                    condition: .when(platforms: [.macOS, .linux])
                ),
                .product(
                    name: "GRPCNIOTransportHTTP2Posix",
                    package: "grpc-swift-nio-transport",
                    condition: .when(platforms: [.macOS, .linux])
                ),
            ],
            path: "Tests/KeepTalkingSDKTests"
        ),
    ]
)
