import Foundation
import OpenAI

extension KeepTalkingClient {
    func toolNameForChatText(
        _ toolCall: ChatQuery.ChatCompletionMessageParam.AssistantMessageParam
            .ToolCallParam,
        routesByFunctionName: [String: KeepTalkingAgentToolRoute],
        skillNameByActionID: [UUID: String],
        nodeAliasResolver: ((UUID) -> String?)? = nil
    ) -> String {
        let functionName = toolCall.function.name
        guard functionName != Self.listingToolFunctionName else {
            return "list available actions"
        }
        if functionName == Self.contextAttachmentListingToolFunctionName {
            return "list context files"
        }
        if functionName == Self.contextAttachmentReadToolFunctionName {
            let arguments = try? decodeToolArguments(toolCall.function.arguments)
            switch arguments?["mode"]?.stringValue {
                case "native":
                    return "inspect context file"
                case "preview_text":
                    return "read context file preview"
                default:
                    return "inspect context file metadata"
            }
        }
        if functionName == Self.contextAttachmentUpdateMetadataToolFunctionName {
            return "update context file metadata"
        }
        if functionName == Self.searchThreadsToolFunctionName {
            return "search thread memory"
        }
        guard let route = routesByFunctionName[functionName] else {
            return friendlyToolCallPhrase(
                toolName: functionName,
                ownerNodeID: nil,
                actionID: nil,
                supportsWakeAssist: false
            )
        }

        switch route {
            case .actionProxy(let definition):
                let routedToolName: String
                if definition.source == .mcp,
                    let arguments = try? parsedActionCallArguments(
                        definition: definition,
                        rawArguments: toolCall.function.arguments
                    ),
                    let selectedTool = arguments["tool"]?.stringValue?
                        .trimmingCharacters(in: .whitespacesAndNewlines),
                    !selectedTool.isEmpty
                {
                    routedToolName =
                        KeepTalkingActionToolDefinition
                        .routedActionName(
                            selectedTool,
                            actionID: definition.actionID
                        )
                } else {
                    routedToolName = actionDisplayName(
                        for: definition,
                        route: route,
                        skillNameByActionID: skillNameByActionID
                    )
                }

                return friendlyToolCallPhrase(
                    toolName: routedToolName,
                    ownerNodeID: definition.ownerNodeID,
                    actionID: definition.actionID,
                    supportsWakeAssist: definition.supportsWakeAssist,
                    nodeAliasResolver: nodeAliasResolver
                )
            case .skillMetadata(let context):
                return friendlyToolCallPhrase(
                    toolName: "skill metadata \(context.bundle.name)",
                    ownerNodeID: context.ownerNodeID,
                    actionID: context.actionID,
                    supportsWakeAssist: false,
                    nodeAliasResolver: nodeAliasResolver
                )
            case .skillFileLocal(let context):
                return friendlyToolCallPhrase(
                    toolName: "skill file \(context.bundle.name)",
                    ownerNodeID: context.ownerNodeID,
                    actionID: context.actionID,
                    supportsWakeAssist: false,
                    nodeAliasResolver: nodeAliasResolver
                )
            case .skillFileRemote(let actionID, _, let skillName):
                return friendlyToolCallPhrase(
                    toolName: "skill file \(skillName)",
                    ownerNodeID: nil,
                    actionID: actionID,
                    supportsWakeAssist: false,
                    nodeAliasResolver: nodeAliasResolver
                )
        }
    }

    func friendlyToolCallPhrase(
        toolName: String,
        ownerNodeID: UUID?,
        actionID: UUID?,
        supportsWakeAssist: Bool,
        nodeAliasResolver: ((UUID) -> String?)? = nil
    ) -> String {
        let unroutedName: String
        if let actionID {
            unroutedName = KeepTalkingActionToolDefinition.unroutedActionName(
                toolName,
                actionID: actionID
            )
        } else {
            unroutedName = toolName
        }

        let collapsed =
            unroutedName
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(
                of: "[_\\-]+",
                with: " ",
                options: .regularExpression
            )
            .replacingOccurrences(
                of: "\\s+",
                with: " ",
                options: .regularExpression
            )

        guard !collapsed.isEmpty else {
            return "using tool"
        }
        guard let ownerNodeID else {
            return collapsed
        }

        let ownerName = nodeDisplayName(
            ownerNodeID,
            nodeAliasResolver: nodeAliasResolver
        )
        if ownerNodeID == config.node {
            return "\(collapsed) on current node \(ownerName)"
        }
        let wakeSuffix: String
        if supportsWakeAssist && !onlineNodeIDs().contains(ownerNodeID) {
            wakeSuffix = " while waking the node"
        } else {
            wakeSuffix = ""
        }
        return "\(collapsed) on node \(ownerName)\(wakeSuffix)"
    }

    func renderCatalogListing(
        _ catalog: KeepTalkingActionToolCatalog,
        routesByFunctionName: [String: KeepTalkingAgentToolRoute],
        contextID: UUID,
        nodeAliasResolver: ((UUID) -> String?)? = nil
    ) -> String {
        let skillNameByActionID = skillNamesByActionID(
            routesByFunctionName: routesByFunctionName
        )
        let rows = catalog.definitions.sorted {
            $0.functionName < $1.functionName
        }.map { definition in
            let route = routesByFunctionName[definition.functionName]
            let taggedToolName = actionDisplayName(
                for: definition,
                route: route,
                skillNameByActionID: skillNameByActionID
            )
            let ownerNodeName = nodeDisplayName(
                definition.ownerNodeID,
                nodeAliasResolver: nodeAliasResolver
            )
            return [
                "function_name": definition.functionName,
                "route_kind": routeKind(route),
                "source": definition.source.rawValue,
                "action_id": definition.actionID.uuidString.lowercased(),
                "owner_node_id": definition.ownerNodeID.uuidString.lowercased(),
                "owner_node_name": ownerNodeName,
                "is_current_node": definition.ownerNodeID == config.node,
                "tool_name": taggedToolName,
                "display_name": taggedToolName,
                "target_name": ownerNodeName,
                "description": definition.description,
            ]
        }

        return jsonString([
            "ok": true,
            "context_id": contextID.uuidString.lowercased(),
            "count": rows.count,
            "tools": rows,
        ])
    }

    func routeKind(_ route: KeepTalkingAgentToolRoute?) -> String {
        guard let route else {
            return "unknown"
        }
        switch route {
            case .actionProxy:
                return "action_proxy"
            case .skillMetadata:
                return "skill_metadata"
            case .skillFileLocal, .skillFileRemote:
                return "skill_file"
        }
    }

    func actionDisplayName(
        for definition: KeepTalkingActionToolDefinition,
        route: KeepTalkingAgentToolRoute?,
        skillNameByActionID: [UUID: String]
    ) -> String {
        if let displayName = definition.displayName?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !displayName.isEmpty
        {
            return KeepTalkingActionToolDefinition.routedActionName(
                displayName,
                actionID: definition.actionID
            )
        }

        switch route {
            case .skillMetadata(let context):
                return KeepTalkingActionToolDefinition.routedActionName(
                    context.bundle.name,
                    actionID: definition.actionID
                )
            case .skillFileLocal(let context):
                return KeepTalkingActionToolDefinition.routedActionName(
                    context.bundle.name,
                    actionID: definition.actionID
                )
            case .skillFileRemote(_, _, let skillName):
                return KeepTalkingActionToolDefinition.routedActionName(
                    skillName,
                    actionID: definition.actionID
                )
            case .actionProxy:
                if let skillName = skillNameByActionID[definition.actionID] {
                    return KeepTalkingActionToolDefinition.routedActionName(
                        skillName,
                        actionID: definition.actionID
                    )
                }
                return KeepTalkingActionToolDefinition.routedActionName(
                    "",
                    actionID: definition.actionID,
                    fallbackPrefix: "action"
                )
            case .none:
                return KeepTalkingActionToolDefinition.routedActionName(
                    "",
                    actionID: definition.actionID,
                    fallbackPrefix: "action"
                )
        }
    }

    func nodeDisplayName(
        _ nodeID: UUID,
        nodeAliasResolver: ((UUID) -> String?)? = nil
    ) -> String {
        KeepTalkingAliasResolution(
            alias: nodeAliasResolver?(nodeID),
            id: nodeID
        ).primary()
    }

    func skillNamesByActionID(
        routesByFunctionName: [String: KeepTalkingAgentToolRoute]
    ) -> [UUID: String] {
        var names: [UUID: String] = [:]
        for route in routesByFunctionName.values {
            switch route {
                case .skillMetadata(let context):
                    names[context.actionID] = context.bundle.name
                case .skillFileLocal(let context):
                    names[context.actionID] = context.bundle.name
                case .skillFileRemote(let actionID, _, let skillName):
                    names[actionID] = skillName
                default:
                    continue
            }
        }
        return names
    }
}
