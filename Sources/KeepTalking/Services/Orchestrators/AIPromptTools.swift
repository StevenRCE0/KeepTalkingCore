import Foundation

/// The tools the system prompt refers to by function name.
public enum AIPromptTool: String, Sendable, Hashable, CaseIterable {
    case runAction
    case skillMetainfo
    case attachmentListing
    case attachmentReader
    case searchThreads
    case markTurningPoint
    case markChitterChatter
}

/// Maps each `AIPromptTool` the prompt mentions to the function name the
/// model will see for it.
public struct AIPromptToolNames: Sendable, Equatable {
    public var names: [AIPromptTool: String]

    public init(_ names: [AIPromptTool: String]) {
        self.names = names
    }

    public subscript(tool: AIPromptTool) -> String {
        get {
            guard let name = names[tool] else {
                preconditionFailure("No function name registered for prompt tool \(tool)")
            }
            return name
        }
        set { names[tool] = newValue }
    }
}
