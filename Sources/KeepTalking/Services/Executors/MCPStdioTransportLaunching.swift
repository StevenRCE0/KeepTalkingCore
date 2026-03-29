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
    let transport: any Transport
    public let processHandler: any MCPStdioProcessHandling

    public init(
        transport: any Transport,
        processHandler: any MCPStdioProcessHandling
    ) {
        self.transport = transport
        self.processHandler = processHandler
    }

    public init(
        inputFileDescriptor: Int32,
        outputFileDescriptor: Int32,
        processHandler: any MCPStdioProcessHandling
    ) {
        self.init(
            transport: StdioTransport(
                input: FileDescriptor(rawValue: inputFileDescriptor),
                output: FileDescriptor(rawValue: outputFileDescriptor)
            ),
            processHandler: processHandler
        )
    }
}

public protocol MCPStdioTransportLaunching: Sendable {
    func launchTransport(
        command: [String],
        environment: [String: String],
        stderrHandler: @escaping @Sendable (Data) -> Void
    ) async throws -> MCPStdioTransportHandle
}
