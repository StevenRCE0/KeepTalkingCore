#if os(macOS)
import Foundation

extension DefaultSkillScriptExecutor {
    static var currentExecutor: (any SkillScriptExecuting)? {
        Executor()
    }
}

private struct Executor: SkillScriptExecuting {
    func runScript(
        scriptURL: URL,
        arguments: [String],
        currentDirectory: URL,
        environment: [String: String],
        actionID: UUID,
        timeoutSeconds: TimeInterval,
        sandboxPolicy: KTSandboxPolicy?
    ) async throws -> SkillScriptExecutionResult {
        try await SkillScriptRunner.run(
            command: SkillScriptRunner.makeCommand(
                scriptURL: scriptURL,
                arguments: arguments
            ),
            currentDirectory: currentDirectory,
            environment: environment,
            actionID: actionID,
            timeoutSeconds: timeoutSeconds,
            sandboxPolicy: sandboxPolicy
        )
    }
}
#endif
