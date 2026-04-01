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
                    description:
                        "List KeepTalking action proxies available in the current context. Use this only when you need to discover or confirm which KeepTalking action proxy to call. Match the requested target node against owner_node_name or target_name. Those names come from mappings aliases and fall back to the node's uppercase UUID when no alias exists. Use is_current_node when the user means the current or local node. Use route_kind and action_id to match skill_metadata or skill_file with skill action_proxy calls.",
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
                    description:
                        "List attachments already stored in the active KeepTalking context, including ids, filenames, mime types, availability, and derived metadata. Use this only when you need a different earlier attachment or need to confirm attachment identity or metadata that is not already present in the current turn. Do not call this just to verify a file or image that was already attached or injected into the same turn.",
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
                    description:
                        "Inspect a specific context attachment after kt_list_context_attachments. Use this when you need a different earlier attachment or metadata that is not already present in the current turn. Do not call this for a file or image that is already attached or injected into the same turn unless you truly need a different earlier context attachment. Use mode metadata for attachment fields, preview_text for derived text or description, and native only when you need the actual file or image added to the next model turn.",
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
                description:
                    "Mark the current user request as a turning point, splitting the conversation into a new thread starting here. Use this proactively when the conversation meaningfully shifts topic, goal, or mode. You MUST always provide previous_topic_name.",
                parameters: JSONSchema(
                    .type(.object),
                    .properties([
                        "previous_topic_name": JSONSchema(
                            .type(.string),
                            .description(
                                "Required. A short label (2–5 words) for the topic that just ended, e.g. \"Paris trip planning\" or \"Docker setup\". Shown as the thread name in the sidebar. Never omit this."
                            )
                        )
                    ]),
                    .required(["previous_topic_name"]),
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
                description:
                    "Toggle the current user request as chitter-chatter — noise, small-talk, greetings, acknowledgements with no new information, or off-topic asides. Chitter-chatter is de-emphasised in the thread view but never deleted. Use proactively.",
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
