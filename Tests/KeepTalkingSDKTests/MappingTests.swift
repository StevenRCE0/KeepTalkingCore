import Foundation
import Testing

@testable import KeepTalkingSDK

struct MappingTests {
    @Test("alias upsert keeps one live alias and clears cleanly")
    func aliasRoundTrip() async throws {
        let localStore = try await KeepTalkingInMemoryStore.make()
        let node = KeepTalkingNode(id: UUID())
        try await node.save(on: localStore.database)

        let client = KeepTalkingClient(
            config: KeepTalkingConfig(
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
        let localStore = try await KeepTalkingInMemoryStore.make()
        let context = KeepTalkingContext(id: UUID())
        try await context.save(on: localStore.database)

        let client = KeepTalkingClient(
            config: KeepTalkingConfig(
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

    @Test("tag color is generated once and reused across targets")
    func tagColorReuse() async throws {
        let localStore = try await KeepTalkingInMemoryStore.make()
        let context = KeepTalkingContext(id: UUID())
        let node = KeepTalkingNode(id: UUID())
        try await context.save(on: localStore.database)
        try await node.save(on: localStore.database)

        let client = KeepTalkingClient(
            config: KeepTalkingConfig(
                contextID: UUID(),
                node: UUID()
            ),
            localStore: localStore
        )

        let contextTarget = KeepTalkingMappingTarget.context(
            try #require(context.id)
        )
        let nodeTarget = KeepTalkingMappingTarget.node(try #require(node.id))

        try await client.addTag("shared", to: contextTarget)
        try await client.addTag("shared", to: nodeTarget)

        let contextColor = try #require(
            try await client.tags(for: contextTarget).first?.colorHex
        )
        let nodeColor = try #require(
            try await client.tags(for: nodeTarget).first?.colorHex
        )

        #expect(contextColor == nodeColor)
        #expect(contextColor.hasPrefix("#"))
        #expect(contextColor.count == 7)
    }

    @Test("actions use the existing mapping tag model")
    func actionTagRoundTrip() async throws {
        let localStore = try await KeepTalkingInMemoryStore.make()
        let owner = KeepTalkingNode(id: UUID())
        try await owner.save(on: localStore.database)
        let action = try await KeepTalkingClient.registerAction(
            payload: .primitive(
                KeepTalkingPrimitiveBundle(
                    name: "test",
                    indexDescription: "Test action",
                    action: .accessCalendar
                )
            ),
            node: owner,
            on: localStore.database
        )

        let target = KeepTalkingMappingTarget.action(try action.requireID())
        try await KeepTalkingClient.addTag(
            "Utilities",
            to: target,
            on: localStore.database
        )

        let tag = try #require(
            try await KeepTalkingClient.tags(
                for: target,
                on: localStore.database
            ).first
        )
        #expect(tag.target == target)
    }

    @Test("scoped alias partitions from global and revives per scope")
    func scopedAliasRoundTrip() async throws {
        let localStore = try await KeepTalkingInMemoryStore.make()
        let node = KeepTalkingNode(id: UUID())
        let context = KeepTalkingContext(id: UUID())
        let otherContext = KeepTalkingContext(id: UUID())
        try await node.save(on: localStore.database)
        try await context.save(on: localStore.database)
        try await otherContext.save(on: localStore.database)

        let client = KeepTalkingClient(
            config: KeepTalkingConfig(
                contextID: UUID(),
                node: UUID()
            ),
            localStore: localStore
        )
        let target = KeepTalkingMappingTarget.node(try #require(node.id))
        let scopeID = try #require(context.id)
        let otherScopeID = try #require(otherContext.id)

        try await client.setAlias("Global", for: target)
        try await client.setAlias(" Reviewer ", for: target, scopeContextID: scopeID)

        // Scoped write leaves the global alias untouched, and reads are
        // exact-scope at the controller level (fallback lives in the lookup).
        #expect(try await client.alias(for: target) == "Global")
        #expect(try await client.alias(for: target, scopeContextID: scopeID) == "Reviewer")
        #expect(try await client.alias(for: target, scopeContextID: otherScopeID) == nil)

        // Upsert stays within its scope: one live row per (target, scope).
        try await client.setAlias("Editor", for: target, scopeContextID: scopeID)
        #expect(try await client.alias(for: target, scopeContextID: scopeID) == "Editor")
        let scopedRows = try await client.mappings(
            for: target,
            scopeContextID: scopeID,
            includeDeleted: true
        )
        #expect(
            scopedRows.filter { $0.kind == .alias && $0.deletedAt == nil }.count == 1
        )

        // Clearing the scoped alias soft-deletes only that scope's row.
        try await client.setAlias(nil, for: target, scopeContextID: scopeID)
        #expect(try await client.alias(for: target, scopeContextID: scopeID) == nil)
        #expect(try await client.alias(for: target) == "Global")

        // Re-set revives the soft-deleted scoped row instead of adding a second.
        try await client.setAlias("Reviewer", for: target, scopeContextID: scopeID)
        let revived = try await client.mappings(
            for: target,
            scopeContextID: scopeID,
            includeDeleted: true
        )
        #expect(revived.filter { $0.kind == .alias }.count == 1)
    }

    @Test("deleting a context cascades its scoped aliases and spares global ones")
    func scopedAliasCascade() async throws {
        let localStore = try await KeepTalkingInMemoryStore.make()
        let node = KeepTalkingNode(id: UUID())
        let context = KeepTalkingContext(id: UUID())
        try await node.save(on: localStore.database)
        try await context.save(on: localStore.database)

        let target = KeepTalkingMappingTarget.node(try #require(node.id))
        let scopeID = try #require(context.id)

        try await KeepTalkingClient.setAlias(
            "Global",
            for: target,
            on: localStore.database
        )
        try await KeepTalkingClient.setAlias(
            "Reviewer",
            for: target,
            scopeContextID: scopeID,
            on: localStore.database
        )

        try await context.delete(on: localStore.database)

        let survivors = try await KeepTalkingMapping.query(on: localStore.database).all()
        #expect(survivors.count == 1)
        #expect(survivors.first?.value == "Global")
        #expect(
            try await KeepTalkingClient.alias(
                for: target,
                scopeContextID: scopeID,
                on: localStore.database
            ) == nil
        )
    }
}

@Test("static mapping helpers behave like instance wrappers")
func staticMappingHelpersWork() async throws {
    let localStore = try await KeepTalkingInMemoryStore.make()
    let node = KeepTalkingNode(id: UUID())
    try await node.save(on: localStore.database)

    let target = KeepTalkingMappingTarget.node(try #require(node.id))

    try await KeepTalkingClient.setAlias(
        "  Home Node  ",
        for: target,
        on: localStore.database
    )

    #expect(
        try await KeepTalkingClient.alias(
            for: target,
            on: localStore.database
        ) == "Home Node"
    )

    try await KeepTalkingClient.addTag(
        " Tenant ",
        namespace: "tenant",
        to: target,
        on: localStore.database
    )

    let tags = try await KeepTalkingClient.tags(
        for: target,
        namespace: "tenant",
        on: localStore.database
    )
    #expect(tags.count == 1)
    #expect(tags.first?.value == "Tenant")
}
