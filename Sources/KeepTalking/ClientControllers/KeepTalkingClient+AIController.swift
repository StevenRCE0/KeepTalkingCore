import FluentKit
import Foundation
import MCP
import OpenAI

extension KeepTalkingClient {
    private static let listingToolFunctionName = "kt_list_available_actions"

    public func runAI(
        prompt: String,
        in context: KeepTalkingContext,
        model: OpenAIModel = .gpt4_o
    ) async throws -> String {

        guard let openAIConnector else {
            throw KeepTalkingClientError.aiNotConfigured
        }

        let catalog = try await discoverActionToolCatalog(in: context)
        onLog?("[ai] catalog has \(catalog.definitions.count) virtual tool(s)")

        let listingTool = makeListingTool()
        let allTools = [listingTool] + catalog.openAITools
        let contextTranscript = try await agentContextTranscript(context)

        var messages: [ChatQuery.ChatCompletionMessageParam] = [
            .developer(
                .init(
                    content: .textContent(
                        """
                        You are a KeepTalking agent. You must call \(Self.listingToolFunctionName) first before any other tool call, then use tool outputs to answer the user.
                        Use the provided conversation context when deciding tool calls and in your final response.

                        Conversation context:
                        \(contextTranscript)
                        """
                    )
                )
            ),
            .user(.init(content: .string(prompt))),
        ]

        // Force the first step to be a listing call.
        let listingTurn = try await openAIConnector.completeTurn(
            messages: messages,
            tools: [listingTool],
            model: model,
            toolChoice: .function(Self.listingToolFunctionName)
        )
        if let assistantMessage = assistantMessage(from: listingTurn) {
            messages.append(assistantMessage)
        }

        var listingToolCalls = listingTurn.toolCalls
        if listingToolCalls.isEmpty {
            let syntheticID = UUID().uuidString.lowercased()
            listingToolCalls = [
                .init(
                    id: syntheticID,
                    function: .init(
                        arguments: "{}",
                        name: Self.listingToolFunctionName
                    )
                )
            ]
        }
        messages.append(
            contentsOf: try await executeAgentToolCalls(
                listingToolCalls,
                catalog: catalog,
                context: context
            )
        )

        var latestAssistantText = listingTurn.assistantText
        for _ in 0..<8 {
            let turn = try await openAIConnector.completeTurn(
                messages: messages,
                tools: allTools,
                model: model,
                toolChoice: .auto
            )

            if let assistantMessage = assistantMessage(from: turn) {
                messages.append(assistantMessage)
            }
            if let assistantText = turn.assistantText,
                !assistantText.trimmingCharacters(in: .whitespacesAndNewlines)
                    .isEmpty
            {
                latestAssistantText = assistantText
            }

            guard !turn.toolCalls.isEmpty else {
                break
            }
            messages.append(
                contentsOf: try await executeAgentToolCalls(
                    turn.toolCalls,
                    catalog: catalog,
                    context: context
                )
            )
        }

        return latestAssistantText?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    public func discoverActionToolCatalog(in context: KeepTalkingContext)
        async throws
        -> KeepTalkingActionToolCatalog
    {
        var definitionsByName: [String: KeepTalkingActionToolDefinition] = [:]
        let onlineNodeIDs = Set(
            try await KeepTalkingNode.query(on: localStore.database)
                .filter(\.$discoveredDuringLogon, .equal, logon)
                .all()
                .compactMap(\.id)
        )

        let selfNode = try await ensure(
            config.node,
            for: KeepTalkingNode.self,
            strict: true
        )

        let localActions = try await selfNode.$actions.query(
            on: localStore.database
        ).all()

        let onlineOutgoingRelations = try await selfNode.$outgoingNodeRelations
            .query(on: localStore.database).filter(
                \.$to.$id ~~ onlineNodeIDs
            ).all()

        let remoteActions = try await withThrowingTaskGroup(
            of: [KeepTalkingAction].self,
            returning: [KeepTalkingAction].self
        ) { group in
            for relation in onlineOutgoingRelations {
                group.addTask {
                    let actionRelations = try await relation.$actionRelations
                        .query(on: self.localStore.database)
                        .with(\.$action)
                        .all()

                    return try await self.authorizedActions(
                        actionRelations.map(\.action),
                        for: KeepTalkingNode(id: relation.$to.id),
                        context: context
                    )
                }
            }

            var result: [KeepTalkingAction] = []

            for try await actions in group {
                result.append(contentsOf: actions)
            }

            return result
        }

        for action in localActions + remoteActions {
            guard let ownerNodeID = action.$node.id else {
                continue
            }

            let definitions = try await normalizedToolDefinitions(
                for: action,
                ownerNodeID: ownerNodeID
            )
            for definition in definitions {
                definitionsByName[definition.functionName] = definition
            }
        }

        return KeepTalkingActionToolCatalog(
            definitions: Array(definitionsByName.values).sorted {
                $0.functionName < $1.functionName
            }
        )
    }

    private func makeListingTool() -> ChatQuery.ChatCompletionToolParam {
        ChatQuery.ChatCompletionToolParam(
            function: .init(
                name: Self.listingToolFunctionName,
                description:
                    "List virtual KeepTalking actions available in the current context. Call this first.",
                parameters: JSONSchema(
                    .type(.object),
                    .properties([:]),
                    .additionalProperties(.boolean(false))
                ),
                strict: false
            )
        )
    }

    private func assistantMessage(
        from turn: OpenAIConnector.ToolPlanningResult
    ) -> ChatQuery.ChatCompletionMessageParam? {
        let text = turn.assistantText?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let content:
            ChatQuery.ChatCompletionMessageParam.TextOrRefusalContent? =
                (text?.isEmpty == false) ? .textContent(text!) : nil
        let toolCalls = turn.toolCalls.isEmpty ? nil : turn.toolCalls
        if content == nil, toolCalls == nil {
            return nil
        }
        return .assistant(
            .init(
                content: content,
                toolCalls: toolCalls
            )
        )
    }

    private func executeAgentToolCalls(
        _ toolCalls: [ChatQuery.ChatCompletionMessageParam.AssistantMessageParam
            .ToolCallParam],
        catalog: KeepTalkingActionToolCatalog,
        context: KeepTalkingContext
    ) async throws -> [ChatQuery.ChatCompletionMessageParam] {
        var messages: [ChatQuery.ChatCompletionMessageParam] = []

        for toolCall in toolCalls {
            let toolCallID =
                toolCall.id.isEmpty
                ? UUID().uuidString.lowercased()
                : toolCall.id
            let functionName = toolCall.function.name

            let payload: String
            if functionName == Self.listingToolFunctionName {
                payload = renderCatalogListing(
                    catalog,
                    contextID: try context.requireID()
                )
            } else if let tool = catalog.definition(functionName: functionName)
            {
                var arguments = try decodeToolArguments(
                    toolCall.function.arguments
                )
                if let mcpToolName = tool.mcpToolName,
                    arguments["tool"] == nil
                {
                    arguments = [
                        "tool": .string(mcpToolName),
                        "arguments": .object(arguments),
                    ]
                }

                let actionCall = KeepTalkingActionCall(
                    action: tool.actionID,
                    arguments: arguments
                )

                let result = try await dispatchActionCall(
                    actionOwner: tool.ownerNodeID,
                    call: actionCall,
                    context: context
                )

                payload = renderAgentToolPayload(
                    functionName: functionName,
                    result: result
                )
            } else {
                payload = jsonString([
                    "ok": false,
                    "error": "unknown_tool",
                    "function_name": functionName,
                ])
            }

            messages.append(
                .tool(
                    .init(
                        content: .textContent(payload),
                        toolCallId: toolCallID
                    )
                )
            )
        }

        return messages
    }

    private func renderCatalogListing(
        _ catalog: KeepTalkingActionToolCatalog,
        contextID: UUID
    ) -> String {
        let rows = catalog.definitions.map { definition in
            [
                "function_name": definition.functionName,
                "action_id": definition.actionID.uuidString.lowercased(),
                "owner_node_id": definition.ownerNodeID.uuidString.lowercased(),
                "mcp_tool_name": definition.mcpToolName ?? "",
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

    private func renderAgentToolPayload(
        functionName: String,
        result: KeepTalkingActionCallResult
    ) -> String {
        let renderedContent = result.content.map { content -> String in
            switch content {
            case .text(let text):
                return text
            default:
                if let data = try? JSONEncoder().encode(content),
                    let json = String(data: data, encoding: .utf8)
                {
                    return json
                }
                return "<non-text content>"
            }
        }
        return jsonString([
            "ok": !result.isError,
            "function_name": functionName,
            "request_id": result.requestID.uuidString.lowercased(),
            "action_id": result.actionID.uuidString.lowercased(),
            "caller_node_id": result.callerNodeID.uuidString.lowercased(),
            "target_node_id": result.targetNodeID.uuidString.lowercased(),
            "error_message": result.errorMessage ?? "",
            "content": renderedContent,
        ])
    }

    private func agentContextTranscript(_ context: KeepTalkingContext)
        async throws -> String
    {
        let persistedContext = try await upsertContext(context)
        guard let contextID = persistedContext.id else {
            return "No prior messages in this context."
        }

        let recentMessages = try await KeepTalkingContextMessage.query(
            on: localStore.database
        )
        .filter(\.$context.$id, .equal, contextID)
        .sort(\.$timestamp, .descending)
        .limit(30)
        .all()

        guard !recentMessages.isEmpty else {
            return "No prior messages in this context."
        }

        return recentMessages.map { message in
            let sender: String =
                switch message.sender {
                case .node(let nodeID):
                    "node:\(nodeID.uuidString.lowercased())"
                case .autonomous(let name):
                    "agent:\(name)"
                }
            return "[\(sender)] \(message.content)"
        }.joined(separator: "\n")
    }

    private func jsonString(_ object: Any) -> String {
        guard JSONSerialization.isValidJSONObject(object) else {
            return "{\"ok\":false,\"error\":\"invalid_json_object\"}"
        }
        guard
            let data = try? JSONSerialization.data(
                withJSONObject: object,
                options: [.sortedKeys]
            ),
            let text = String(data: data, encoding: .utf8)
        else {
            return "{\"ok\":false,\"error\":\"json_encoding_failed\"}"
        }
        return text
    }

    func normalizedToolDefinitions(
        for action: KeepTalkingAction,
        ownerNodeID: UUID
    ) async throws -> [KeepTalkingActionToolDefinition] {
        guard let actionID = action.id else { return [] }
        let bundle: KeepTalkingMCPBundle?
        if case .mcpBundle(let decodedBundle) = action.payload {
            bundle = decodedBundle
        } else {
            bundle = nil
        }

        let baseDescription =
            action.descriptor?.action?.description
            ?? bundle?.indexDescription
            ?? "Virtual action call routed by node ownership."
        let virtualToolName =
            bundle?.name.trimmingCharacters(
                in: .whitespacesAndNewlines
            ) ?? ""
        let selectedToolName: String? =
            virtualToolName.isEmpty
            ? nil
            : virtualToolName
        let functionName =
            KeepTalkingActionToolDefinition.normalizedFunctionName(
                ownerNodeID: ownerNodeID,
                actionID: actionID,
                mcpToolName: selectedToolName
            )
        return [
            KeepTalkingActionToolDefinition(
                functionName: functionName,
                actionID: actionID,
                ownerNodeID: ownerNodeID,
                mcpToolName: selectedToolName,
                description:
                    "\(baseDescription) Virtual action call routed by node ownership.",
                parameters: KeepTalkingActionToolDefinition
                    .permissiveObjectParameters
            )
        ]
    }

    func decodeToolArguments(_ raw: String) throws -> [String: Value] {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return [:]
        }
        guard let data = trimmed.data(using: .utf8) else {
            throw KeepTalkingClientError.invalidToolArguments(raw)
        }
        do {
            return try JSONDecoder().decode([String: Value].self, from: data)
        } catch {
            throw KeepTalkingClientError.invalidToolArguments(raw)
        }
    }

    func renderToolResult(
        _ result: KeepTalkingActionCallResult,
        for functionName: String
    ) -> String {
        if result.isError {
            let message = result.errorMessage ?? "unknown error"
            return "[tool:\(functionName)] error: \(message)"
        }

        if result.content.isEmpty {
            return "[tool:\(functionName)] ok (empty result)"
        }

        let parts = result.content.map { content -> String in
            switch content {
            case .text(let text):
                return text
            default:
                if let data = try? JSONEncoder().encode(content),
                    let json = String(data: data, encoding: .utf8)
                {
                    return json
                }
                return "<non-text content>"
            }
        }
        return "[tool:\(functionName)] " + parts.joined(separator: "\n")
    }

    func registerLocalActionsInMCP() async throws {
        let localActions = try await KeepTalkingAction.query(
            on: localStore.database
        )
        .filter(\.$node.$id, .equal, config.node)
        .all()
        try await mcpManager.registerMCPActions(localActions)
    }
}
