import Testing

@testable import KeepTalkingSDK

struct OpenAIConnectorPromptTests {
    @Test("system prompt makes KeepTalking action listing conditional")
    func actionListingIsConditional() {
        let prompt = OpenAIConnector.keepTalkingSystemPrompt(
            listingToolFunctionName:
                KeepTalkingClient.listingToolFunctionName,
            attachmentListingToolFunctionName:
                KeepTalkingClient.contextAttachmentListingToolFunctionName,
            attachmentReaderToolFunctionName:
                KeepTalkingClient.contextAttachmentReadToolFunctionName,
            currentPromptIncludesAttachments: false,
            currentPromptShouldAvoidAutomaticToolUse: false,
            contextTranscript: ""
        )

        #expect(
            prompt.contains(
                "Call \(KeepTalkingClient.listingToolFunctionName) only when you need to discover or confirm which KeepTalking action proxy to use."
            )
        )
        #expect(prompt.contains("Do not call it when you can already answer directly"))
    }

    @Test("system prompt prefers already provided attachments over attachment tools")
    func currentTurnAttachmentsArePreferred() {
        let prompt = OpenAIConnector.keepTalkingSystemPrompt(
            listingToolFunctionName:
                KeepTalkingClient.listingToolFunctionName,
            attachmentListingToolFunctionName:
                KeepTalkingClient.contextAttachmentListingToolFunctionName,
            attachmentReaderToolFunctionName:
                KeepTalkingClient.contextAttachmentReadToolFunctionName,
            currentPromptIncludesAttachments: true,
            currentPromptShouldAvoidAutomaticToolUse: true,
            contextTranscript: ""
        )

        #expect(
            prompt.contains(
                "Use those provided files or images directly before considering any tool call."
            )
        )
        #expect(
            prompt.contains(
                "When a file or image is already present in the current turn, or was just injected into the transcript after a tool call, inspect that provided content directly instead of listing or re-reading the same attachment."
            )
        )
        #expect(
            prompt.contains(
                "A file or image injected immediately after ask-for-file is the user-provided attachment you requested."
            )
        )
    }
}
