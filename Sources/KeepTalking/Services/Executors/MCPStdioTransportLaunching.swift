import Foundation
import MCP

#if canImport(System)
    import System
#else
    @preconcurrency import SystemPackage
#endif

public protocol MCPStdioProcessHandling: Sendable {
    func terminationStatus() -> Int32?
    func terminate()
}

public struct MCPStdioTransportHandle: Sendable {
    let transport: StdioTransport
    public let processHandler: any MCPStdioProcessHandling

    public init(
        inputFileDescriptor: Int32,
        outputFileDescriptor: Int32,
        processHandler: any MCPStdioProcessHandling
    ) {
        self.transport = StdioTransport(
            input: FileDescriptor(rawValue: inputFileDescriptor),
            output: FileDescriptor(rawValue: outputFileDescriptor)
        )
        self.processHandler = processHandler
    }
}

public protocol MCPStdioTransportLaunching: Sendable {
    func launchTransport(
        command: [String],
        environment: [String: String],
        stderrHandler: @escaping @Sendable (Data) -> Void
    ) async throws -> MCPStdioTransportHandle
}
