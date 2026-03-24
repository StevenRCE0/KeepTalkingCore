#if !os(iOS) && !os(tvOS) && !os(watchOS) && !os(visionOS)
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
        actionID: UUID,
        timeoutSeconds: TimeInterval
    ) async throws -> SkillScriptExecutionResult {
        try await SkillScriptRunner.run(
            command: SkillScriptRunner.makeCommand(
                scriptURL: scriptURL,
                arguments: arguments
            ),
            currentDirectory: currentDirectory,
            actionID: actionID,
            timeoutSeconds: timeoutSeconds
        )
    }
}
#endif
