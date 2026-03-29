#if !os(iOS) && !os(tvOS) && !os(watchOS) && !os(visionOS)
import Foundation
import Logging
import MCP

extension DefaultMCPStdioTransportLauncher {
    static var currentLauncher: (any MCPStdioTransportLaunching)? {
        Launcher()
    }
}

private final class DefaultMCPStdioProcessHandler:
    @unchecked Sendable,
    MCPStdioProcessHandling
{
    private let process: Process
    private let stdinPipe: Pipe
    private let stdoutPipe: Pipe
    private let stderrPipe: Pipe
    private let exitState: DefaultProcessExitState

    init(
        process: Process,
        stdinPipe: Pipe,
        stdoutPipe: Pipe,
        stderrPipe: Pipe,
        exitState: DefaultProcessExitState
    ) {
        self.process = process
        self.stdinPipe = stdinPipe
        self.stdoutPipe = stdoutPipe
        self.stderrPipe = stderrPipe
        self.exitState = exitState
    }

    func terminationStatus() -> Int32? {
        exitState.snapshot()
    }

    func terminate() {
        if process.isRunning {
            process.terminate()
            process.waitUntilExit()
        }
        stdinPipe.fileHandleForWriting.closeFile()
        stdoutPipe.fileHandleForReading.closeFile()
        stderrPipe.fileHandleForReading.readabilityHandler = nil
        stderrPipe.fileHandleForReading.closeFile()
    }
}

private struct Launcher: MCPStdioTransportLaunching {
    func launchTransport(
        command: [String],
        environment: [String: String],
        stderrHandler: @escaping @Sendable (Data) -> Void
    ) async throws -> MCPStdioTransportHandle {
        let process = Process()
        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        let exitState = DefaultProcessExitState()
        let mergedEnvironment =
            DefaultProcessExecutionSupport
            .mergedEnvironment(
                for: command,
                environment: environment
            )

        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = command
        process.environment = mergedEnvironment
        process.terminationHandler = { process in
            exitState.set(status: process.terminationStatus)
        }

        stderrPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                handle.readabilityHandler = nil
                return
            }
            stderrHandler(data)
        }

        do {
            try process.run()
        } catch {
            stderrPipe.fileHandleForReading.readabilityHandler = nil
            DefaultMCPStdioProcessHandler(
                process: process,
                stdinPipe: stdinPipe,
                stdoutPipe: stdoutPipe,
                stderrPipe: stderrPipe,
                exitState: exitState
            ).terminate()
            throw error
        }

        stdinPipe.fileHandleForReading.closeFile()
        stdoutPipe.fileHandleForWriting.closeFile()
        stderrPipe.fileHandleForWriting.closeFile()

        let processHandler = DefaultMCPStdioProcessHandler(
            process: process,
            stdinPipe: stdinPipe,
            stdoutPipe: stdoutPipe,
            stderrPipe: stderrPipe,
            exitState: exitState
        )

        return MCPStdioTransportHandle(
            transport: MCPPipeTransport(
                inputHandle: stdoutPipe.fileHandleForReading,
                outputHandle: stdinPipe.fileHandleForWriting
            ),
            processHandler: processHandler
        )
    }
}

private actor MCPPipeTransport: Transport {
    nonisolated let logger: Logger

    private let inputHandle: FileHandle
    private let outputHandle: FileHandle
    private var isConnected = false
    private var pendingData = Data()
    private let messageStream: AsyncThrowingStream<Data, Swift.Error>
    private let messageContinuation: AsyncThrowingStream<Data, Swift.Error>.Continuation

    init(
        inputHandle: FileHandle,
        outputHandle: FileHandle,
        logger: Logger? = nil
    ) {
        self.inputHandle = inputHandle
        self.outputHandle = outputHandle
        self.logger =
            logger
            ?? Logger(label: "keepTalking.transport.pipe") { _ in
                SwiftLogNoOpLogHandler()
            }

        var continuation: AsyncThrowingStream<Data, Swift.Error>.Continuation!
        self.messageStream = AsyncThrowingStream { continuation = $0 }
        self.messageContinuation = continuation
    }

    func connect() async throws {
        guard !isConnected else {
            return
        }

        isConnected = true
        inputHandle.readabilityHandler = { [weak inputHandle] handle in
            let data = handle.availableData
            Task {
                await self.handleReadableData(data)
                if data.isEmpty {
                    inputHandle?.readabilityHandler = nil
                }
            }
        }
    }

    func disconnect() async {
        guard isConnected else {
            return
        }
        isConnected = false
        inputHandle.readabilityHandler = nil
        messageContinuation.finish()
    }

    func send(_ data: Data) async throws {
        guard isConnected else {
            throw MCPError.internalError("Pipe transport is not connected")
        }

        var payload = data
        payload.append(UInt8(ascii: "\n"))
        try outputHandle.write(contentsOf: payload)
    }

    func receive() -> AsyncThrowingStream<Data, Swift.Error> {
        messageStream
    }

    private func handleReadableData(_ data: Data) async {
        guard isConnected else {
            return
        }

        if data.isEmpty {
            inputHandle.readabilityHandler = nil
            messageContinuation.finish()
            return
        }

        pendingData.append(data)

        while let message = extractNextMessage() {
            messageContinuation.yield(message)
        }
    }

    private func extractNextMessage() -> Data? {
        if let newlineIndex = pendingData.firstIndex(of: UInt8(ascii: "\n")) {
            let messageData = pendingData[..<newlineIndex]
            pendingData.removeSubrange(...newlineIndex)
            guard !messageData.isEmpty else {
                return extractNextMessage()
            }
            return Data(messageData)
        }

        guard !pendingData.isEmpty else {
            return nil
        }

        if isCompleteJSONMessage(pendingData) {
            defer { pendingData.removeAll(keepingCapacity: true) }
            return pendingData
        }

        return nil
    }

    private func isCompleteJSONMessage(_ data: Data) -> Bool {
        do {
            _ = try JSONSerialization.jsonObject(with: data)
            return true
        } catch {
            return false
        }
    }
}
#endif
