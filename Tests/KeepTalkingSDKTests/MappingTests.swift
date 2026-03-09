import Foundation
import Testing

@testable import KeepTalkingSDK

struct MappingTests {
    @Test("alias upsert keeps one live alias and clears cleanly")
    func aliasRoundTrip() async throws {
        let localStore = KeepTalkingInMemoryStore()
        let node = KeepTalkingNode(id: UUID())
        try await node.save(on: localStore.database)

        let client = KeepTalkingClient(
            config: KeepTalkingConfig(
                signalURL: try #require(URL(string: "ws://127.0.0.1")),
                contextID: UUID(),
                node: UUID()
            ),
            localStore: localStore
        )
        let target = KeepTalkingMappingTarget.node(try #require(node.id))

        try await client.setAlias("  Home Node  ", for: target)
        #expect(try await client.alias(for: target) == "Home Node")

        try await client.setAlias("Alpha", for: target)
        #expect(try await client.alias(for: target) == "Alpha")

        let allMappings = try await client.mappings(
            for: target,
            includeDeleted: true
        )
        #expect(
            allMappings.filter {
                $0.kind == .alias && $0.deletedAt == nil
            }.count == 1
        )

        try await client.setAlias(nil, for: target)
        #expect(try await client.alias(for: target) == nil)
    }

    @Test("tag add and remove deduplicates on normalized value")
    func tagRoundTrip() async throws {
        let localStore = KeepTalkingInMemoryStore()
        let context = KeepTalkingContext(id: UUID())
        try await context.save(on: localStore.database)

        let client = KeepTalkingClient(
            config: KeepTalkingConfig(
                signalURL: try #require(URL(string: "ws://127.0.0.1")),
                contextID: UUID(),
                node: UUID()
            ),
            localStore: localStore
        )
        let target = KeepTalkingMappingTarget.context(try #require(context.id))

        try await client.addTag(" Tenant ", namespace: "tenant", to: target)
        try await client.addTag("tenant", namespace: "tenant", to: target)

        let tags = try await client.tags(for: target, namespace: "tenant")
        #expect(tags.count == 1)
        #expect(tags.first?.value == "Tenant")

        try await client.removeTag(
            "TENANT",
            namespace: "tenant",
            from: target
        )
        #expect(
            try await client.tags(
                for: target,
                namespace: "tenant"
            ).isEmpty
        )
    }
}
