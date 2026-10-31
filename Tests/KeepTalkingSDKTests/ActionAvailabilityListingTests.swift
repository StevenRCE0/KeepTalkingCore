import Foundation
import Testing

@testable import KeepTalkingSDK

struct ActionAvailabilityListingTests {

    @Test("a word-code attachment handle resolves against the context's attachments")
    func attachmentWordCodeResolves() {
        let id = UUID.v7()
        let other = UUID.v7()
        let handle = KTResourceManifest.agentHandle(kind: .attachment, id: id)

        #expect(handle.hasPrefix("KT_ATTACHMENT_"))
        #expect(KTResourceManifest.parseAgentHandleCode(handle)?.kind == .attachment)
        #expect(KTResourceManifest.resolveAgentHandle(handle) == nil)

        guard case .unknown = KTResourceManifest.resolveAgentHandle(handle, among: [other]) else {
            Issue.record("a foreign candidate set must not resolve")
            return
        }
        guard
            case .resolved(let resolved) = KTResourceManifest.resolveAgentHandle(
                handle, among: [other, id])
        else {
            Issue.record("the attachment's own id must resolve")
            return
        }
        #expect(resolved == id)
    }

    @Test("a stub is available unless told otherwise")
    func stubDefaultsToAvailable() {
        let stub = KeepTalkingActionStub(
            actionID: UUID(), ownerNodeID: UUID(), name: "Convert to Markdown",
            kind: .plugin, description: "", supportsWakeAssist: false, isCurrentNode: true)
        #expect(stub.isAvailable)
        #expect(stub.unavailableReason == nil)
    }

    @Test("the compact on-device catalog keeps an entry's availability field")
    func compactCatalogKeepsAvailability() {
        let prompt = """
            System prompt header.

            \(AIPromptPresets.actionCatalogHeading) (use kt_run_action to execute):
            Pass an action's `action:` word-name as `action_id`.
            - action: amber-swift-koala  name: Convert to Markdown  type: plugin  node: lab (current)  availability: unavailable (plugin "MarkItDown" is not connected to this node)  description: Convert a document into Markdown. Handles PDFs too.
            - action: brave-calm-otter  name: Browser Task  type: plugin  node: lab (current)  description: Run a browser task.

            Trailing paragraph.
            """
        let entries = AIPromptPresets.compactActionCatalog(fromSystemPrompt: prompt)
        #expect(entries.count == 2)
        #expect(
            entries.first
                == "- action: amber-swift-koala  name: Convert to Markdown  availability: unavailable (plugin \"MarkItDown\" is not connected to this node)  description: Convert a document into Markdown."
        )
        #expect(
            entries.last
                == "- action: brave-calm-otter  name: Browser Task  description: Run a browser task.")
    }
}
