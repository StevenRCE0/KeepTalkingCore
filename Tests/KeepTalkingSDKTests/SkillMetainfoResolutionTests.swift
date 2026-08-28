import Foundation
import MCP
import Testing

@testable import KeepTalkingSDK

/// `kt_skill_metainfo` must accept the SAME action identifier vocabulary the
/// catalog listing teaches — the three-word name — because that is what the
/// model copies into the call. Regression guard: the word-name overhaul
/// updated the listing and `kt_run_action` but left this tool parsing bare
/// UUIDs, so every identifier the listing offered came back
/// `missing_or_invalid_action_id` and the agent lost its only mid-turn way to
/// inspect a skill.
struct SkillMetainfoResolutionTests {

    // MARK: - Helpers

    private func makeCatalog(
        stubs: [KeepTalkingActionStub]
    ) -> KeepTalkingActionRuntimeCatalog {
        KeepTalkingActionRuntimeCatalog(
            catalog: KeepTalkingActionToolCatalog(definitions: []),
            routesByFunctionName: [:],
            actionStubs: stubs,
            remoteSemanticRetrievalActions: [],
            remoteActionCreationActions: [],
            lazyRegistry: KeepTalkingLazyToolRegistry()
        )
    }

    private func payloadObject(_ messages: [AIMessage]) throws -> [String: Any] {
        let message = try #require(messages.first)
        guard case .text(let text) = message.content else {
            Issue.record("tool reply is not a text payload")
            return [:]
        }
        let data = try #require(text.data(using: .utf8))
        return try #require(
            try JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
    }

    private func makeSkillFixture() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
        let manifest = """
            ---
            name: fixture-skill
            description: Fixture description
            ---
            # Fixture Skill
            """
        try manifest.write(
            to: SkillDirectoryDefinitions.entryURL(.manifest, in: directory),
            atomically: true,
            encoding: .utf8
        )
        return directory
    }

    // MARK: - Tests

    @Test("kt_skill_metainfo resolves the word-name the catalog lists")
    func resolvesFriendlyName() async throws {
        let surface = try await AgentSurface.make()
        let fixture = try makeSkillFixture()
        defer { try? FileManager.default.removeItem(at: fixture) }

        let action = try await KeepTalkingClient.registerAction(
            payload: .skill(
                KeepTalkingSkillBundle(
                    name: "fixture-skill",
                    indexDescription: "Fixture skill",
                    directory: fixture
                )
            ),
            node: surface.node,
            on: surface.store.database
        )
        let actionID = try action.requireID()
        let catalog = makeCatalog(stubs: [
            .init(
                actionID: actionID,
                ownerNodeID: surface.nodeID,
                name: "fixture-skill",
                kind: .skill,
                description: "Fixture skill",
                supportsWakeAssist: false,
                isCurrentNode: true
            )
        ])

        let reply = try await surface.client.executeKtSkillMetainfoToolCall(
            toolCallID: "call-1",
            rawArguments: #"{"action_id": "\#(actionID.friendlyNameToken)"}"#,
            runtimeCatalog: catalog,
            context: surface.context
        )
        let payload = try payloadObject(reply)

        #expect(payload["ok"] as? Bool == true)
        #expect(payload["skill_name"] as? String == "fixture-skill")
        #expect(payload["action_id"] as? String == actionID.uuidString.lowercased())
        await surface.shutdown()
    }

    @Test("a resolved word-name of a non-skill action reports the kind, not a naming miss")
    func nonSkillNameFallsThroughToKindError() async throws {
        let surface = try await AgentSurface.make()
        let actionID = UUID()
        let catalog = makeCatalog(stubs: [
            .init(
                actionID: actionID,
                ownerNodeID: surface.nodeID,
                name: "files",
                kind: .filesystem,
                description: "Filesystem",
                supportsWakeAssist: false,
                isCurrentNode: true
            )
        ])

        let reply = try await surface.client.executeKtSkillMetainfoToolCall(
            toolCallID: "call-2",
            rawArguments: #"{"action_id": "\#(actionID.friendlyNameToken)"}"#,
            runtimeCatalog: catalog,
            context: surface.context
        )
        let payload = try payloadObject(reply)

        #expect(payload["error"] as? String == "action_not_found_or_not_a_skill")
        await surface.shutdown()
    }

    @Test("an unrecognized token hands back the skill roster for self-correction")
    func unknownTokenListsSkillRoster() async throws {
        let surface = try await AgentSurface.make()
        let skillActionID = UUID()
        let catalog = makeCatalog(stubs: [
            .init(
                actionID: skillActionID,
                ownerNodeID: surface.nodeID,
                name: "fixture-skill",
                kind: .skill,
                description: "Fixture skill",
                supportsWakeAssist: false,
                isCurrentNode: true
            )
        ])

        let reply = try await surface.client.executeKtSkillMetainfoToolCall(
            toolCallID: "call-3",
            rawArguments: #"{"action_id": "definitely-not-an-action"}"#,
            runtimeCatalog: catalog,
            context: surface.context
        )
        let payload = try payloadObject(reply)

        #expect(payload["error"] as? String == "unknown_action_id")
        let roster = try #require(payload["available_skill_actions"] as? [[String: Any]])
        #expect(
            roster.contains {
                $0["action"] as? String == skillActionID.friendlyNameToken
            }
        )
        await surface.shutdown()
    }
}
