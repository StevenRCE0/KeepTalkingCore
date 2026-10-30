import Foundation
import Testing

@testable import KeepTalkingSDK

struct OpenAIConnectorPromptTests {
    @Test("system prompt routes actions through ACT")
    func actionsUseACTTool() {
        let prompt = OpenAIConnector.keepTalkingSystemPrompt(
            OrchestrationPromptFactor.groupChat(
                tools: KeepTalkingClient.promptToolNames,
                contextTranscript: "",
                currentDate: "2024-01-15T10:00:00Z",
                platform: "macOS"
            )
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
            OrchestrationPromptFactor.groupChat(
                tools: KeepTalkingClient.promptToolNames,
                currentPromptIncludesAttachments: true,
                currentPromptShouldAvoidAutomaticToolUse: true,
                contextTranscript: "",
                currentDate: "2024-01-15T10:00:00Z",
                platform: "macOS"
            )
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
            OrchestrationPromptFactor.groupChat(
                tools: KeepTalkingClient.promptToolNames,
                contextTranscript: "",
                currentDate: "2024-01-15T10:00:00Z",
                platform: "macOS",
                responseLanguages: ["Chinese (Simplified)", "Japanese"]
            )
        )

        #expect(
            prompt.contains(
                "Respond only in these languages unless the user explicitly requests another language: Chinese (Simplified), Japanese."
            )
        )
    }

    @Test("a context style decides which sections exist and in what order")
    func factorsAreTheStyle() {
        let tools = KeepTalkingClient.promptToolNames
        let noAnnotation: [OrchestrationPromptFactor] = [
            .identity(opening: "You are a KeepTalking participant working on a canvas."),
            .environment(platform: "macOS", currentDate: "2026-10-29 10:00", datePlacement: .systemPrompt),
            .privacy,
            .actionRouting(runAction: tools[.runAction], skillMetainfo: tools[.skillMetainfo]),
            .conversationContext(transcript: "Available actions:\n- action: X", scope: .whole),
        ]
        let prompt = OpenAIConnector.keepTalkingSystemPrompt(noAnnotation)

        #expect(prompt.hasPrefix("You are a KeepTalking participant working on a canvas."))
        #expect(prompt.contains(tools[.runAction]))
        #expect(!prompt.contains("THREAD ANNOTATION"))
        #expect(!prompt.contains(tools[.markTurningPoint]))
        #expect(!prompt.contains(tools[.searchThreads]))
        #expect(prompt.hasSuffix("- action: X"))
    }

    @Test("the orchestrated group chat leaves per-turn detail to the turn context")
    func orchestratedGroupChatDefersPerTurnDetail() {
        let note = KeepTalkingSideNoteDTO(
            key: "plan", value: "ship it", isArchived: false, versionCounter: 1, versionWriter: UUID()
        )
        let factors = OrchestrationPromptFactor.groupChat(
            tools: KeepTalkingClient.promptToolNames,
            currentPromptIncludesAttachments: true,
            sideNotes: [note],
            contextTranscript: "",
            currentDate: "2026-10-29 10:00",
            platform: "macOS",
            layout: .orchestrated
        )
        let prompt = AIPromptPresets.render(factors)

        #expect(!factors.contains(.sideNotes([note])))
        #expect(factors.contains(.threadConsults(searchThreads: KeepTalkingClient.searchThreadsToolFunctionName)))
        #expect(!prompt.contains("2026-10-29 10:00"))
        #expect(!prompt.contains("ship it"))
        #expect(!prompt.contains("already includes its newly attached files"))
        #expect(prompt.contains("in the turn context at the end of the conversation"))
    }
}
