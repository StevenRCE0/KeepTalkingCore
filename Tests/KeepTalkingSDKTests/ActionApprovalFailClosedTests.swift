import Foundation
import Testing

@testable import KeepTalkingSDK

/// An action declaring `blockingAuthorisation` must never execute unattended.
///
/// The approval check used to bind the handler inside its `if` condition, so a
/// host that installed no handler skipped approval entirely and the call ran —
/// it failed *open*. These cover the fail-closed behaviour so that cannot
/// silently return.
struct ActionApprovalFailClosedTests {

    /// Builds a locally-owned primitive action and the request that calls it
    /// from this node, which is the combination the approval gate gates on.
    private func makeFixture(
        blockingAuthorisation: Bool
    ) async throws -> (
        client: KeepTalkingClient,
        context: KeepTalkingContext,
        request: KeepTalkingActionCallRequest
    ) {
        let store = try await KeepTalkingInMemoryStore.make()
        let node = KeepTalkingNode(id: UUID())
        let context = KeepTalkingContext(id: UUID())
        try await node.save(on: store.database)
        try await context.save(on: store.database)

        let bundle = KeepTalkingPrimitiveBundle(
            name: "open-with-url",
            indexDescription: "Open a URL",
            action: .openWithURL
        )
        let action = KeepTalkingAction(
            payload: .primitive(bundle),
            remoteAuthorisable: false,
            blockingAuthorisation: blockingAuthorisation
        )
        // resolveLocalActionForExecution filters on `$node == config.node`, so
        // the action must be hosted by this node to reach the approval gate.
        action.$node.id = try node.requireID()
        // `descriptor` is NOT NULL in the schema.
        action.descriptor = KeepTalkingActionDescriptor(
            subject: nil,
            action: KeepTalkingActionWithDescription(description: "Open a URL"),
            object: nil
        )
        try await action.save(on: store.database)

        let nodeID = try node.requireID()
        let client = KeepTalkingClient(
            config: KeepTalkingConfig(
                contextID: try context.requireID(),
                node: nodeID
            ),
            localStore: store
        )

        let request = KeepTalkingActionCallRequest(
            contextID: try context.requireID(),
            callerNodeID: nodeID,  // local caller — the gated path
            targetNodeID: nodeID,
            call: KeepTalkingActionCall(
                action: try #require(action.id),
                arguments: ["url": .string("https://example.com")]
            )
        )
        return (client, context, request)
    }

    @Test("a blocking-authorisation action is denied when no approval handler is installed")
    func deniesWhenHandlerMissing() async throws {
        let fixture = try await makeFixture(blockingAuthorisation: true)
        // Deliberately install nothing.
        let result = await fixture.client.executeActionCallRequest(
            fixture.request,
            context: fixture.context
        )
        #expect(result.isError == true)
    }

    @Test("a blocking-authorisation action is denied when the handler refuses")
    func deniesWhenHandlerReturnsFalse() async throws {
        let fixture = try await makeFixture(blockingAuthorisation: true)
        fixture.client.setActionApprovalHandler { _, _, _ in false }
        let result = await fixture.client.executeActionCallRequest(
            fixture.request,
            context: fixture.context
        )
        #expect(result.isError == true)
    }

    @Test("a blocking-authorisation action is denied when the context cannot be resolved")
    func deniesWhenContextMissing() async throws {
        let fixture = try await makeFixture(blockingAuthorisation: true)
        // A handler is installed, but with no context there is nothing to show
        // the user, so this must still deny rather than fall through.
        fixture.client.setActionApprovalHandler { _, _, _ in true }
        let result = await fixture.client.executeActionCallRequest(
            fixture.request,
            context: nil
        )
        #expect(result.isError == true)
    }

    // Deliberately not covered here: the positive path (an approving handler
    // letting a call through). This fixture grants the action to nobody, so
    // such a call still fails — at the *grant* check, with its own
    // authorization-flavoured error that cannot be told apart from an approval
    // denial by inspecting `errorMessage`. Asserting on it would either be
    // vacuous or would really be testing grant resolution. Grant behaviour is
    // covered by `RemoteActionCallTests`.
}
