import Foundation
import MCP
import OpenAI

extension KeepTalkingClient {
    func mcpProxyDefinitions(
        for action: KeepTalkingAction,
        ownerNodeID: UUID,
        bundle: KeepTalkingMCPBundle,
        remoteTools: [KeepTalkingActionCatalogMCPTool]
    ) async throws -> [KeepTalkingActionToolDefinition] {
        guard let actionID = action.id else {
            return []
        }

        if ownerNodeID != config.node {
            return mcpProxyDefinitionsForRemoteAction(
                actionID: actionID,
                ownerNodeID: ownerNodeID,
                action: action,
                bundle: bundle,
                remoteTools: remoteTools
            )
        }

        let tools = try await mcpManager.listActionTools(action: action).sorted {
            $0.name < $1.name
        }
        guard !tools.isEmpty else {
            return [
                KeepTalkingActionToolDefinition(
                    functionName:
                        KeepTalkingActionToolDefinition.normalizedFunctionName(
                            ownerNodeID: ownerNodeID,
                            actionID: actionID,
                            mcpToolName: bundle.name
                        ),
                    actionID: actionID,
                    ownerNodeID: ownerNodeID,
                    source: .mcp,
                    mcpToolName: bundle.name,
                    description:
                        action.descriptor?.action?.description
                        ?? bundle.indexDescription,
                    parameters: KeepTalkingActionToolDefinition
                        .permissiveObjectParameters
                )
            ]
        }

        let fallbackDescription =
            action.descriptor?.action?.description
            ?? bundle.indexDescription

        return tools.map { tool in
            let selectedToolName = tool.name.trimmingCharacters(
                in: .whitespacesAndNewlines
            )
            return KeepTalkingActionToolDefinition(
                functionName:
                    KeepTalkingActionToolDefinition.normalizedFunctionName(
                        ownerNodeID: ownerNodeID,
                        actionID: actionID,
                        mcpToolName: selectedToolName.isEmpty
                            ? nil
                            : selectedToolName
                    ),
                actionID: actionID,
                ownerNodeID: ownerNodeID,
                source: .mcp,
                mcpToolName: selectedToolName.isEmpty ? nil : selectedToolName,
                description: tool.description ?? fallbackDescription,
                parameters: openAIParameters(from: tool.inputSchema)
            )
        }
    }

    func mcpProxyDefinitionsForRemoteAction(
        actionID: UUID,
        ownerNodeID: UUID,
        action: KeepTalkingAction,
        bundle: KeepTalkingMCPBundle,
        remoteTools: [KeepTalkingActionCatalogMCPTool]
    ) -> [KeepTalkingActionToolDefinition] {
        let fallbackDescription =
            action.descriptor?.action?.description
            ?? bundle.indexDescription
        let sortedTools = remoteTools.sorted { $0.name < $1.name }

        guard !sortedTools.isEmpty else {
            return [
                KeepTalkingActionToolDefinition(
                    functionName:
                        KeepTalkingActionToolDefinition.normalizedFunctionName(
                            ownerNodeID: ownerNodeID,
                            actionID: actionID,
                            mcpToolName: bundle.name
                        ),
                    actionID: actionID,
                    ownerNodeID: ownerNodeID,
                    source: .mcp,
                    mcpToolName: bundle.name,
                    description: fallbackDescription,
                    parameters: KeepTalkingActionToolDefinition
                        .permissiveObjectParameters
                )
            ]
        }

        return sortedTools.map { tool in
            let selectedToolName = tool.name.trimmingCharacters(
                in: .whitespacesAndNewlines
            )
            return KeepTalkingActionToolDefinition(
                functionName:
                    KeepTalkingActionToolDefinition.normalizedFunctionName(
                        ownerNodeID: ownerNodeID,
                        actionID: actionID,
                        mcpToolName: selectedToolName.isEmpty
                            ? nil
                            : selectedToolName
                    ),
                actionID: actionID,
                ownerNodeID: ownerNodeID,
                source: .mcp,
                mcpToolName: selectedToolName.isEmpty ? nil : selectedToolName,
                description: tool.description ?? fallbackDescription,
                parameters: openAIParameters(from: tool.inputSchema)
            )
        }
    }

    func makeSkillActionProxyDefinition(
        actionID: UUID,
        ownerNodeID: UUID,
        bundle: KeepTalkingSkillBundle,
        descriptor: KeepTalkingActionDescriptor?
    ) -> KeepTalkingActionToolDefinition {
        let description =
            descriptor?.action?.description
            ?? bundle.indexDescription
        return KeepTalkingActionToolDefinition(
            functionName: KeepTalkingActionToolDefinition.normalizedFunctionName(
                ownerNodeID: ownerNodeID,
                actionID: actionID,
                mcpToolName: nil
            ),
            actionID: actionID,
            ownerNodeID: ownerNodeID,
            source: .skill,
            mcpToolName: nil,
            description: description,
            parameters: KeepTalkingActionToolDefinition.permissiveObjectParameters
        )
    }

    func makeSkillMetadataDefinition(
        actionID: UUID,
        ownerNodeID: UUID,
        bundle: KeepTalkingSkillBundle
    ) -> KeepTalkingActionToolDefinition {
        KeepTalkingActionToolDefinition(
            functionName: KeepTalkingActionToolDefinition.normalizedFunctionName(
                ownerNodeID: ownerNodeID,
                actionID: actionID,
                mcpToolName: "skill_metadata"
            ),
            actionID: actionID,
            ownerNodeID: ownerNodeID,
            source: .skill,
            mcpToolName: nil,
            description:
                "Read skill metadata for \(bundle.name), including manifest metadata and indexed directories.",
            parameters: JSONSchema(
                .type(.object),
                .properties([:]),
                .additionalProperties(.boolean(false))
            )
        )
    }

    func makeSkillFileReaderDefinition(
        actionID: UUID,
        ownerNodeID: UUID,
        bundle: KeepTalkingSkillBundle
    ) -> KeepTalkingActionToolDefinition {
        KeepTalkingActionToolDefinition(
            functionName: KeepTalkingActionToolDefinition.normalizedFunctionName(
                ownerNodeID: ownerNodeID,
                actionID: actionID,
                mcpToolName: "skill_file"
            ),
            actionID: actionID,
            ownerNodeID: ownerNodeID,
            source: .skill,
            mcpToolName: nil,
            description:
                "Read a file from skill bundle \(bundle.name). Paths must stay within the skill directory.",
            parameters: JSONSchema(
                .type(.object),
                .properties([
                    "path": JSONSchema(
                        .type(.string),
                        .description(
                            "Relative path inside the skill bundle."
                        )
                    ),
                    "max_characters": JSONSchema(
                        .type(.integer),
                        .description(
                            "Optional maximum characters to return."
                        )
                    ),
                ]),
                .additionalProperties(.boolean(true))
            )
        )
    }

    func makeListingTool() -> ChatQuery.ChatCompletionToolParam {
        ChatQuery.ChatCompletionToolParam(
            function: .init(
                name: Self.listingToolFunctionName,
                description:
                    "List KeepTalking action proxies available in the current context. Always call this first. Use route_kind and action_id to match skill_metadata/skill_file with skill action_proxy calls.",
                parameters: JSONSchema(
                    .type(.object),
                    .properties([:]),
                    .additionalProperties(.boolean(false))
                ),
                strict: false
            )
        )
    }

    func openAIParameters(from inputSchema: Value?) -> JSONSchema {
        guard let inputSchema else {
            return KeepTalkingActionToolDefinition.permissiveObjectParameters
        }

        let repaired = repairedSchemaNode(inputSchema, forceObjectAtRoot: true)
        guard
            let data = try? JSONEncoder().encode(repaired),
            let schema = try? JSONDecoder().decode(JSONSchema.self, from: data)
        else {
            return KeepTalkingActionToolDefinition.permissiveObjectParameters
        }
        return schema
    }

    func repairedSchemaNode(
        _ node: Value,
        forceObjectAtRoot: Bool = false
    ) -> Value {
        switch node {
            case .object(let object):
                return .object(
                    repairedSchemaDictionary(
                        object,
                        forceObjectSemantics: forceObjectAtRoot
                    )
                )
            case .array(let array):
                return .array(
                    array.map { repairedSchemaNode($0, forceObjectAtRoot: false) }
                )
            default:
                if forceObjectAtRoot {
                    return .object([
                        "type": .string("object"),
                        "properties": .object([:]),
                        "additionalProperties": .bool(true),
                    ])
                }
                return node
        }
    }

    func repairedSchemaDictionary(
        _ object: [String: Value],
        forceObjectSemantics: Bool = false
    ) -> [String: Value] {
        var repaired: [String: Value] = [:]
        repaired.reserveCapacity(object.count)

        for (key, value) in object {
            switch value {
                case .object, .array:
                    repaired[key] = repairedSchemaNode(value)
                default:
                    repaired[key] = value
            }
        }

        let hasObjectKeywords =
            repaired["properties"] != nil
            || repaired["additionalProperties"] != nil
            || repaired["patternProperties"] != nil
            || repaired["required"] != nil
            || repaired["dependentRequired"] != nil
            || repaired["dependentSchemas"] != nil
            || repaired["propertyNames"] != nil

        let typeIsObject: Bool = {
            guard let type = repaired["type"] else {
                return false
            }
            switch type {
                case .string(let value):
                    return value == "object"
                case .array(let values):
                    return values.contains {
                        if case .string(let value) = $0 {
                            return value == "object"
                        }
                        return false
                    }
                default:
                    return false
            }
        }()

        let shouldTreatAsObject =
            forceObjectSemantics || hasObjectKeywords || typeIsObject
        guard shouldTreatAsObject else {
            return repaired
        }

        if repaired["type"] == nil {
            repaired["type"] = .string("object")
        }

        if repaired["properties"]?.objectValue == nil {
            repaired["properties"] = .object([:])
        }

        if let additionalProperties = repaired["additionalProperties"] {
            switch additionalProperties {
                case .bool:
                    break
                case .object:
                    repaired["additionalProperties"] = repairedSchemaNode(
                        additionalProperties
                    )
                default:
                    repaired["additionalProperties"] = .bool(true)
            }
        } else {
            repaired["additionalProperties"] = .bool(true)
        }

        return repaired
    }
}
