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
            let fallbackDescription =
                action.descriptor?.action?.description
                ?? bundle.indexDescription
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
                    description: mcpProxyToolDescription(
                        originalToolName: bundle.name,
                        originalToolDescription: fallbackDescription,
                        fallbackDescription: fallbackDescription
                    ),
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
                description: mcpProxyToolDescription(
                    originalToolName: selectedToolName.isEmpty
                        ? bundle.name
                        : selectedToolName,
                    originalToolDescription: tool.description,
                    fallbackDescription: fallbackDescription
                ),
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
                    description: mcpProxyToolDescription(
                        originalToolName: bundle.name,
                        originalToolDescription: fallbackDescription,
                        fallbackDescription: fallbackDescription
                    ),
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
                description: mcpProxyToolDescription(
                    originalToolName: selectedToolName.isEmpty
                        ? bundle.name
                        : selectedToolName,
                    originalToolDescription: tool.description,
                    fallbackDescription: fallbackDescription
                ),
                parameters: openAIParameters(from: tool.inputSchema)
            )
        }
    }

    func mcpProxyToolDescription(
        originalToolName: String,
        originalToolDescription: String?,
        fallbackDescription: String
    ) -> String {
        let name = originalToolName.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        let trimmedOriginalDescription = originalToolDescription?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let description: String
        if let trimmedOriginalDescription, !trimmedOriginalDescription.isEmpty {
            description = trimmedOriginalDescription
        } else {
            description = fallbackDescription
        }

        if name.isEmpty {
            return description
        }
        return """
            Functional tool name: \(name)
            Functional tool description: \(description)
            """
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

    func makePrimitiveActionProxyDefinition(
        actionID: UUID,
        ownerNodeID: UUID,
        bundle: KeepTalkingPrimitiveBundle,
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
            source: .primitive,
            mcpToolName: bundle.name,
            description: description,
            parameters: primitiveActionParameters(for: bundle.action)
        )
    }

    func makeSkillMetadataDefinition(
        actionID: UUID,
        ownerNodeID: UUID,
        bundle: KeepTalkingSkillBundle
    ) -> KeepTalkingActionToolDefinition {
        return KeepTalkingActionToolDefinition(
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
        return KeepTalkingActionToolDefinition(
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

    func makeListingTool() -> OpenAITool {
        OpenAITool
            .functionTool(
                .init(
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

    func makeWebSearchTool() -> OpenAITool {
        OpenAITool
            .webSearchTool(
                .init(
                    _type: .webSearchPreview,
                    searchContextSize: .medium
                )
            )
    }

    func primitiveActionParameters(for action: KeepTalkingPrimitiveActionKind)
        -> JSONSchema
    {
        switch action {
            case .openURLInBrowser:
                return JSONSchema(
                    .type(.object),
                    .properties([
                        "url": JSONSchema(
                            .type(.string),
                            .description("URL to open in the system browser.")
                        )
                    ]),
                    .additionalProperties(.boolean(false))
                )
        }
    }

    func openAIParameters(from inputSchema: Value?) -> JSONSchema {
        guard let inputSchema else {
            return KeepTalkingActionToolDefinition.permissiveObjectParameters
        }

        let normalized = normalizedSchemaNode(
            inputSchema,
            expectation: .schema,
            forceRootObject: true
        )
        guard
            let data = try? JSONEncoder().encode(normalized),
            let schema = try? JSONDecoder().decode(JSONSchema.self, from: data)
        else {
            return KeepTalkingActionToolDefinition.permissiveObjectParameters
        }
        return schema
    }

    private enum SchemaExpectation {
        case any
        case schema
        case schemaOrBoolean
        case schemaArray
        case schemaMap
    }

    private func normalizedSchemaNode(
        _ node: Value,
        expectation: SchemaExpectation,
        forceRootObject: Bool = false
    ) -> Value {
        switch expectation {
            case .schema:
                guard case .object(let object) = node else {
                    return .object([:])
                }
                return .object(
                    normalizedSchemaObject(
                        object,
                        forceRootObject: forceRootObject
                    )
                )

            case .schemaOrBoolean:
                switch node {
                    case .bool:
                        return node
                    case .object(let object):
                        return .object(normalizedSchemaObject(object))
                    case .string(let value):
                        if value.lowercased() == "false" {
                            return .bool(false)
                        }
                        return .bool(true)
                    default:
                        return .bool(true)
                }

            case .schemaArray:
                guard case .array(let array) = node else {
                    return .array([])
                }
                return .array(
                    array.map {
                        normalizedSchemaNode(
                            $0,
                            expectation: .schemaOrBoolean
                        )
                    }
                )

            case .schemaMap:
                guard case .object(let object) = node else {
                    return .object([:])
                }
                return .object(
                    object.mapValues {
                        normalizedSchemaNode(
                            $0,
                            expectation: .schemaOrBoolean
                        )
                    }
                )

            case .any:
                switch node {
                    case .object(let object):
                        return .object(normalizedSchemaObject(object))
                    case .array(let array):
                        return .array(
                            array.map {
                                normalizedSchemaNode(
                                    $0,
                                    expectation: .any
                                )
                            }
                        )
                    default:
                        return node
                }
        }
    }

    private func normalizedSchemaObject(
        _ object: [String: Value],
        forceRootObject: Bool = false
    ) -> [String: Value] {
        var normalized: [String: Value] = [:]
        normalized.reserveCapacity(object.count)

        for (key, value) in object {
            if key == "$schema" || key == "$id" {
                continue
            }
            normalized[key] = normalizedSchemaNode(
                value,
                expectation: schemaExpectation(for: key)
            )
        }

        if let required = normalized["required"] {
            if case .array(let requiredValues) = required {
                let names = requiredValues.compactMap { value -> Value? in
                    guard case .string(let key) = value else {
                        return nil
                    }
                    let trimmed = key.trimmingCharacters(
                        in: .whitespacesAndNewlines
                    )
                    guard !trimmed.isEmpty else {
                        return nil
                    }
                    return .string(trimmed)
                }
                normalized["required"] = .array(names)
            } else {
                normalized.removeValue(forKey: "required")
            }
        }

        if forceRootObject {
            if normalized["type"] == nil {
                normalized["type"] = .string("object")
            }
            if normalized["properties"]?.objectValue == nil {
                normalized["properties"] = .object([:])
            }
            if normalized["additionalProperties"] == nil {
                normalized["additionalProperties"] = .bool(true)
            }
        }

        return normalized
    }

    private func schemaExpectation(for key: String) -> SchemaExpectation {
        switch key {
            case "items", "contains", "not", "if", "then", "else",
                "propertyNames":
                return .schema
            case "additionalProperties", "unevaluatedItems",
                "unevaluatedProperties":
                return .schemaOrBoolean
            case "allOf", "anyOf", "oneOf", "prefixItems":
                return .schemaArray
            case "properties", "patternProperties", "dependentSchemas",
                "$defs", "definitions":
                return .schemaMap
            default:
                return .any
        }
    }
}
