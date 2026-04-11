import Testing

@testable import KeepTalkingSDK

struct OpenAIConnectorPromptTests {
    @Test("system prompt routes actions through ACT")
    func actionsUseACTTool() {
        let prompt = OpenAIConnector.keepTalkingSystemPrompt(
            ktRunActionToolFunctionName:
                KeepTalkingClient.runActionToolFunctionName,
            ktSkillMetainfoToolFunctionName:
                KeepTalkingClient.ktSkillMetainfoToolFunctionName,
            attachmentListingToolFunctionName:
                KeepTalkingClient.contextAttachmentListingToolFunctionName,
            attachmentReaderToolFunctionName:
                KeepTalkingClient.contextAttachmentReadToolFunctionName,
            searchThreadsToolFunctionName:
                KeepTalkingClient.searchThreadsToolFunctionName,
            markTurningPointToolFunctionName:
                KeepTalkingClient.markTurningPointToolFunctionName,
            markChitterChatterToolFunctionName:
                KeepTalkingClient.markChitterChatterToolFunctionName,
            currentPromptIncludesAttachments: false,
            currentPromptShouldAvoidAutomaticToolUse: false,
            contextTranscript: "",
            currentDate: "2024-01-15T10:00:00Z",
            platform: "macOS"
        )

        #expect(
            prompt.contains(
                "Call \(KeepTalkingClient.runActionToolFunctionName)(action_id, task) to execute an action end-to-end"
            )
        )
        #expect(prompt.contains("ACT agent will handle tool discovery"))
        #expect(!prompt.contains("listing tool"))
    }

    @Test("system prompt prefers already provided attachments over attachment tools")
    func currentTurnAttachmentsArePreferred() {
        let prompt = OpenAIConnector.keepTalkingSystemPrompt(
            ktRunActionToolFunctionName:
                KeepTalkingClient.runActionToolFunctionName,
            ktSkillMetainfoToolFunctionName:
                KeepTalkingClient.ktSkillMetainfoToolFunctionName,
            attachmentListingToolFunctionName:
                KeepTalkingClient.contextAttachmentListingToolFunctionName,
            attachmentReaderToolFunctionName:
                KeepTalkingClient.contextAttachmentReadToolFunctionName,
            searchThreadsToolFunctionName:
                KeepTalkingClient.searchThreadsToolFunctionName,
            markTurningPointToolFunctionName:
                KeepTalkingClient.markTurningPointToolFunctionName,
            markChitterChatterToolFunctionName:
                KeepTalkingClient.markChitterChatterToolFunctionName,
            currentPromptIncludesAttachments: true,
            currentPromptShouldAvoidAutomaticToolUse: true,
            contextTranscript: "",
            currentDate: "2024-01-15T10:00:00Z",
            platform: "macOS"
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
