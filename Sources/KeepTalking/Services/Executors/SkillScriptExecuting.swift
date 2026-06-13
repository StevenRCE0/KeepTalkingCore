import Foundation

public struct SkillScriptExecutionResult: Sendable {
    public let command: [String]
    public let exitCode: Int32
    public let stdout: String
    public let stderr: String

    public init(
        command: [String],
        exitCode: Int32,
        stdout: String,
        stderr: String
    ) {
        self.command = command
        self.exitCode = exitCode
        self.stdout = stdout
        self.stderr = stderr
    }
}

#if os(macOS)
public protocol SkillScriptExecuting: Sendable {
    /// Runs an arbitrary command LINE through a real shell under the sandbox — the
    /// agent's sole execution primitive now that per-declared-script tools are
    /// retired (a genuine shell, so resource handles, pipes, and redirections
    /// expand natively). The configured timeout is the patient-wait grace period,
    /// not a hard kill.
    func runShellCommand(
        command: String,
        currentDirectory: URL,
        environment: [String: String],
        actionID: UUID,
        timeoutSeconds: TimeInterval,
        sandboxPolicy: KTSandboxPolicy?
    ) async throws -> SkillScriptExecutionResult
}
#else
/// No script execution off macOS (sandbox-exec is macOS-only); the executor is
/// `nil` on other platforms. Empty by design — see task to extend to Linux.
public protocol SkillScriptExecuting: Sendable {}
#endif

public enum DefaultSkillScriptExecutor {
    public static var current: (any SkillScriptExecuting)? {
        currentExecutor
    }
}
