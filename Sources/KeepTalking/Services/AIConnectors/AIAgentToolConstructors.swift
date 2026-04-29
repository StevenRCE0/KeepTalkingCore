import AIProxy
import Foundation
import MCP

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
                            targetName: bundle.name
                        ),
                    actionID: actionID,
                    ownerNodeID: ownerNodeID,
                    source: .mcp,
                    targetName: bundle.name,
                    displayName: bundle.name,
                    supportsWakeAssist: action.blockingAuthorisation == true,
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
                        targetName: selectedToolName.isEmpty
                            ? nil
                            : selectedToolName
                    ),
                actionID: actionID,
                ownerNodeID: ownerNodeID,
                source: .mcp,
                targetName: selectedToolName.isEmpty ? nil : selectedToolName,
                displayName: selectedToolName.isEmpty ? bundle.name : selectedToolName,
                supportsWakeAssist: action.blockingAuthorisation == true,
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
                            targetName: bundle.name
                        ),
                    actionID: actionID,
                    ownerNodeID: ownerNodeID,
                    source: .mcp,
                    targetName: bundle.name,
                    displayName: bundle.name,
                    supportsWakeAssist: action.blockingAuthorisation == true,
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
                        targetName: selectedToolName.isEmpty
                            ? nil
                            : selectedToolName
                    ),
                actionID: actionID,
                ownerNodeID: ownerNodeID,
                source: .mcp,
                targetName: selectedToolName.isEmpty ? nil : selectedToolName,
                displayName: selectedToolName.isEmpty ? bundle.name : selectedToolName,
                supportsWakeAssist: action.blockingAuthorisation == true,
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
        AIPromptPresets.mcpProxyToolDescription(
            originalToolName: originalToolName,
            originalToolDescription: originalToolDescription,
            fallbackDescription: fallbackDescription
        )
    }

    func makeSkillActionProxyDefinition(
        actionID: UUID,
        ownerNodeID: UUID,
        bundle: KeepTalkingSkillBundle,
        descriptor: KeepTalkingActionDescriptor?,
        supportsWakeAssist: Bool = false
    ) -> KeepTalkingActionToolDefinition {
        let baseDescription =
            descriptor?.action?.description
            ?? bundle.indexDescription

        // Surface configured parameter names so the outer AI knows what's already set
        let dirParams = bundle.parameters.filter { $0.value.hasPrefix("/") }
        let envParams = bundle.parameters.filter { !$0.value.hasPrefix("/") }
        var paramHints: [String] = []
        if !dirParams.isEmpty {
            let dirs = dirParams.keys.sorted().joined(separator: ", ")
            paramHints.append("Configured directories: \(dirs) (already set, do NOT ask the user for paths).")
        }
        if !envParams.isEmpty {
            let envs = envParams.keys.sorted().joined(separator: ", ")
            paramHints.append("Configured parameters: \(envs).")
        }
        let paramSuffix = paramHints.isEmpty ? "" : " " + paramHints.joined(separator: " ")

        let description =
            "Execute skill \(bundle.name). Call this tool to run the skill — "
            + "do NOT just read metadata or describe commands. "
            + baseDescription
            + paramSuffix
        return KeepTalkingActionToolDefinition(
            functionName: KeepTalkingActionToolDefinition.normalizedFunctionName(
                ownerNodeID: ownerNodeID,
                actionID: actionID,
                targetName: nil
            ),
            actionID: actionID,
            ownerNodeID: ownerNodeID,
            source: .skill,
            targetName: bundle.name,
            displayName: bundle.name,
            supportsWakeAssist: supportsWakeAssist,
            description: description,
            parameters: KeepTalkingActionToolDefinition.permissiveObjectParameters
        )
    }

    func makePrimitiveActionProxyDefinition(
        actionID: UUID,
        ownerNodeID: UUID,
        bundle: KeepTalkingPrimitiveBundle,
        descriptor: KeepTalkingActionDescriptor?,
        supportsWakeAssist: Bool = false
    ) -> KeepTalkingActionToolDefinition {
        let description =
            descriptor?.action?.description
            ?? bundle.indexDescription
        return KeepTalkingActionToolDefinition(
            functionName: KeepTalkingActionToolDefinition.normalizedFunctionName(
                ownerNodeID: ownerNodeID,
                actionID: actionID,
                targetName: bundle.action.rawValue
            ),
            actionID: actionID,
            ownerNodeID: ownerNodeID,
            source: .primitive,
            targetName: bundle.action.rawValue,
            displayName: bundle.name,
            supportsWakeAssist: supportsWakeAssist,
            description: description,
            parameters: primitiveRegistry?.toolParameters(bundle.action)
                ?? KeepTalkingActionToolDefinition.permissiveObjectParameters
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
                targetName: "skill_metadata"
            ),
            actionID: actionID,
            ownerNodeID: ownerNodeID,
            source: .skill,
            targetName: "skill_metadata",
            displayName: bundle.name,
            description:
                "Read skill metadata for \(bundle.name), including manifest metadata and indexed directories.",
            parameters: [
                "type": .string("object"),
                "properties": .object([:]),
                "additionalProperties": .bool(false),
            ]
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
                targetName: "skill_file"
            ),
            actionID: actionID,
            ownerNodeID: ownerNodeID,
            source: .skill,
            targetName: "skill_file",
            displayName: bundle.name,
            description:
                "Read a file from skill bundle \(bundle.name). Paths must stay within the skill directory.",
            parameters: [
                "type": .string("object"),
                "properties": .object([
                    "path": .object([
                        "type": .string("string"),
                        "description": .string("Relative path inside the skill bundle."),
                    ]),
                    "max_characters": .object([
                        "type": .string("integer"),
                        "description": .string("Optional maximum characters to return."),
                    ]),
                ]),
                "additionalProperties": .bool(true),
            ]
        )
    }

    func makeKtSkillMetainfoTool() -> KeepTalkingActionToolDefinition {
        .init(
            functionName: Self.ktSkillMetainfoToolFunctionName,
            actionID: UUID(),
            ownerNodeID: UUID(),
            source: .primitive,
            description: AIPromptPresets.ToolDescriptions.ktSkillMetainfo,
            parameters: [
                "type": .string("object"),
                "properties": .object([
                    "action_id": .object([
                        "type": .string("string"),
                        "description": .string(
                            "The action_id of the skill action to inspect, from the available actions list."
                        ),
                    ])
                ]),
                "required": .array([.string("action_id")]),
                "additionalProperties": .bool(false),
            ]
        )
    }

    func makeContextAttachmentListingTool() -> KeepTalkingActionToolDefinition {
        .init(
            functionName: Self.contextAttachmentListingToolFunctionName,
            actionID: UUID(),
            ownerNodeID: UUID(),
            source: .primitive,
            description: AIPromptPresets.ToolDescriptions.contextAttachmentListing,
            parameters: [
                "type": .string("object"),
                "properties": .object([:]),
                "additionalProperties": .bool(false),
            ]
        )
    }

    func makeContextAttachmentReadTool() -> KeepTalkingActionToolDefinition {
        .init(
            functionName: Self.contextAttachmentReadToolFunctionName,
            actionID: UUID(),
            ownerNodeID: UUID(),
            source: .primitive,
            description: AIPromptPresets.ToolDescriptions.contextAttachmentRead,
            parameters: [
                "type": .string("object"),
                "properties": .object([
                    "attachment_id": .object([
                        "type": .string("string"),
                        "description": .string(
                            "Attachment identifier returned by kt_list_context_attachments."
                        ),
                    ]),
                    "mode": .object([
                        "type": .string("string"),
                        "enum": .array([
                            .string("metadata"),
                            .string("preview_text"),
                            .string("native"),
                        ]),
                        "description": .string("How to inspect the attachment."),
                    ]),
                    "max_characters": .object([
                        "type": .string("integer"),
                        "description": .string(
                            "Optional maximum preview length for preview_text mode."
                        ),
                    ]),
                ]),
                "required": .array([.string("attachment_id"), .string("mode")]),
                "additionalProperties": .bool(false),
            ]
        )
    }

    func makeMarkTurningPointTool() -> KeepTalkingActionToolDefinition {
        .init(
            functionName: Self.markTurningPointToolFunctionName,
            actionID: UUID(),
            ownerNodeID: UUID(),
            source: .primitive,
            description: AIPromptPresets.ToolDescriptions.markTurningPoint,
            parameters: [
                "type": .string("object"),
                "properties": .object([
                    "previous_topic_name": .object([
                        "type": .string("string"),
                        "description": .string(
                            "Optional only when this message is the first meaningful message of the live thread. Otherwise required. A short 2-5 word label for the topic that ends before this message."
                        ),
                    ]),
                    "current_topic_name": .object([
                        "type": .string("string"),
                        "description": .string(
                            "Required. A short 2-5 word label for the live thread topic that starts at this message and should remain active after this tool call."
                        ),
                    ]),
                ]),
                "required": .array([.string("current_topic_name")]),
                "additionalProperties": .bool(false),
            ]
        )
    }

    func makeMarkChitterChatterTool() -> KeepTalkingActionToolDefinition {
        .init(
            functionName: Self.markChitterChatterToolFunctionName,
            actionID: UUID(),
            ownerNodeID: UUID(),
            source: .primitive,
            description: AIPromptPresets.ToolDescriptions.markChitterChatter,
            parameters: [
                "type": .string("object"),
                "properties": .object([:]),
                "additionalProperties": .bool(false),
            ]
        )
    }

    func makeContextAttachmentUpdateMetadataTool() -> KeepTalkingActionToolDefinition {
        .init(
            functionName: Self.contextAttachmentUpdateMetadataToolFunctionName,
            actionID: UUID(),
            ownerNodeID: UUID(),
            source: .primitive,
            description: AIPromptPresets.ToolDescriptions.contextAttachmentUpdateMetadata,
            parameters: [
                "type": .string("object"),
                "properties": .object([
                    "attachment_id": .object([
                        "type": .string("string"),
                        "description": .string("Attachment identifier."),
                    ]),
                    "image_description": .object([
                        "type": .string("string"),
                        "description": .string(
                            "A concise description of the image content. Set this after seeing the image via native mode."
                        ),
                    ]),
                    "text_preview": .object([
                        "type": .string("string"),
                        "description": .string(
                            "A summary or text preview for non-text files (e.g. PDFs, audio transcripts)."
                        ),
                    ]),
                    "tags": .object([
                        "type": .string("array"),
                        "items": .object([
                            "type": .string("string")
                        ]),
                        "description": .string(
                            "Tags to set on this attachment. Replaces existing tags."
                        ),
                    ]),
                ]),
                "required": .array([.string("attachment_id")]),
                "additionalProperties": .bool(false),
            ]
        )
    }

    func makeSearchThreadsTool() -> KeepTalkingActionToolDefinition {
        .init(
            functionName: Self.searchThreadsToolFunctionName,
            actionID: UUID(),
            ownerNodeID: UUID(),
            source: .primitive,
            description: AIPromptPresets.ToolDescriptions.searchThreads,
            parameters: [
                "type": .string("object"),
                "properties": .object([
                    "query": .object([
                        "type": .string("string"),
                        "description": .string(
                            "Natural-language memory query, phrased as the fact, topic, task, or decision you want to recover from earlier conversation."
                        ),
                    ]),
                    "top_k": .object([
                        "type": .string("integer"),
                        "description": .string(
                            "Optional maximum number of memory hits to return. Defaults to 5."
                        ),
                    ]),
                ]),
                "required": .array([.string("query")]),
                "additionalProperties": .bool(false),
            ]
        )
    }

    func makeWebSearchTool() -> KeepTalkingActionToolDefinition {
        // Chat Completions only — Responses-API-style web_search_preview was dropped
        // when the protocol moved off the Responses API.
        .init(
            functionName: Self.webSearchFunctionName,
            actionID: UUID(),
            ownerNodeID: UUID(),
            source: .primitive,
            description:
                "Search the web for current information, recent events, or factual data not present in your training. Returns a text summary of relevant results.",
            parameters: [
                "type": .string("object"),
                "properties": .object([
                    "query": .object([
                        "type": .string("string"),
                        "description": .string("The search query."),
                    ])
                ]),
                "required": .array([.string("query")]),
                "additionalProperties": .bool(false),
            ]
        )
    }

    /// Convert an MCP `Value` schema into the AIProxy `[String: AIProxyJSONValue]`
    /// shape that `OpenAIChatCompletionRequestBody.Tool.function(parameters:)` expects.
    func openAIParameters(from inputSchema: Value?) -> [String: AIProxyJSONValue] {
        guard let inputSchema else {
            return KeepTalkingActionToolDefinition.permissiveObjectParameters
        }
        let normalized = normalizedSchemaNode(
            inputSchema,
            expectation: .schema,
            forceRootObject: true
        )
        guard case .object(let dict) = normalized else {
            return KeepTalkingActionToolDefinition.permissiveObjectParameters
        }
        return dict.mapValues(Self.toAIProxy)
    }

    private static func toAIProxy(_ value: Value) -> AIProxyJSONValue {
        switch value {
            case .null: return .null(NSNull())
            case .bool(let b): return .bool(b)
            case .int(let i): return .int(i)
            case .double(let d): return .double(d)
            case .string(let s): return .string(s)
            case .data(_, let d):
                // Schemas should not contain raw data; surface as base64 string for sanity.
                return .string(d.base64EncodedString())
            case .array(let arr): return .array(arr.map(toAIProxy))
            case .object(let obj): return .object(obj.mapValues(toAIProxy))
        }
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
            if case .object = normalized["properties"] {
                // ok
            } else {
                normalized["properties"] = .object([:])
            }
            if normalized["additionalProperties"] == nil {
                normalized["additionalProperties"] = .bool(true)
            }
        }

        return normalized
    }

    /// Builds one `KeepTalkingActionToolDefinition` per filesystem operation
    /// that the caller is allowed to use (filtered by `allowedTools`).
    func makeFilesystemToolDefinitions(
        actionID: UUID,
        ownerNodeID: UUID,
        bundle: KeepTalkingFilesystemBundle,
        supportsWakeAssist: Bool,
        allowedTools: [KeepTalkingFilesystemTool]
    ) -> [KeepTalkingActionToolDefinition] {
        allowedTools.map { tool in
            let opName = tool.operation.rawValue
            let propsValue: AIProxyJSONValue = .object(
                tool.operation.inputSchemaProperties.mapValues { propInfo in
                    AIProxyJSONValue.object([
                        "type": .string("string"),
                        "description": .string(propInfo["description"] ?? ""),
                    ])
                }
            )
            return KeepTalkingActionToolDefinition(
                functionName: KeepTalkingActionToolDefinition.normalizedFunctionName(
                    ownerNodeID: ownerNodeID,
                    actionID: actionID,
                    targetName: opName
                ),
                actionID: actionID,
                ownerNodeID: ownerNodeID,
                source: .filesystem,
                targetName: opName,
                displayName: opName,
                supportsWakeAssist: supportsWakeAssist,
                description: tool.description,
                parameters: [
                    "type": .string("object"),
                    "properties": propsValue,
                    "required": .array(
                        tool.operation.requiredInputProperties.map(AIProxyJSONValue.string)
                    ),
                    "additionalProperties": .bool(false),
                ]
            )
        }
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
