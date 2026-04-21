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
}
