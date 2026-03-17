import Foundation
import MCP
import Testing

@testable import KeepTalkingSDK

struct PrimitiveActionManagerTests {
    @Test("primitive action callback is invoked and response is forwarded")
    func callbackResponseForwarded() async throws {
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

        let manager = PrimitiveActionManager { primitive, incomingCall in
            #expect(primitive == bundle)
            #expect(incomingCall.action == call.action)
            #expect(incomingCall.arguments["url"]?.stringValue == "https://example.com")
            return KeepTalkingPrimitiveActionResponse(
                text: "opened",
                isError: true
            )
        }

        let response = try await manager.callAction(action: action, call: call)

        #expect(response.isError == true)
        #expect(response.content.count == 1)
        if case .text(let text) = try #require(response.content.first) {
            #expect(text == "opened")
        } else {
            Issue.record("Expected text content from primitive action callback")
        }
    }

    @Test("primitive action manager rejects missing callback")
    func missingCallbackRejected() async throws {
        let bundle = KeepTalkingPrimitiveBundle.availablePrimitiveActions[0]
        let action = KeepTalkingAction(
            payload: .primitive(bundle),
            remoteAuthorisable: false,
            blockingAuthorisation: false
        )
        let call = KeepTalkingActionCall(action: try #require(action.id))
        let manager = PrimitiveActionManager(callback: nil)

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
        let manager = PrimitiveActionManager { _, _ in
            KeepTalkingPrimitiveActionResponse(text: "unused")
        }

        await #expect(throws: PrimitiveActionManagerError.self) {
            try await manager.registerPrimitiveAction(action)
        }
    }
}
