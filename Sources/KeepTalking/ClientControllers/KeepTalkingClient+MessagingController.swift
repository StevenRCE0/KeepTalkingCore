import FluentKit
import Foundation

extension KeepTalkingClient {

    public func send(
        _ text: String,
        in context: KeepTalkingContext,
        sender: KeepTalkingContextMessage.Sender? = nil
    ) async throws {
        let node = try await getCurrentNodeInstance()
        let persistedContext = try await upsertContext(context)

        let message = KeepTalkingContextMessage(
            context: persistedContext,
            sender: try sender ?? .node(node: node.requireID()),
            content: text
        )
        persistedContext.updatedAt = message.timestamp
        _ = try await persistedContext.$messages.get(on: localStore.database)

        try await message.save(on: localStore.database)
        try await persistedContext.save(on: localStore.database)

        try rtcClient.sendEnvelope(.message(message))
    }

    public func sendConversationContext(
        _ context: KeepTalkingConversationContext
    ) async throws {
        try await saveContext(context)
        try rtcClient.sendEnvelope(.context(context))
    }

    func mergeContext(_ context: KeepTalkingContext) {
        Task {
            try? await self.saveContext(context)
        }
    }

    func handleIncomingMessage(_ message: KeepTalkingContextMessage)
        async throws
    {
        Task {
            try? await message.save(on: localStore.database)
        }

        let node = try await getCurrentNodeInstance()

        if case .node(let nodeID) = message.sender, nodeID != config.node {
            let senderNode: KeepTalkingNode
            if let existingSenderNode =
                try await KeepTalkingNode
                .query(on: localStore.database)
                .filter(\.$id, .equal, nodeID)
                .first()
            {
                senderNode = existingSenderNode
            } else {
                senderNode = KeepTalkingNode(id: nodeID)
                try await senderNode.save(on: localStore.database)
            }

            let relationExists =
                try await KeepTalkingNodeRelation
                .query(on: localStore.database)
                .filter(\.$from.$id, .equal, try node.requireID())
                .filter(\.$to.$id, .equal, nodeID)
                .count() > 0

            if !relationExists {
                let relationship = try KeepTalkingNodeRelation(
                    from: node,
                    to: senderNode,
                    relationship: .pending
                )
                try await relationship.save(on: localStore.database)
            }
        }

        onMessage?(message)
    }

    func handleIncomingEnvelope(_ envelope: KeepTalkingP2PEnvelope)
        async throws
    {
        switch envelope {
        case .message(let message):
            try await handleIncomingMessage(message)
            rtcClient.debug("Message cast to envelope")
        case .node(let node):
            try await mergeDiscoveredNode(node)
        case .nodeStatus(let status):
            try await mergeDiscoveredNodeStatus(status)
        case .context(let context):
            mergeContext(context)
            if let latestMessage = context.messages.max(by: {
                $0.timestamp < $1.timestamp
            }) {
                onMessage?(latestMessage)
            }
        case .actionCallRequest(let request):
            if request.targetNodeID == config.node {
                Task { [weak self] in
                    try await self?.handleIncomingActionCallRequest(request)
                }
            }
        case .actionCallResult(let result):
            _ = resolvePendingActionCall(result)
        case .p2pPresence(let presence):
            guard presence.node != config.node else {
                break
            }
            let nodeIDText = presence.node.uuidString.lowercased()
            do {
                try await markNodeDiscovered(presence.node)
            } catch {
                rtcClient.debug(
                    "mark node discovered failed node=\(nodeIDText) error=\(error.localizedDescription)"
                )
            }
            scheduleDebouncedNodeStateBroadcast(
                reason: "p2pPresence node=\(nodeIDText)"
            )
        default:
            break
        }

        onEnvelope?(envelope)
    }

    func saveContext(_ context: KeepTalkingContext) async throws {
        let persistedContext = try await upsertContext(context)
        for message in context.messages {
            message.context = persistedContext
            try await message.save(on: localStore.database)
        }
    }

    func upsertContext(_ context: KeepTalkingContext) async throws
        -> KeepTalkingContext
    {
        guard let contextID = context.id else {
            try await context.save(on: localStore.database)
            return context
        }

        if let existing = try await KeepTalkingContext.query(
            on: localStore.database
        )
        .filter(\.$id, .equal, contextID)
        .first() {
            if let updatedAt = context.updatedAt {
                if let existingUpdatedAt = existing.updatedAt {
                    existing.updatedAt = max(existingUpdatedAt, updatedAt)
                } else {
                    existing.updatedAt = updatedAt
                }
                try await existing.save(on: localStore.database)
            }
            return existing
        }

        try await context.save(on: localStore.database)
        return context
    }

    func blocking<T: Sendable>(
        _ operation: @escaping @Sendable () async throws -> T
    ) throws -> T {
        let semaphore = DispatchSemaphore(value: 0)
        var result: Result<T, Error>?

        Task {
            do {
                result = .success(try await operation())
            } catch {
                result = .failure(error)
            }
            semaphore.signal()
        }

        semaphore.wait()
        guard let result else {
            fatalError("Blocking operation did not produce a result.")
        }
        return try result.get()
    }
}
