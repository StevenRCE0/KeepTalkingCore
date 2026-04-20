import Foundation
import MCP
import OpenAI
import Testing

@testable import KeepTalkingSDK

struct PrimitiveActionManagerTests {
    @Test("primitive action registry is invoked and response is forwarded")
    func registryResponseForwarded() async throws {
        let bundle = KeepTalkingPrimitiveBundle(
            name: "open-url-in-browser",
            indexDescription: "Open a URL",
            action: .openURLInBrowser
        )
        let action = KeepTalkingAction(
            payload: .primitive(bundle),
            remoteAuthorisable: false,
            blockingAuthorisation: false
        )
        let call = KeepTalkingActionCall(
            action: try #require(action.id),
            arguments: ["url": .string("https://example.com")]
        )

        let registry = KeepTalkingPrimitiveRegistry(
            toolParameters: { _ in JSONSchema(.type(.object)) },
            callAction: { primitive, incomingCall in
                #expect(primitive == bundle)
                #expect(incomingCall.action == call.action)
                #expect(incomingCall.arguments["url"]?.stringValue == "https://example.com")
                return KeepTalkingPrimitiveActionResponse(text: "opened", isError: true)
            }
        )
        let manager = PrimitiveActionManager(registry: registry)

        let response = try await manager.callAction(action: action, call: call)

        #expect(response.isError == true)
        #expect(response.content.count == 1)
        if case .text(let text, _, _) = try #require(response.content.first) {
            #expect(text == "opened")
        } else {
            Issue.record("Expected text content from primitive action registry")
        }
    }

    @Test("primitive action manager rejects missing registry")
    func missingRegistryRejected() async throws {
        let bundle = KeepTalkingPrimitiveBundle.availablePrimitiveActions[0]
        let action = KeepTalkingAction(
            payload: .primitive(bundle),
            remoteAuthorisable: false,
            blockingAuthorisation: false
        )
        let call = KeepTalkingActionCall(action: try #require(action.id))
        let manager = PrimitiveActionManager(registry: nil)

        await #expect(throws: PrimitiveActionManagerError.self) {
            _ = try await manager.callAction(action: action, call: call)
        }
    }

    @Test("primitive action manager rejects non primitive payloads")
    func invalidPayloadRejected() async throws {
        let bundle = KeepTalkingSkillBundle(
            name: "skill",
            indexDescription: "Skill",
            directory: URL(fileURLWithPath: "/tmp")
        )
        let action = KeepTalkingAction(
            payload: .skill(bundle),
            remoteAuthorisable: false,
            blockingAuthorisation: false
        )
        let registry = KeepTalkingPrimitiveRegistry(
            toolParameters: { _ in JSONSchema(.type(.object)) },
            callAction: { _, _ in KeepTalkingPrimitiveActionResponse(text: "unused") }
        )
        let manager = PrimitiveActionManager(registry: registry)

        await #expect(throws: PrimitiveActionManagerError.self) {
            try await manager.registerPrimitiveAction(action)
        }
    }
}
