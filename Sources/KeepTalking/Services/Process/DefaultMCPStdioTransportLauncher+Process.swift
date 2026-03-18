#if !os(iOS) && !os(tvOS) && !os(watchOS) && !os(visionOS)
import Foundation

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
        let mergedEnvironment = DefaultProcessExecutionSupport
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

        return MCPStdioTransportHandle(
            inputFileDescriptor: stdoutPipe.fileHandleForReading.fileDescriptor,
            outputFileDescriptor: stdinPipe.fileHandleForWriting.fileDescriptor,
            processHandler: DefaultMCPStdioProcessHandler(
                process: process,
                stdinPipe: stdinPipe,
                stdoutPipe: stdoutPipe,
                stderrPipe: stderrPipe,
                exitState: exitState
            )
        )
    }
}
#endif
