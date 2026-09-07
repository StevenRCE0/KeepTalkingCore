import AIProxy
import FluentKit
import Foundation
import MCP

extension KeepTalkingClient {
    /// Executes the built-in `kt_create_action` meta tool.
    ///
    /// Without `node_id` (or with this node's ID) the request is served
    /// locally through the app-installed action-creation handler — the host
    /// user confirms and curates before anything is created. With a remote
    /// `node_id` the request is dispatched to that peer's `actionCreation`
    /// action, which runs the same confirmation flow on the peer's device.
    func executeCreateActionToolCall(
        rawArguments: String,
        runtimeCatalog: KeepTalkingActionRuntimeCatalog,
        context: KeepTalkingContext,
        agentTurnID: UUID? = nil
    ) async throws -> String {
        let args = (try? decodeToolArguments(rawArguments)) ?? [:]
        guard
            let intention = args["intention"]?.stringValue?
                .trimmingCharacters(in: .whitespacesAndNewlines),
            !intention.isEmpty
        else {
            return jsonString([
                "ok": false,
                "error": "intention is required.",
            ])
        }

        let targetNodeID = args["node_id"]?.stringValue.flatMap {
            UUID(uuidString: $0)
        }

        guard let targetNodeID, targetNodeID != config.node else {
            // Local request: ask this node's own user.
            guard let actionCreationHandler else {
                return jsonString([
                    "ok": false,
                    "error": "Action creation is not available on this node right now.",
                ])
            }
            let contextID = context.id ?? config.contextID
            let createdActionID = await actionCreationHandler(
                intention,
                contextID,
                config.node
            )
            guard let createdActionID else {
                return jsonString([
                    "ok": false,
                    "error": Self.actionCreationDeclinedMessage,
                ])
            }
            return jsonString([
                "ok": true,
                "status": "created",
                "action_id": createdActionID.uuidString.lowercased(),
            ])
        }

        guard
            let entry = runtimeCatalog.remoteActionCreationActions.first(
                where: { $0.ownerNodeID == targetNodeID }
            )
        else {
            let grantedNodes = runtimeCatalog.remoteActionCreationActions.map {
                $0.ownerNodeID.uuidString.lowercased()
            }
            return jsonString([
                "ok": false,
                "error":
                    "Node \(targetNodeID.uuidString.lowercased()) has not granted action creation in this context.",
                "granted_node_ids": grantedNodes,
            ])
        }

        let call = KeepTalkingActionCall(
            action: entry.actionID,
            arguments: [
                "intention": .string(intention)
            ]
        )
        let result: KeepTalkingActionCallResult
        do {
            result = try await dispatchActionCall(
                actionOwner: entry.ownerNodeID,
                call: call,
                context: context,
                agentTurnID: agentTurnID
            )
        } catch {
            return jsonString([
                "ok": false,
                "error": error.localizedDescription,
            ])
        }

        let text = result.content.compactMap { content -> String? in
            if case .text(let text, _, _) = content { return text }
            return nil
        }.joined(separator: "\n")

        if result.isError {
            return jsonString([
                "ok": false,
                "error": text.isEmpty
                    ? (result.errorMessage ?? "Action creation failed.")
                    : text,
            ])
        }
        return text.isEmpty
            ? jsonString(["ok": true, "status": "created"])
            : text
    }

    static let actionCreationDeclinedMessage =
        "The user declined this action-creation request. "
        + "Do NOT retry create-action for the same intention. "
        + "Continue the task without the new action, or ask the user in chat "
        + "what they would prefer instead."

    /// Executes an incoming `.actionCreation` action call — a peer (or the
    /// local agent, routed through the same gate) asking this host's user to
    /// create a new action. The app-installed handler owns confirmation and
    /// curation; a nil return means the user declined or dismissed the flow.
    func executeActionCreationActionCall(
        action: KeepTalkingAction,
        request: KeepTalkingActionCallRequest
    ) async -> (content: [Tool.Content], isError: Bool?) {
        func response(_ text: String, isError: Bool) -> (content: [Tool.Content], isError: Bool?) {
            (content: [.text(text: text, annotations: nil, _meta: nil)], isError: isError)
        }

        guard case .actionCreation(let bundle) = action.payload else {
            return response("Not an action-creation action.", isError: true)
        }
        if !bundle.contextIDs.isEmpty, !bundle.contextIDs.contains(request.contextID) {
            return response(
                "Action creation is not available in this context.",
                isError: true
            )
        }
        guard let actionCreationHandler else {
            return response(
                "Action creation is not available on this node right now.",
                isError: true
            )
        }

        let intention =
            request.call.arguments["intention"]?.stringValue?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !intention.isEmpty else {
            return response("intention is required.", isError: true)
        }

        let createdActionID = await actionCreationHandler(
            intention,
            request.contextID,
            request.callerNodeID
        )
        guard let createdActionID else {
            return response(Self.actionCreationDeclinedMessage, isError: true)
        }
        return response(
            jsonString([
                "ok": true,
                "status": "created",
                "action_id": createdActionID.uuidString.lowercased(),
            ]),
            isError: false
        )
    }
}

// MARK: - Host-driven requests

/// Why a request to have a peer create an action didn't produce one.
public enum KeepTalkingActionCreationRequestError: LocalizedError, Sendable {
    /// The peer hasn't granted this node its action-creation capability in
    /// this context, so there is nothing to dispatch to.
    case notGranted(UUID)
    /// The peer's user saw the request and said no.
    case declined(String)
    /// The call reached the peer but came back an error.
    case failed(String)

    public var errorDescription: String? {
        switch self {
            case .notGranted(let nodeID):
                return
                    "\(nodeID.uuidString.lowercased()) hasn't shared action creation in this context."
            case .declined(let message), .failed(let message):
                return message
        }
    }
}

extension KeepTalkingClient {
    /// Asks `nodeID`'s user to build an action for `intention`, through the
    /// peer's granted `.actionCreation` capability.
    ///
    /// This is the same hop `kt_create_action` takes for a remote `node_id`,
    /// exposed for hosts that raise the request from UI rather than from an
    /// agent turn. The peer's device runs its own confirm-and-curate flow and
    /// grants the result back, so the returned id names an action this node
    /// may already call by the time the request resolves.
    @discardableResult
    public func requestActionCreation(
        onNodeID nodeID: UUID,
        intention: String,
        in context: KeepTalkingContext
    ) async throws -> UUID? {
        let catalog = try await resolveActionRuntimeCatalog(in: context)
        guard
            let entry = catalog.remoteActionCreationActions.first(where: {
                $0.ownerNodeID == nodeID
            })
        else {
            throw KeepTalkingActionCreationRequestError.notGranted(nodeID)
        }

        let result = try await dispatchActionCall(
            actionOwner: entry.ownerNodeID,
            call: KeepTalkingActionCall(
                action: entry.actionID,
                arguments: ["intention": .string(intention)]
            ),
            context: context
        )

        let text = result.content.compactMap { content -> String? in
            if case .text(let text, _, _) = content { return text }
            return nil
        }.joined(separator: "\n")

        if result.isError {
            let message =
                text.isEmpty
                ? (result.errorMessage ?? "Action creation failed.")
                : text
            // The decline message is the peer's user saying no, not a fault.
            throw message.contains("declined")
                ? KeepTalkingActionCreationRequestError.declined(message)
                : KeepTalkingActionCreationRequestError.failed(message)
        }

        guard
            let data = text.data(using: .utf8),
            let object = try? JSONSerialization.jsonObject(with: data),
            let fields = object as? [String: Any],
            let raw = fields["action_id"] as? String
        else {
            // Created, but the peer named no id — the sweep still catches it.
            return nil
        }
        return UUID(uuidString: raw)
    }
}
