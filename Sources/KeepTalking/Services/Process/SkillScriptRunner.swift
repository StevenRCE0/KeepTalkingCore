#if !os(iOS) && !os(tvOS) && !os(watchOS) && !os(visionOS)
import Foundation

public enum SkillScriptRunner {
    public static func makeCommand(
        scriptURL: URL,
        arguments: [String]
    ) -> [String] {
        let path = scriptURL.path
        switch scriptURL.pathExtension.lowercased() {
            case "py":
                return ["/usr/bin/env", "python3", path] + arguments
            case "sh", "command":
                return ["/bin/zsh", path] + arguments
            default:
                if FileManager.default.isExecutableFile(atPath: path) {
                    return [path] + arguments
                }
                return ["/bin/zsh", path] + arguments
        }
    }

    public static func run(
        command: [String],
        currentDirectory: URL,
        actionID: UUID,
        timeoutSeconds: TimeInterval
    ) async throws -> SkillScriptExecutionResult {
        guard let executable = command.first else {
            return SkillScriptExecutionResult(
                command: [],
                exitCode: 2,
                stdout: "",
                stderr: "Missing command executable."
            )
        }

        let processBox = SkillScriptProcessBox()
        return try await withTaskCancellationHandler {
            try await run(
                process: processBox.process,
                executable: executable,
                command: command,
                currentDirectory: currentDirectory,
                actionID: actionID,
                timeoutSeconds: timeoutSeconds
            )
        } onCancel: {
            terminateProcessIfRunning(processBox.process)
        }
    }

    private enum Outcome: Sendable {
        case exited(Int32)
        case timedOut
    }

    private final class SkillScriptProcessBox: @unchecked Sendable {
        let process = Process()
    }

    private static func run(
        process: Process,
        executable: String,
        command: [String],
        currentDirectory: URL,
        actionID: UUID,
        timeoutSeconds: TimeInterval
    ) async throws -> SkillScriptExecutionResult {
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = Array(command.dropFirst())
        process.currentDirectoryURL = currentDirectory
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        process.environment =
            DefaultProcessExecutionSupport
            .mergedEnvironment(
                for: command,
                environment: [:]
            )

        async let stdoutData = DefaultProcessExecutionSupport.readToEnd(
            stdoutPipe.fileHandleForReading
        )
        async let stderrData = DefaultProcessExecutionSupport.readToEnd(
            stderrPipe.fileHandleForReading
        )

        let timeoutNanos = UInt64(max(timeoutSeconds, 1) * 1_000_000_000)
        let exitCode: Int32
        do {
            let outcome = try await withThrowingTaskGroup(of: Outcome.self) {
                group in
                group.addTask {
                    let status = try await withCheckedThrowingContinuation {
                        (
                            continuation: CheckedContinuation<Int32, Error>
                        ) in
                        process.terminationHandler = { process in
                            continuation.resume(
                                returning: process.terminationStatus
                            )
                        }
                        do {
                            try process.run()
                            stdoutPipe.fileHandleForWriting.closeFile()
                            stderrPipe.fileHandleForWriting.closeFile()
                        } catch {
                            continuation.resume(throwing: error)
                        }
                    }
                    return .exited(status)
                }

                group.addTask {
                    try await Task.sleep(nanoseconds: timeoutNanos)
                    requestProcessTermination(process)
                    return .timedOut
                }

                guard let result = try await group.next() else {
                    throw SkillManagerError.toolCallTimedOut(
                        actionID,
                        timeoutSeconds
                    )
                }
                group.cancelAll()
                return result
            }

            switch outcome {
                case .exited(let status):
                    exitCode = status
                case .timedOut:
                    throw SkillManagerError.toolCallTimedOut(
                        actionID,
                        timeoutSeconds
                    )
            }
        } catch {
            terminateProcessIfRunning(process)
            _ = try? await stdoutData
            _ = try? await stderrData
            throw error
        }

        return SkillScriptExecutionResult(
            command: command,
            exitCode: exitCode,
            stdout: DefaultProcessExecutionSupport.decode(
                data: try await stdoutData
            ),
            stderr: DefaultProcessExecutionSupport.decode(
                data: try await stderrData
            )
        )
    }

    private static func terminateProcessIfRunning(_ process: Process) {
        guard process.isRunning else {
            return
        }
        process.terminate()
        process.waitUntilExit()
    }

    private static func requestProcessTermination(_ process: Process) {
        guard process.isRunning else {
            return
        }
        process.terminate()
    }
}
#else
import Foundation

public enum SkillScriptRunner {
    public static func makeCommand(
        scriptURL: URL,
        arguments: [String]
    ) -> [String] {
        [scriptURL.path] + arguments
    }

    public static func run(
        command _: [String],
        currentDirectory _: URL,
        actionID _: UUID,
        timeoutSeconds _: TimeInterval
    ) async throws -> SkillScriptExecutionResult {
        throw SkillManagerError.scriptExecutionUnavailableOnThisPlatform
    }
}
#endif
