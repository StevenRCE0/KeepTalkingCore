import Foundation
import OpenAI

public struct KeepTalkingActionToolDefinition: Sendable, Hashable {
    public enum Source: String, Sendable, Hashable {
        case mcp
        case skill
        case primitive
    }

    public let functionName: String
    public let actionID: UUID
    public let ownerNodeID: UUID
    public let source: Source
    public let mcpToolName: String?
    public let description: String
    public let parameters: JSONSchema

    public init(
        functionName: String,
        actionID: UUID,
        ownerNodeID: UUID,
        source: Source,
        mcpToolName: String? = nil,
        description: String,
        parameters: JSONSchema
    ) {
        self.functionName = functionName
        self.actionID = actionID
        self.ownerNodeID = ownerNodeID
        self.source = source
        self.mcpToolName = mcpToolName
        self.description = description
        self.parameters = parameters
    }

    public var openAITool: OpenAITool {
        .functionTool(
            .init(
                name: functionName,
                description: description,
                parameters: parameters,
                strict: false
            )
        )
    }

    public static func normalizedFunctionName(
        ownerNodeID: UUID,
        actionID: UUID,
        mcpToolName: String? = nil
    ) -> String {
        let owner = ownerNodeID.uuidString
            .replacingOccurrences(of: "-", with: "")
            .lowercased()
        let action = actionID.uuidString
            .replacingOccurrences(of: "-", with: "")
            .lowercased()
        var normalized = "kt_\(owner.prefix(24))_\(action.prefix(24))"

        if let mcpToolName {
            let cleaned =
                mcpToolName
                .lowercased()
                .map { $0.isLetter || $0.isNumber ? $0 : "_" }
            let prefix = String(cleaned.prefix(6))
                .trimmingCharacters(in: CharacterSet(charactersIn: "_"))
            let checksum = String(
                format: "%04x",
                mcpToolName.utf8.reduce(UInt32(2_166_136_261)) { partial, byte in
                    (partial ^ UInt32(byte)) &* 16_777_619
                } & 0xffff
            )
            let token = prefix.isEmpty ? checksum : "\(prefix)_\(checksum)"
            if !token.isEmpty {
                // Keep OpenAI function name <= 64 chars.
                normalized += "_\(token)"
            }
        }

        return normalized
    }

    public static var permissiveObjectParameters: JSONSchema {
        JSONSchema(
            .type(.object),
            .properties([
                "tool": JSONSchema(
                    .type(.string),
                    .description(
                        "Target MCP tool name on the server. If omitted, defaults to action name."
                    )
                ),
                "arguments": JSONSchema(
                    .type(.object),
                    .description(
                        "Arguments object passed to the MCP tool."
                    ),
                    .properties([:]),
                    .additionalProperties(.boolean(true))
                ),
            ]),
            .additionalProperties(.boolean(true))
        )
    }
}

public struct KeepTalkingActionToolCatalog: Sendable {
    public let definitions: [KeepTalkingActionToolDefinition]

    public init(definitions: [KeepTalkingActionToolDefinition]) {
        self.definitions = definitions
    }

    public var openAITools: [OpenAITool] {
        definitions.map(\.openAITool)
    }

    public func definition(functionName: String)
        -> KeepTalkingActionToolDefinition?
    {
        definitions.first { $0.functionName == functionName }
    }
}
