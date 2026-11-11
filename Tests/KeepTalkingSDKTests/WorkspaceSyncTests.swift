import FluentKit
import Foundation
import Testing

@testable import KeepTalkingSDK

private struct ExportingWorkspace: KeepTalkingWorkspaceProviding {
    let manifest = KeepTalkingWorkspaceManifest(
        title: "Canvas", kind: .canvas, schema: "excalidraw-scene", granularities: [.full])
    let state: String

    func snapshot(granularity: KeepTalkingWorkspaceGranularity) async throws -> KeepTalkingWorkspaceSnapshot {
        .init(granularity: granularity, stats: .init(), liftedText: state)
    }

    func export() async throws -> KeepTalkingWorkspaceExport {
        .init(data: Data(state.utf8), mimeType: "application/json", pathExtension: "excalidraw")
    }
}

struct WorkspaceSyncTests {
    private struct Node {
        let store: KeepTalkingInMemoryStore
        let client: KeepTalkingClient
        let nodeID: UUID
        let room: FakeMultiplexer
    }

    private let contextID = UUID()
    private static let schema = "excalidraw-scene"

    private func makeNode() async throws -> Node {
        let store = try await KeepTalkingInMemoryStore.make()
        try await KeepTalkingContext(id: contextID).save(on: store.database)
        let nodeID = UUID()
        try await KeepTalkingNode(id: nodeID).save(on: store.database)
        let room = FakeMultiplexer()
        let client = KeepTalkingClient(
            config: KeepTalkingConfig(contextID: contextID, node: nodeID),
            transport: room.transport,
            localStore: store
        )
        try await client.connect()
        return Node(store: store, client: client, nodeID: nodeID, room: room)
    }

    private func sent<T>(_ room: FakeMultiplexer, _ type: T.Type) -> [T] {
        room.current?.envelopes.compactMap { $0 as? T } ?? []
    }

    private func export(_ state: String) -> KeepTalkingWorkspaceExport {
        .init(data: Data(state.utf8), mimeType: "application/json", pathExtension: "excalidraw")
    }

    /// The stores are left to the process: a store shut down while a client's
    /// connection tasks wind down crashes in `FluentManager.db`.
    private func withNodes(_ count: Int, _ body: ([Node]) async throws -> Void) async throws {
        var nodes: [Node] = []
        for _ in 0..<count { nodes.append(try await makeNode()) }
        defer { for node in nodes { node.client.disconnect() } }
        try await body(nodes)
    }

    @Test("a live delta reaches the room and a peer's page as sent; own echoes are dropped; nothing is stored")
    func liveDeltas() async throws {
        try await withNodes(2) { nodes in
            let (alice, bob) = (nodes[0], nodes[1])
            let (changes, sink) = AsyncStream.makeStream(of: KeepTalkingWorkspaceChange.self)
            let subscription = bob.client.workspaceChanges.observe { sink.yield($0) }
            defer { subscription.cancel() }
            let inbox = AsyncInbox(changes)

            let change = Data(#"{"elements":[{"id":"a","version":2}],"deletedElementIDs":[]}"#.utf8)
            alice.client.publishWorkspaceDelta(schema: Self.schema, change: change)
            let delta = try #require(sent(alice.room, KeepTalkingWorkspaceDeltaPayload.self).last)
            #expect(delta.change == change && delta.schema == Self.schema)

            try await bob.client.handleIncomingEnvelope(delta)
            let received = await inbox.next()
            #expect(received?.change == change && received?.origin == alice.nodeID)
            #expect(alice.client.handleIncomingWorkspaceDelta(delta) == false)
            #expect(try await KeepTalkingWorkspaceStageRow.query(on: bob.store.database).count() == 0)
        }
    }

    @Test("the stage is written as a blob, announced, pulled by a peer and offered to its page once the bytes are here")
    func stageExchange() async throws {
        try await withNodes(2) { nodes in
            let (alice, bob) = (nodes[0], nodes[1])
            let (offers, sink) = AsyncStream.makeStream(of: KeepTalkingWorkspacePendingStage.self)
            let subscription = bob.client.workspaceStages.observe { sink.yield($0) }
            defer { subscription.cancel() }
            let inbox = AsyncInbox(offers)

            let first = try await alice.client.recordWorkspaceStage(schema: Self.schema, export: export("scene v1"))
            #expect(first.holder == alice.nodeID)
            #expect(try await alice.client.workspaceStageData(schema: Self.schema)?.data == Data("scene v1".utf8))
            let announced = try #require(sent(alice.room, KeepTalkingWorkspaceStagePayload.self).last)
            #expect(announced.stage == first)

            try await bob.client.handleIncomingEnvelope(announced)
            #expect(try await bob.client.pendingWorkspaceStages(schema: Self.schema).isEmpty)
            #expect(!sent(bob.room, KeepTalkingBlobTransferEnvelope.self).isEmpty)
            #expect(try await bob.client.handleIncomingWorkspaceStage(announced) == false)

            _ = try await bob.client.storeBlob(Data("scene v1".utf8), mimeType: "application/json")
            await bob.client.offerWorkspaceStagesIfArrived(blobID: first.blobID)
            let offered = await inbox.next()
            #expect(offered?.stage == first && offered?.data == Data("scene v1".utf8))
            #expect(try await bob.client.pendingWorkspaceStages(schema: Self.schema).map(\.stage) == [first])

            try await bob.client.markWorkspaceStageMerged(first)
            #expect(try await bob.client.pendingWorkspaceStages(schema: Self.schema).isEmpty)
            let bobs = try await bob.client.recordWorkspaceStage(schema: Self.schema, export: export("scene v1"))
            #expect(bobs.blobID == first.blobID)
            try await alice.client.handleIncomingEnvelope(
                try #require(sent(bob.room, KeepTalkingWorkspaceStagePayload.self).last))
            #expect(try await alice.client.pendingWorkspaceStages(schema: Self.schema).isEmpty)

            let second = try await alice.client.recordWorkspaceStage(schema: Self.schema, export: export("scene v2"))
            #expect(second.blobID != first.blobID)
            let aliceBlobs = {
                Set(try await KeepTalkingBlobRecord.query(on: alice.store.database).all(\.$id).compactMap { $0 })
            }
            #expect(try await aliceBlobs() == [first.blobID, second.blobID])
            try await alice.client.handleIncomingEnvelope(
                KeepTalkingWorkspaceStagePayload(
                    from: bob.nodeID, contextID: contextID,
                    stage: .init(
                        schema: Self.schema, holder: bob.nodeID, blobID: second.blobID, mimeType: "application/json")))
            #expect(
                try await KeepTalkingClient.pruneAllStrayBlobs(
                    on: alice.store.database, blobStore: alice.client.blobStore) == [first.blobID])

            await alice.client.broadcastWorkspaceStages()
            #expect(sent(alice.room, KeepTalkingWorkspaceStagePayload.self).count == 3)
        }
    }

    @Test("a peer's stage already here is offered at once, and one identical to ours needs no merge")
    func stageAlreadyHere() async throws {
        try await withNodes(2) { nodes in
            let (alice, bob) = (nodes[0], nodes[1])
            let (offers, sink) = AsyncStream.makeStream(of: KeepTalkingWorkspacePendingStage.self)
            let subscription = bob.client.workspaceStages.observe { sink.yield($0) }
            defer { subscription.cancel() }
            let inbox = AsyncInbox(offers)

            _ = try await bob.client.storeBlob(Data("shared".utf8), mimeType: "application/json")
            let stage = try await alice.client.recordWorkspaceStage(schema: Self.schema, export: export("shared"))
            try await bob.client.handleIncomingEnvelope(
                try #require(sent(alice.room, KeepTalkingWorkspaceStagePayload.self).last))
            #expect(await inbox.next()?.stage == stage)

            let own = try await bob.client.recordWorkspaceStage(schema: Self.schema, export: export("shared"))
            #expect(own.blobID == stage.blobID)
            #expect(try await bob.client.pendingWorkspaceStages(schema: Self.schema).isEmpty)
        }
    }

    @Test("viewports leave only while broadcasting and arrive only from the followed peer")
    func viewportFollowMode() async throws {
        try await withNodes(2) { nodes in
            let (alice, bob) = (nodes[0], nodes[1])
            let (updates, sink) = AsyncStream.makeStream(of: KeepTalkingWorkspaceViewportUpdate.self)
            let subscription = bob.client.workspaceViewports.observe { sink.yield($0) }
            defer { subscription.cancel() }
            let inbox = AsyncInbox(updates)
            let state = KeepTalkingWorkspaceViewport(centerX: 10, centerY: 20, zoom: 1.5, timestamp: 1)

            alice.client.publishWorkspaceViewport(schema: Self.schema, state)
            #expect(sent(alice.room, KeepTalkingWorkspaceViewportPayload.self).isEmpty)
            alice.client.setWorkspaceFollowMode(.broadcasting)
            alice.client.publishWorkspaceViewport(schema: Self.schema, state)
            let payload = try #require(sent(alice.room, KeepTalkingWorkspaceViewportPayload.self).last)

            try await bob.client.handleIncomingEnvelope(payload)
            bob.client.setWorkspaceFollowMode(.following(UUID()))
            try await bob.client.handleIncomingEnvelope(payload)
            bob.client.setWorkspaceFollowMode(.following(alice.nodeID))
            try await bob.client.handleIncomingEnvelope(payload)
            let update = await inbox.next()
            #expect(update?.from == alice.nodeID && update?.state == state)
        }
    }

    @Test("an image the canvas holds outlives its message, and goes when the canvas lets it go")
    func resourceClaims() async throws {
        try await withNodes(2) { nodes in
            let (alice, bob) = (nodes[0], nodes[1])
            let bytes = Data("png bytes".utf8)
            let blobID = try await alice.client.storeBlob(bytes, mimeType: "image/png", pathExtension: "png")
            let context = try #require(try await KeepTalkingContext.find(contextID, on: alice.store.database))
            let message = KeepTalkingContextMessage(context: context, sender: .node(node: alice.nodeID), content: "pic")
            try await message.save(on: alice.store.database)
            let attachment = KeepTalkingContextAttachment(
                context: context, parentMessageID: try message.requireID(), sender: .node(node: alice.nodeID),
                blobID: blobID, filename: "pic.png", mimeType: "image/png", byteCount: bytes.count)
            try await attachment.save(on: alice.store.database)
            let attachmentID = try attachment.requireID()

            let held = try await alice.client.claimWorkspaceResource(schema: Self.schema, attachmentID: attachmentID)
            #expect(held.blobID == blobID && held.filename == "pic.png")
            #expect(
                try await alice.client.claimWorkspaceResource(schema: Self.schema, attachmentID: attachmentID) == held)
            let payload = try #require(sent(alice.room, KeepTalkingWorkspaceResourcesPayload.self).last)
            #expect(payload.resources == [held])

            try await bob.client.handleIncomingEnvelope(payload)
            #expect(try await bob.client.workspaceResources(schema: Self.schema) == [held])
            await #expect(throws: KeepTalkingWorkspaceError.self) {
                try await bob.client.workspaceResource(attachmentID)
            }
            #expect(!sent(bob.room, KeepTalkingBlobTransferEnvelope.self).isEmpty)
            _ = try await bob.client.storeBlob(bytes, mimeType: "image/png", pathExtension: "png")
            let resolved = try await bob.client.workspaceResource(attachmentID)
            #expect(resolved.name == "pic.png")
            #expect(resolved.dataURL == "data:image/png;base64,\(bytes.base64EncodedString())")
            #expect(
                try await KeepTalkingClient.pruneAllStrayBlobs(on: bob.store.database, blobStore: bob.client.blobStore)
                    .isEmpty)

            try await message.delete(on: alice.store.database)
            #expect(try await alice.client.contextAttachment(attachmentID, in: contextID) == nil)
            #expect(
                try await KeepTalkingClient.pruneStrayBlobs(
                    among: [blobID], on: alice.store.database, blobStore: alice.client.blobStore
                ).isEmpty)
            #expect(try await alice.client.workspaceResource(attachmentID).name == "pic.png")

            try await alice.client.releaseWorkspaceResources(schema: Self.schema, keeping: [])
            let release = try #require(sent(alice.room, KeepTalkingWorkspaceResourcesPayload.self).last)
            #expect(release.resources.first?.isRemoved == true)
            #expect(
                try await KeepTalkingClient.pruneStrayBlobs(
                    among: [blobID], on: alice.store.database, blobStore: alice.client.blobStore) == [blobID])
            try await bob.client.handleIncomingEnvelope(release)
            #expect(try await bob.client.workspaceResources(schema: Self.schema).isEmpty)
            #expect(
                try await KeepTalkingClient.pruneAllStrayBlobs(on: bob.store.database, blobStore: bob.client.blobStore)
                    == [blobID])

            await alice.client.broadcastWorkspaceStages()
            #expect(sent(alice.room, KeepTalkingWorkspaceResourcesPayload.self).count == 3)
        }
    }

    @Test("the context's workspace list syncs by newest write, with removal as a tombstone")
    func workspaceCatalog() async throws {
        try await withNodes(2) { nodes in
            let (alice, bob) = (nodes[0], nodes[1])
            let (changes, sink) = AsyncStream.makeStream(of: UUID.self)
            let subscription = bob.client.workspaceCatalogChanges.observe { sink.yield($0) }
            defer { subscription.cancel() }
            let inbox = AsyncInbox(changes)

            let added = try await alice.client.addContextWorkspace(
                schema: Self.schema, title: "Canvas", kind: .canvas, provider: "canvas")
            #expect(try await alice.client.contextWorkspaces().map(\.schema) == [Self.schema])
            let catalog = try #require(sent(alice.room, KeepTalkingWorkspaceCatalogPayload.self).last)
            #expect(catalog.workspaces == [added])

            try await bob.client.handleIncomingEnvelope(catalog)
            #expect(await inbox.next() == contextID)
            #expect(try await bob.client.contextWorkspaces().map(\.title) == ["Canvas"])
            #expect(try await bob.client.handleIncomingWorkspaceCatalog(catalog) == false)

            try await alice.client.renameContextWorkspace(schema: Self.schema, title: "  Architecture  ")
            let renamed = try #require(sent(alice.room, KeepTalkingWorkspaceCatalogPayload.self).last)
            #expect(renamed.workspaces.first?.title == "Architecture")
            try await bob.client.handleIncomingEnvelope(renamed)
            #expect(try await bob.client.contextWorkspaces().map(\.title) == ["Architecture"])

            try await alice.client.removeContextWorkspace(schema: Self.schema)
            let removal = try #require(sent(alice.room, KeepTalkingWorkspaceCatalogPayload.self).last)
            #expect(removal.workspaces.first?.isRemoved == true)
            try await bob.client.handleIncomingEnvelope(removal)
            #expect(try await bob.client.contextWorkspaces().isEmpty)
            #expect(try await bob.client.handleIncomingWorkspaceCatalog(catalog) == false)
            #expect(try await bob.client.contextWorkspaces().isEmpty)

            await alice.client.broadcastWorkspaceStages()
            #expect(sent(alice.room, KeepTalkingWorkspaceCatalogPayload.self).count == 4)
        }
    }
}
