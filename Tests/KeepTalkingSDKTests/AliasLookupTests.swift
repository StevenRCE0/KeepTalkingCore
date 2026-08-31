import Foundation
import Testing

@testable import KeepTalkingSDK

struct AliasLookupTests {
    @Test("alias resolution prefers alias and exposes lowercase and uppercase IDs")
    func aliasFormatting() {
        let id = UUID(uuidString: "9D86068C-CE26-42EA-B037-81AAC1869002")!
        let resolution = KeepTalkingAliasResolution(
            alias: "Home",
            id: id,
            fallback: "Fallback"
        )

        #expect(resolution.primary() == "Home")
        #expect(resolution.secondary(.uppercase) == id.uuidString.uppercased())
        #expect(resolution.combined(.lowercase) == "Home (\(id.uuidString.lowercased()))")
        #expect(
            resolution.combined(.uppercase)
                == "Home (\(id.uuidString.uppercased()))"
        )
    }

    @Test("alias resolution falls back when alias or id is absent")
    func fallbackFormatting() {
        let fallbackOnly = KeepTalkingAliasResolution(
            alias: nil,
            id: nil,
            fallback: "Autonomous"
        )
        let unknown = KeepTalkingAliasResolution(
            alias: nil,
            id: nil,
            fallback: nil
        )

        #expect(fallbackOnly.primary() == "Autonomous")
        #expect(fallbackOnly.secondary() == nil)
        #expect(fallbackOnly.combined(includeID: false) == "Autonomous")
        #expect(unknown.primary() == "Unknown")
    }

    @Test("alias lookup ignores deleted aliases and resolves senders")
    func lookupResolvesMappingsAndSenders() {
        let nodeID = UUID(uuidString: "158010DE-FAF8-4B04-842D-0D0CD022AAB6")!
        let contextID = UUID(uuidString: "C115CD0F-6739-4ECC-8F35-C45ADBDCBD42")!
        let mappings = [
            KeepTalkingMapping(
                target: .node(nodeID),
                kind: .alias,
                value: "  Home Node  "
            ),
            KeepTalkingMapping(
                target: .context(contextID),
                kind: .alias,
                value: " Workspace "
            ),
            KeepTalkingMapping(
                target: .node(nodeID),
                kind: .alias,
                value: "Deleted",
                deletedAt: .now
            ),
        ]

        let lookup = KeepTalkingAliasLookup(mappings: mappings)

        #expect(lookup.alias(for: .node(nodeID)) == "Home Node")
        #expect(lookup.alias(for: .context(contextID)) == "Workspace")
        #expect(lookup.resolve(.node(nodeID)).combined(.uppercase).hasPrefix("Home Node"))
        #expect(
            lookup.resolve(sender: .autonomous(name: "Scheduler")).primary()
                == "Scheduler"
        )
    }

    @Test("scoped aliases bucket separately and overlay via scoped(to:)")
    func scopedLookup() {
        let nodeID = UUID(uuidString: "158010DE-FAF8-4B04-842D-0D0CD022AAB6")!
        let scopeID = UUID(uuidString: "C115CD0F-6739-4ECC-8F35-C45ADBDCBD42")!
        let otherScopeID = UUID(uuidString: "0B27B7A2-6E5B-4B47-9BA0-6C2D66A2D9E1")!
        let mappings = [
            KeepTalkingMapping(
                target: .node(nodeID),
                kind: .alias,
                value: "Global"
            ),
            KeepTalkingMapping(
                target: .node(nodeID),
                scopeContext: scopeID,
                kind: .alias,
                value: " Reviewer "
            ),
        ]

        let lookup = KeepTalkingAliasLookup(mappings: mappings)

        // Scoped rows never leak into the global map.
        #expect(lookup.alias(for: .node(nodeID)) == "Global")

        // Bucketed accessor: scoped-first, global fallback.
        #expect(lookup.alias(for: .node(nodeID), in: scopeID) == "Reviewer")
        #expect(lookup.alias(for: .node(nodeID), in: otherScopeID) == "Global")
        #expect(lookup.alias(for: .node(nodeID), in: nil) == "Global")

        // Merged view: plain accessors resolve as seen from the scope.
        let scoped = lookup.scoped(to: scopeID)
        #expect(scoped.alias(for: .node(nodeID)) == "Reviewer")
        #expect(scoped.resolve(sender: .node(node: nodeID)).primary() == "Reviewer")
        #expect(lookup.scoped(to: nil).alias(for: .node(nodeID)) == "Global")
        #expect(lookup.scoped(to: otherScopeID).alias(for: .node(nodeID)) == "Global")

        // Autonomous sender composition picks up the scoped node name.
        #expect(
            lookup.resolve(
                sender: .autonomous(name: "Scheduler", node: nodeID),
                in: scopeID
            ).primary() == "Scheduler · Reviewer"
        )
    }
}
