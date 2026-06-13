#if os(macOS)
import Foundation

extension DefaultSkillScriptExecutor {
    static var currentExecutor: (any SkillScriptExecuting)? {
        Executor()
    }
}

private struct Executor: SkillScriptExecuting {
    func runShellCommand(
        command: String,
        currentDirectory: URL,
        environment: [String: String],
        actionID: UUID,
        timeoutSeconds: TimeInterval,
        sandboxPolicy: KTSandboxPolicy?
    ) async throws -> SkillScriptExecutionResult {
        try await SandboxedProcessRunner.runShell(
            command: command,
            currentDirectory: currentDirectory,
            environment: environment,
            actionID: actionID,
            graceSeconds: timeoutSeconds,
            sandboxPolicy: sandboxPolicy
        )
    }
}
#endif
