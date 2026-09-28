import Foundation
import Testing

@testable import KeepTalkingSDK

struct ModelCatalogTests {
    /// A trimmed models.dev payload: one provider in an unknown shape (must not
    /// blank the rest), and models covering each reasoning knob.
    static let fixture = """
        {
          "broken": { "id": "broken", "models": 42 },
          "openrouter": {
            "id": "openrouter",
            "models": {
              "openai/gpt-5": {
                "attachment": true, "reasoning": true, "tool_call": true,
                "reasoning_options": [{ "type": "effort", "values": ["minimal", "low", "medium", "high"] }],
                "modalities": { "input": ["text", "image"], "output": ["text"] },
                "limit": { "context": 400000, "input": 272000, "output": 128000 }
              },
              "sao10k/l3-lunaris-8b": {
                "attachment": false, "reasoning": false, "tool_call": false,
                "modalities": { "input": ["text"], "output": ["text"] },
                "limit": { "context": 8192, "output": 8192 }
              },
              "deepseek/deepseek-r1": {
                "attachment": false, "reasoning": true, "tool_call": true,
                "reasoning_options": [{ "type": "toggle" }],
                "modalities": { "input": ["text"], "output": ["text"] },
                "limit": { "context": 64000, "output": 16000 }
              }
            }
          },
          "anthropic": {
            "id": "anthropic",
            "models": {
              "claude-opus-5-5": {
                "attachment": true, "reasoning": true, "tool_call": true,
                "reasoning_options": [
                  { "type": "toggle" },
                  { "type": "effort", "values": ["low", "medium", "high", "xhigh", "max"] }
                ],
                "modalities": { "input": ["text", "image", "pdf"], "output": ["text"] },
                "limit": { "context": 1000000, "output": 128000 }
              },
              "claude-haiku-4-5": {
                "attachment": true, "reasoning": true, "tool_call": true,
                "reasoning_options": [{ "type": "budget_tokens", "min": 1024 }],
                "modalities": { "input": ["text", "image", "pdf"], "output": ["text"] },
                "limit": { "context": 200000, "output": 64000 }
              }
            }
          }
        }
        """

    func index() throws -> KeepTalkingModelCatalog.Index {
        try KeepTalkingModelCatalog.Index(modelsDevJSON: Data(Self.fixture.utf8))
    }

    @Test("parses capabilities, limits and reasoning knobs")
    func parsesProfiles() throws {
        let index = try index()
        let gpt = try #require(index.profile(forModel: "openai/gpt-5", providerID: "openrouter"))
        #expect(gpt.supportsToolCalling)
        #expect(gpt.acceptsImages)
        #expect(gpt.contextWindow == 400_000)
        #expect(gpt.maxInputTokens == 272_000)
        #expect(gpt.selectableEfforts == [.minimal, .low, .medium, .high])

        let small = try #require(index.profile(forModel: "sao10k/l3-lunaris-8b", providerID: "openrouter"))
        #expect(!small.supportsToolCalling)
        #expect(!small.supportsAttachments)
        #expect(!small.supportsReasoning)
        #expect(small.selectableEfforts.isEmpty)

        let r1 = try #require(index.profile(forModel: "deepseek/deepseek-r1", providerID: "openrouter"))
        #expect(r1.reasoningIsToggle)
        #expect(r1.selectableEfforts == [.noReasoning, .medium])

        // A toggle beside graded efforts adds "off"; `max` has no KT effort.
        let opus = try #require(index.profile(forModel: "claude-opus-5-5", providerID: "anthropic"))
        #expect(opus.selectableEfforts == [.noReasoning, .low, .medium, .high, .xhigh])

        let haiku = try #require(index.profile(forModel: "claude-haiku-4-5", providerID: "anthropic"))
        #expect(haiku.reasoning == .budget)
    }

    @Test("lookup falls back across variant suffixes, vendor prefixes and providers")
    func lookupFallbacks() throws {
        let index = try index()
        #expect(index.profile(forModel: "openai/gpt-5:free", providerID: "openrouter")?.contextWindow == 400_000)
        #expect(index.profile(forModel: "OpenAI/GPT-5", providerID: "openrouter") != nil)
        // An Anthropic model routed through OpenRouter's vendor/model naming.
        #expect(index.profile(forModel: "anthropic/claude-opus-5-5", providerID: "openrouter") != nil)
        // A custom endpoint with no provider hint.
        #expect(index.profile(forModel: "claude-haiku-4-5", providerID: nil) != nil)
        #expect(index.profile(forModel: "no-such-model", providerID: "openrouter") == nil)
    }

    @Test("efforts snap to the nearest accepted level")
    func effortSnapping() {
        let graded = AIModelProfile(reasoning: .efforts([.low, .medium, .high]))
        #expect(graded.resolvedEffort(nil) == nil)
        #expect(graded.resolvedEffort(.medium) == .medium)
        #expect(graded.resolvedEffort(.xhigh) == .high)
        #expect(graded.resolvedEffort(.minimal) == .low)
        // Can't be switched off: provider default, not some other level.
        #expect(graded.resolvedEffort(.noReasoning) == nil)

        let none = AIModelProfile(reasoning: .unsupported)
        #expect(none.resolvedEffort(.high) == nil)
        let toggle = AIModelProfile(reasoning: .toggle)
        #expect(toggle.resolvedEffort(.high) == .medium)
        #expect(toggle.resolvedEffort(.noReasoning) == .noReasoning)
    }

    @Test("history trims from the oldest end to the budget")
    func historyTrimming() {
        let messages = (0..<10).map { AIMessage.user(String(repeating: "x", count: 400) + "\($0)") }
        let each = messages[0].approximateTokenCount
        let trimmed = messages.trimmedToTokenBudget(each * 3 + 1)
        #expect(trimmed.droppedCount == 7)
        #expect(trimmed.messages == Array(messages.suffix(3)))
        #expect(messages.trimmedToTokenBudget(0).messages.isEmpty)
    }

    @Test("input budget leaves room for the reply")
    func inputBudget() {
        #expect(AIModelProfile(contextWindow: 8192, maxOutputTokens: 8192).inputTokenBudget == 6144)
        #expect(AIModelProfile(contextWindow: 200_000, maxOutputTokens: 8_000).inputTokenBudget == 192_000)
        #expect(
            AIModelProfile(contextWindow: 400_000, maxInputTokens: 272_000, maxOutputTokens: 128_000)
                .inputTokenBudget == 272_000
        )
        #expect(AIModelProfile().inputTokenBudget == nil)
    }

    @Test("image parts become placeholders for text-only models")
    func imageStripping() throws {
        let url = try #require(URL(string: "data:image/png;base64,AAAA"))
        let message = AIMessage.user(parts: [.text("look"), .imageURL(url)])
        let stripped = message.replacingImageParts(with: "[image]")
        #expect(stripped.content == .parts([.text("look"), .text("[image]")]))
    }

    static func prompt(_ profile: AIModelProfile?) -> String {
        OpenAIConnector.keepTalkingSystemPrompt(
            ktRunActionToolFunctionName: KeepTalkingClient.runActionToolFunctionName,
            ktSkillMetainfoToolFunctionName: KeepTalkingClient.ktSkillMetainfoToolFunctionName,
            attachmentListingToolFunctionName: KeepTalkingClient.contextAttachmentListingToolFunctionName,
            attachmentReaderToolFunctionName: KeepTalkingClient.resourceReadToolFunctionName,
            searchThreadsToolFunctionName: KeepTalkingClient.searchThreadsToolFunctionName,
            markTurningPointToolFunctionName: KeepTalkingClient.markTurningPointToolFunctionName,
            markChitterChatterToolFunctionName: KeepTalkingClient.markChitterChatterToolFunctionName,
            currentPromptIncludesAttachments: false,
            currentPromptShouldAvoidAutomaticToolUse: false,
            contextTranscript: "Available actions:\n- action: X",
            currentDate: "2026-09-28 10:00",
            platform: "macOS",
            modelProfile: profile
        )
    }

    @Test("tool-less models get a conversation-only prompt")
    func conversationOnlyPrompt() {
        let prompt = Self.prompt(AIModelProfile(supportsToolCalling: false, supportsAttachments: false))
        #expect(prompt.contains("cannot call tools"))
        #expect(prompt.contains("cannot read attachments"))
        #expect(!prompt.contains(KeepTalkingClient.runActionToolFunctionName))
        #expect(!prompt.contains("THREAD ANNOTATION"))
        #expect(prompt.contains("Available actions"))
    }

    @Test("capability notes appear only for known limits")
    func capabilityNotes() {
        #expect(!Self.prompt(nil).contains("§ Model capabilities"))
        let limited = Self.prompt(AIModelProfile(supportsAttachments: false, contextWindow: 128_000))
        #expect(limited.contains("§ Model capabilities"))
        #expect(limited.contains("cannot read attachments"))
        #expect(limited.contains("about 128k tokens"))
        #expect(limited.contains(KeepTalkingClient.runActionToolFunctionName))
        #expect(AIPromptPresets.tokenCountDescription(1_000_000) == "1M")
        #expect(AIPromptPresets.tokenCountDescription(8192) == "8k")
    }
}
