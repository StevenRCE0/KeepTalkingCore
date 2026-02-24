import Foundation
import OpenAI

public struct KeepTalkingActionToolDefinition: Sendable, Hashable {
    public let functionName: String
    public let actionID: UUID
    public let ownerNodeID: UUID
    public let description: String
    public let parameters: JSONSchema

    public init(
        functionName: String,
        actionID: UUID,
        ownerNodeID: UUID,
        description: String,
        parameters: JSONSchema
    ) {
        self.functionName = functionName
        self.actionID = actionID
        self.ownerNodeID = ownerNodeID
        self.description = description
        self.parameters = parameters
    }

    public var openAITool: ChatQuery.ChatCompletionToolParam {
        .init(
            function: .init(
                name: functionName,
                description: description,
                parameters: parameters,
                strict: false
            )
        )
    }

    public static func normalizedFunctionName(
        ownerNodeID: UUID,
        actionID: UUID
    ) -> String {
        let owner = ownerNodeID.uuidString
            .replacingOccurrences(of: "-", with: "")
            .lowercased()
        let action = actionID.uuidString
            .replacingOccurrences(of: "-", with: "")
            .lowercased()
        // Must stay <= 64 chars for OpenAI function names.
        return "kt_\(owner.prefix(24))_\(action.prefix(24))"
    }

    public static var permissiveObjectParameters: JSONSchema {
        JSONSchema(
            .type(.object),
            .additionalProperties(.boolean(true))
        )
    }
}

public struct KeepTalkingActionToolCatalog: Sendable {
    public let definitions: [KeepTalkingActionToolDefinition]
    private let byFunctionName: [String: KeepTalkingActionToolDefinition]

    public init(definitions: [KeepTalkingActionToolDefinition]) {
        self.definitions = definitions
        self.byFunctionName = definitions.reduce(into: [:]) { partial, item in
            partial[item.functionName] = item
        }
    }

    public var openAITools: [ChatQuery.ChatCompletionToolParam] {
        definitions.map(\.openAITool)
    }

    public func definition(functionName: String)
        -> KeepTalkingActionToolDefinition?
    {
        byFunctionName[functionName]
    }
}
