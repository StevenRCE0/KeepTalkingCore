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
                KeepTalkingClient.resourceReadToolFunctionName,
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

        // Asserted as invariant fragments rather than whole sentences: the
        // contract is "route actions through kt_run_action, and ACT owns tool
        // discovery", not the exact copy, which gets edited often.
        #expect(
            prompt.contains(
                "\(KeepTalkingClient.runActionToolFunctionName)(action_id, task)"
            )
        )
        #expect(prompt.contains("end-to-end"))
        #expect(prompt.contains("ACT agent"))
        #expect(prompt.contains("tool discovery"))
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
                KeepTalkingClient.resourceReadToolFunctionName,
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
        #expect(prompt.contains("Do not call attachment tools"))
    }

    @Test("ask-for-file lead text tells the model the attachment is already present")
    func attachmentInjectionLeadTextIsSelfDescribing() {
        // This guidance used to live in the system prompt. It now rides with the
        // injected file itself, so it is asserted where it actually is.
        let text = AIPromptPresets.attachmentInjectionLeadText(
            filename: "report.pdf",
            isImage: false
        )

        #expect(text.contains("report.pdf"))
        #expect(text.contains("the user-provided attachment you just requested"))
        #expect(text.contains("already included in this turn"))
        #expect(text.contains("Do not call context attachment tools"))
    }

    @Test("system prompt includes response language preference")
    func responseLanguagePreferenceIsInjected() {
        let prompt = OpenAIConnector.keepTalkingSystemPrompt(
            ktRunActionToolFunctionName:
                KeepTalkingClient.runActionToolFunctionName,
            ktSkillMetainfoToolFunctionName:
                KeepTalkingClient.ktSkillMetainfoToolFunctionName,
            attachmentListingToolFunctionName:
                KeepTalkingClient.contextAttachmentListingToolFunctionName,
            attachmentReaderToolFunctionName:
                KeepTalkingClient.resourceReadToolFunctionName,
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
            platform: "macOS",
            responseLanguages: ["Chinese (Simplified)", "Japanese"]
        )

        #expect(
            prompt.contains(
                "Respond only in these languages unless the user explicitly requests another language: Chinese (Simplified), Japanese."
            )
        )
    }
}
