import FluentKit
import Foundation
import MCP
import OpenAI

extension KeepTalkingClient {
    public func runAI(
        prompt: String,
        in context: KeepTalkingContext,
        model: OpenAIModel = .gpt4_o
    ) async throws -> String {
        guard let openAIConnector else {
            throw KeepTalkingClientError.aiNotConfigured
        }

        let contextID = context.id ?? config.contextID
        let catalog = try await discoverActionToolCatalog(in: contextID)
        let planning = try await openAIConnector.planTools(
            prompt: prompt,
            tools: catalog.openAITools,
            model: model
        )

        guard !planning.toolCalls.isEmpty else {
            return planning.assistantText ?? ""
        }

        var renderedOutputs: [String] = []
        for toolCall in planning.toolCalls {
            let functionName = toolCall.function.name
            guard let tool = catalog.definition(functionName: functionName)
            else {
                throw KeepTalkingClientError.unknownTool(functionName)
            }

            let arguments = try decodeToolArguments(toolCall.function.arguments)
            let actionCall = KeepTalkingActionCall(
                action: tool.actionID,
                arguments: arguments
            )

            let result = try await dispatchActionCall(
                actionOwner: tool.ownerNodeID,
                call: actionCall,
                contextID: contextID
            )
            renderedOutputs.append(renderToolResult(result, for: functionName))
        }

        if renderedOutputs.isEmpty {
            return planning.assistantText ?? ""
        }
        return renderedOutputs.joined(separator: "\n")
    }

    public func discoverActionToolCatalog(in contextID: UUID) async throws
        -> KeepTalkingActionToolCatalog
    {
        var definitionsByName: [String: KeepTalkingActionToolDefinition] = [:]
        let onlineNodeIDs = Set(
            try await KeepTalkingNode.query(on: localStore.database)
                .filter(\.$discoveredDuringLogon, .equal, logon)
                .all()
                .compactMap(\.id)
        )

        let localActions = try await KeepTalkingAction.query(
            on: localStore.database
        )
        .filter(\.$node.$id, .equal, config.node)
        .all()
        for action in localActions {
            guard
                let definition = normalizedToolDefinition(
                    for: action,
                    ownerNodeID: config.node
                )
            else { continue }
            definitionsByName[definition.functionName] = definition
        }

        let relations = try await KeepTalkingNodeRelation.query(
            on: localStore.database
        )
        .filter(\.$from.$id, .equal, config.node)
        .filter(\.$relationship ~~ [.owner, .trusted])
        .all()

        for relation in relations {
            guard let relationID = relation.id else { continue }

            let links =
                try await KeepTalkingNodeRelationActionRelation
                .query(on: localStore.database)
                .filter(\.$relation.$id, .equal, relationID)
                .with(\.$action)
                .all()

            for link in links {
                guard
                    approvingContextAllows(
                        link.approvingContext,
                        contextID: contextID
                    )
                else {
                    continue
                }

                let action = link.action
                let actionOwner = action.$node.id ?? relation.$to.id

                // Remote discoverability is limited to remote-authorisable actions.
                if actionOwner != config.node {
                    guard onlineNodeIDs.contains(actionOwner) else {
                        continue
                    }
                    if action.remoteAuthorisable != true {
                        continue
                    }
                }

                guard
                    let definition = normalizedToolDefinition(
                        for: action,
                        ownerNodeID: actionOwner
                    )
                else { continue }
                definitionsByName[definition.functionName] = definition
            }
        }

        return KeepTalkingActionToolCatalog(
            definitions: Array(definitionsByName.values).sorted {
                $0.functionName < $1.functionName
            }
        )
    }

    func normalizedToolDefinition(
        for action: KeepTalkingAction,
        ownerNodeID: UUID
    ) -> KeepTalkingActionToolDefinition? {
        guard let actionID = action.id else { return nil }
        guard case .mcpBundle(let bundle) = action.payload else { return nil }

        let description =
            action.descriptor?.action?.description
            ?? bundle.indexDescription

        let functionName =
            KeepTalkingActionToolDefinition.normalizedFunctionName(
                ownerNodeID: ownerNodeID,
                actionID: actionID
            )

        return KeepTalkingActionToolDefinition(
            functionName: functionName,
            actionID: actionID,
            ownerNodeID: ownerNodeID,
            description: description,
            parameters: KeepTalkingActionToolDefinition
                .permissiveObjectParameters
        )
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
