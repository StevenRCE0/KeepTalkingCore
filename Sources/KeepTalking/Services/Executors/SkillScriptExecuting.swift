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

public protocol SkillScriptExecuting: Sendable {
    func runScript(
        scriptURL: URL,
        arguments: [String],
        currentDirectory: URL,
        actionID: UUID,
        timeoutSeconds: TimeInterval
    ) async throws -> SkillScriptExecutionResult
}

public enum DefaultSkillScriptExecutor {
    public static var current: (any SkillScriptExecuting)? {
        currentExecutor
    }
}
