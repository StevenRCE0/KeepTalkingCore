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
        let description =
            descriptor?.action?.description
            ?? bundle.indexDescription
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
                targetName: "skill_metadata"
            ),
            actionID: actionID,
            ownerNodeID: ownerNodeID,
            source: .skill,
            targetName: "skill_metadata",
            displayName: bundle.name,
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
                targetName: "skill_file"
            ),
            actionID: actionID,
            ownerNodeID: ownerNodeID,
            source: .skill,
            targetName: "skill_file",
            displayName: bundle.name,
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
                    description: AIPromptPresets.ToolDescriptions.listingTool,
                    parameters: JSONSchema(
                        .type(.object),
                        .properties([:]),
                        .additionalProperties(.boolean(false))
                    ),
                    strict: false
                )
            )
    }

    func makeContextAttachmentListingTool() -> OpenAITool {
        OpenAITool
            .functionTool(
                .init(
                    name: Self.contextAttachmentListingToolFunctionName,
                    description: AIPromptPresets.ToolDescriptions.contextAttachmentListing,
                    parameters: JSONSchema(
                        .type(.object),
                        .properties([:]),
                        .additionalProperties(.boolean(false))
                    ),
                    strict: false
                )
            )
    }

    func makeContextAttachmentReadTool() -> OpenAITool {
        OpenAITool
            .functionTool(
                .init(
                    name: Self.contextAttachmentReadToolFunctionName,
                    description: AIPromptPresets.ToolDescriptions.contextAttachmentRead,
                    parameters: JSONSchema(
                        .type(.object),
                        .properties([
                            "attachment_id": JSONSchema(
                                .type(.string),
                                .description(
                                    "Attachment identifier returned by kt_list_context_attachments."
                                )
                            ),
                            "mode": JSONSchema(
                                .type(.string),
                                .enumValues([
                                    "metadata",
                                    "preview_text",
                                    "native",
                                ]),
                                .description(
                                    "How to inspect the attachment."
                                )
                            ),
                            "max_characters": JSONSchema(
                                .type(.integer),
                                .description(
                                    "Optional maximum preview length for preview_text mode."
                                )
                            ),
                        ]),
                        .required(["attachment_id", "mode"]),
                        .additionalProperties(.boolean(false))
                    ),
                    strict: false
                )
            )
    }

    func makeMarkTurningPointTool() -> OpenAITool {
        OpenAITool.functionTool(
            .init(
                name: Self.markTurningPointToolFunctionName,
                description: AIPromptPresets.ToolDescriptions.markTurningPoint,
                parameters: JSONSchema(
                    .type(.object),
                    .properties([
                        "previous_topic_name": JSONSchema(
                            .type(.string),
                            .description(
                                "Optional only when this message is the first meaningful message of the live thread. Otherwise required. A short 2-5 word label for the topic that ends before this message."
                            )
                        ),
                        "current_topic_name": JSONSchema(
                            .type(.string),
                            .description(
                                "Required. A short 2-5 word label for the live thread topic that starts at this message and should remain active after this tool call."
                            )
                        )
                    ]),
                    .required(["current_topic_name"]),
                    .additionalProperties(.boolean(false))
                ),
                strict: false
            )
        )
    }

    func makeMarkChitterChatterTool() -> OpenAITool {
        OpenAITool.functionTool(
            .init(
                name: Self.markChitterChatterToolFunctionName,
                description: AIPromptPresets.ToolDescriptions.markChitterChatter,
                parameters: JSONSchema(
                    .type(.object),
                    .properties([:]),
                    .additionalProperties(.boolean(false))
                ),
                strict: false
            )
        )
    }

    func makeContextAttachmentUpdateMetadataTool() -> OpenAITool {
        OpenAITool.functionTool(
            .init(
                name: Self.contextAttachmentUpdateMetadataToolFunctionName,
                description: AIPromptPresets.ToolDescriptions.contextAttachmentUpdateMetadata,
                parameters: JSONSchema(
                    .type(.object),
                    .properties([
                        "attachment_id": JSONSchema(
                            .type(.string),
                            .description(
                                "Attachment identifier."
                            )
                        ),
                        "image_description": JSONSchema(
                            .type(.string),
                            .description(
                                "A concise description of the image content. Set this after seeing the image via native mode."
                            )
                        ),
                        "text_preview": JSONSchema(
                            .type(.string),
                            .description(
                                "A summary or text preview for non-text files (e.g. PDFs, audio transcripts)."
                            )
                        ),
                        "tags": JSONSchema(
                            .type(.array),
                            .items(JSONSchema(.type(.string))),
                            .description(
                                "Tags to set on this attachment. Replaces existing tags."
                            )
                        ),
                    ]),
                    .required(["attachment_id"]),
                    .additionalProperties(.boolean(false))
                ),
                strict: false
            )
        )
    }

    func makeSearchThreadsTool() -> OpenAITool {
        OpenAITool.functionTool(
            .init(
                name: Self.searchThreadsToolFunctionName,
                description: AIPromptPresets.ToolDescriptions.searchThreads,
                parameters: JSONSchema(
                    .type(.object),
                    .properties([
                        "query": JSONSchema(
                            .type(.string),
                            .description(
                                "Natural-language memory query, phrased as the fact, topic, task, or decision you want to recover from earlier conversation."
                            )
                        ),
                        "top_k": JSONSchema(
                            .type(.integer),
                            .description(
                                "Optional maximum number of memory hits to return. Defaults to 5."
                            )
                        ),
                    ]),
                    .required(["query"]),
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
            case .addToReadingList:
                return JSONSchema(
                    .type(.object),
                    .properties([
                        "url": JSONSchema(
                            .type(.string),
                            .description("URL to add to the reading list.")
                        ),
                        "title": JSONSchema(
                            .type(.string),
                            .description(
                                "Optional title for the reading list entry.")
                        ),
                        "previewText": JSONSchema(
                            .type(.string),
                            .description(
                                "Optional preview text for the reading list entry."
                            )
                        ),
                    ]),
                    .required(["url"]),
                    .additionalProperties(.boolean(false))
                )
            case .askForFile:
                return JSONSchema(
                    .type(.object),
                    .properties([
                        "picker": JSONSchema(
                            .type(.string),
                            .enumValues([
                                "ask",
                                "filePicker",
                                "photoPicker",
                            ]),
                            .description(
                                "Which picker UI to present. Use ask to let the host prompt for take photo, select photo, or pick file, photoPicker for the photo library, or filePicker for general files. Defaults to ask."
                            )
                        ),
                        "allowedTypes": JSONSchema(
                            .type(.array),
                            .items(JSONSchema(
                                .type(.string)
                            )),
                            .description(
                                "Optional array of UTI strings to filter file types, e.g. [\"public.image\", \"public.plain-text\"]."
                            )
                        ),
                        "allowMultiple": JSONSchema(
                            .type(.boolean),
                            .description(
                                "Whether to allow selecting multiple files. Defaults to false."
                            )
                        ),
                    ]),
                    .additionalProperties(.boolean(false))
                )
            case .getCurrentlyPlayingMusic:
                return JSONSchema(
                    .type(.object),
                    .properties([
                        "storeID": JSONSchema(
                            .type(.string),
                            .description(
                                "Optional Apple Music song store ID to play. If omitted, the tool returns the currently playing music metadata."
                            )
                        ),
                        "url": JSONSchema(
                            .type(.string),
                            .description(
                                "Optional Apple Music song URL to play. The song store ID will be extracted from the URL. If omitted, the tool returns the currently playing music metadata."
                            )
                        ),
                    ]),
                    .additionalProperties(.boolean(false))
                )
            case .runMacOSShortcut:
                return JSONSchema(
                    .type(.object),
                    .properties([
                        "input": JSONSchema(
                            .type(.array),
                            .items(JSONSchema(.type(.string))),
                            .description(
                                "Optional list of string values to pass to the shortcut as input. Each item is sent as a separate line via stdin."
                            )
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
