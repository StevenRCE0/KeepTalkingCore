import Testing

@testable import KeepTalkingSDK

struct AIAttachmentToolPolicyTests {
    @Test("current prompt attachments disable automatic tool use by default")
    func currentPromptAttachmentsDisableAutomaticToolUse() {
        #expect(
            KeepTalkingClient.shouldAllowAutomaticToolUse(
                prompt: "What do you see in this image?",
                hasCurrentPromptAttachments: true
            ) == false
        )
    }

    @Test("explicit tool requests still allow tool use with current prompt attachments")
    func explicitToolRequestKeepsToolUseEnabled() {
        #expect(
            KeepTalkingClient.shouldAllowAutomaticToolUse(
                prompt:
                    "Use the context attachment tool to compare this image with the previous file I shared earlier.",
                hasCurrentPromptAttachments: true
            ) == true
        )
    }

    @Test("tool use stays enabled when the current prompt has no attachments")
    func noCurrentPromptAttachmentsKeepAutomaticToolUseEnabled() {
        #expect(
            KeepTalkingClient.shouldAllowAutomaticToolUse(
                prompt: "Search the web for the latest docs.",
                hasCurrentPromptAttachments: false
            ) == true
        )
    }
}
