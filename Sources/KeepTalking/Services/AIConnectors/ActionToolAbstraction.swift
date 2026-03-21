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
    public let supportsWakeAssist: Bool
    public let description: String
    public let parameters: JSONSchema

    public init(
        functionName: String,
        actionID: UUID,
        ownerNodeID: UUID,
        source: Source,
        mcpToolName: String? = nil,
        supportsWakeAssist: Bool = false,
        description: String,
        parameters: JSONSchema
    ) {
        self.functionName = functionName
        self.actionID = actionID
        self.ownerNodeID = ownerNodeID
        self.source = source
        self.mcpToolName = mcpToolName
        self.supportsWakeAssist = supportsWakeAssist
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
        // Keep deterministic and compact while still carrying an explicit
        // action tag so names remain consistent across catalog rebuilds.
        let owner = compactIdentifier(ownerNodeID, prefixLength: 20)
        let action = compactIdentifier(actionID, prefixLength: 20)
        let shortAction = shortActionID(actionID)
        var normalized = "kt_\(owner.prefix(20))_\(action.prefix(20))_\(shortAction)"

        if let mcpToolName {
            let cleaned =
                mcpToolName
                .lowercased()
                .map { $0.isLetter || $0.isNumber ? $0 : "_" }
            let prefix = String(cleaned.prefix(5))
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

    public static func shortActionID(_ actionID: UUID) -> String {
        compactIdentifier(actionID, prefixLength: 8)
    }

    public static func shortNodeID(_ nodeID: UUID) -> String {
        compactIdentifier(nodeID, prefixLength: 8)
    }

    public static func routedActionName(
        _ rawName: String,
        actionID: UUID,
        fallbackPrefix: String = "action"
    ) -> String {
        let trimmed = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        let shortID = shortActionID(actionID)
        let suffix = "__\(shortID)"
        if trimmed.isEmpty {
            return "\(fallbackPrefix)_\(shortID)"
        }
        if trimmed.hasSuffix(suffix) {
            return trimmed
        }
        return "\(trimmed)\(suffix)"
    }

    public static func unroutedActionName(
        _ routedName: String,
        actionID: UUID
    ) -> String {
        let trimmed = routedName.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        let suffix = "__\(shortActionID(actionID))"
        guard trimmed.hasSuffix(suffix) else {
            return trimmed
        }
        return String(trimmed.dropLast(suffix.count))
    }

    public static func routedUserNodeName(
        _ nodeID: UUID,
        alias: String? = nil
    ) -> String {
        let trimmedAlias = alias?.trimmingCharacters(in: .whitespacesAndNewlines)
        let shortID = shortNodeID(nodeID)
        if let trimmedAlias, !trimmedAlias.isEmpty {
            let suffix = "__\(shortID)"
            if trimmedAlias.hasSuffix(suffix) {
                return trimmedAlias
            }
            return "\(trimmedAlias)\(suffix)"
        }
        return "node_\(shortID)"
    }

    public static func conversationSenderTag(
        _ sender: KeepTalkingContextMessage.Sender,
        nodeAliasResolver: ((UUID) -> String?)? = nil
    ) -> String {
        switch sender {
            case .node(let nodeID):
                return "user:\(routedUserNodeName(nodeID, alias: nodeAliasResolver?(nodeID)))"
            case .autonomous(let name):
                return "agent:\(name)"
        }
    }

    private static func compactIdentifier(
        _ id: UUID,
        prefixLength: Int
    ) -> String {
        String(
            id.uuidString
                .replacingOccurrences(of: "-", with: "")
                .lowercased()
                .prefix(prefixLength)
        )
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
