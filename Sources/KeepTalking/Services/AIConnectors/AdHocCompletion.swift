//
//  AdHocCompletion.swift
//  KeepTalking
//
//  One bounded turn on a connector, outside the orchestrator.
//
//  The orchestrator path exists for conversations: history, context, published
//  thinking rows, a loop that runs until the model stops asking for things. A
//  surprising number of jobs want none of that and would rather hand a model
//  one instruction and one piece of material and take an answer back — naming
//  a thing someone just created, summarising a line, answering a plugin's
//  `host.act.request`. Written out longhand each time, those call sites drift:
//  one forgets a token ceiling, another reads `assistantText` without
//  trimming, a third invents its own model fallback.
//
//  This is that shape, once. Tools are optional but supported: a caller can
//  offer a tool set and either read the requested calls back, or pass a
//  `toolExecutor` and let the connector run its own loop. What stays out is
//  the orchestrator's bookkeeping, not the model's capabilities.
//
//  It holds no policy about WHICH model — callers resolve that from wherever
//  their configuration lives and hand it over.
//

import AIProxy
import Foundation
import NIOConcurrencyHelpers

public struct AdHocCompletion: Sendable {
    /// What a single run produced. `thinking` is present only for connectors
    /// that surface reasoning and models that emit it; `toolCalls` only when
    /// tools were offered and the model asked for one.
    public struct Result: Sendable {
        public let text: String
        public let thinking: String?
        public let toolCalls: [AIToolCall]

        public init(text: String, thinking: String?, toolCalls: [AIToolCall] = []) {
            self.text = text
            self.thinking = thinking
            self.toolCalls = toolCalls
        }
    }

    /// What the SDK falls back to wherever no model is configured — the same
    /// literal the orchestrator, the plugin ACT turn and the planners already
    /// default to, named so callers stop repeating it. Connectors map it onto
    /// their provider's spelling (OpenRouter wants `openai/` in front).
    public static let defaultModel = "gpt-5-codex"

    public let connector: any AIConnector
    public let model: String

    /// - Parameter model: Pass nil to take `defaultModel`, which is what a
    ///   caller with no configured model should do rather than decline to run.
    public init(connector: any AIConnector, model: String?) {
        self.connector = connector
        self.model = model ?? Self.defaultModel
    }

    /// Runs one turn: a system instruction, optional leading messages, and the
    /// task.
    ///
    /// - Parameters:
    ///   - instruction: The system line. Say what shape the answer must take —
    ///     there is no conversation here in which to correct a misread.
    ///   - task: The user line: the material to work from.
    ///   - leadingMessages: Messages placed between the instruction and the
    ///     task. Image parts ride here, mirroring the tool-result inlining
    ///     convention.
    ///   - tools: Tools the model may call. Empty means a single round trip
    ///     that cannot call anything.
    ///   - toolChoice: Whether the model must call a tool, may, or must not.
    ///   - toolExecutor: Runs requested calls inside the turn, for connectors
    ///     that loop natively. Without one, calls come back in the result for
    ///     the caller to handle.
    ///   - maxOutputTokens: A ceiling. Leave generous headroom on reasoning
    ///     models — reasoning is drawn from this budget, and a tight cap
    ///     returns an empty `text` having spent the lot on thinking.
    ///   - reasoning: Worth setting `.noReasoning` for jobs where deliberation
    ///     buys nothing, which is most of them at this size.
    ///   - temperature: Left to the connector's default when nil.
    ///   - responseFormat: Ask for `.jsonObject` when the reply is parsed
    ///     rather than read.
    public func run(
        instruction: String,
        task: String,
        leadingMessages: [AIMessage] = [],
        tools: [KeepTalkingActionToolDefinition] = [],
        toolChoice: AIToolChoice? = nil,
        toolExecutor: (@Sendable ([AIToolCall]) async throws -> [AIMessage])? = nil,
        maxOutputTokens: Int? = nil,
        reasoning: AIReasoning? = nil,
        temperature: Double? = nil,
        responseFormat: AIResponseFormat? = nil
    ) async throws -> Result {
        func attempt(_ reasoning: AIReasoning?) async throws -> AITurnResult {
            try await connector.completeTurn(
                messages: [.system(instruction)] + leadingMessages + [.user(task)],
                tools: tools,
                model: model,
                toolChoice: toolChoice,
                stage: tools.isEmpty ? .execution : .planning,
                configuration: AITurnConfiguration(
                    reasoning: reasoning,
                    temperature: temperature,
                    maxOutputTokens: maxOutputTokens,
                    responseFormat: responseFormat
                ),
                toolExecutor: toolExecutor
            )
        }

        // `.noReasoning` is a preference, not a requirement: some models
        // reason unconditionally — Gemini's Pro tiers most visibly — and their
        // endpoints reject the request rather than ignore the knob. Step down
        // to the cheapest effort every reasoning model accepts, and remember
        // the model so later calls skip the refused round trip.
        var fallback = reasoning ?? AIReasoning()
        fallback.effort = .low
        let wantsNoReasoning = reasoning?.effort == .noReasoning
        let knownToRefuse = Self.modelsRequiringReasoning.withLockedValue { $0.contains(model) }

        let turn: AITurnResult
        if wantsNoReasoning && knownToRefuse {
            turn = try await attempt(fallback)
        } else {
            do {
                turn = try await attempt(reasoning)
            } catch let error as AIProxyError
                where wantsNoReasoning && Self.refusesToSkipReasoning(error)
            {
                Self.modelsRequiringReasoning.withLockedValue { _ = $0.insert(model) }
                turn = try await attempt(fallback)
            }
        }
        return Result(
            text: turn.assistantText ?? "",
            thinking: turn.thinking,
            toolCalls: turn.toolCalls
        )
    }

    /// Models whose endpoint refused `.noReasoning` this launch. Process-wide
    /// because the refusal belongs to the model, not to one caller's instance.
    private static let modelsRequiringReasoning = NIOLockedValueBox<Set<String>>([])

    /// A 400 whose body is about reasoning — OpenRouter's "Reasoning is
    /// mandatory for this endpoint", OpenAI's "does not support 'none' with
    /// this model". Both name the thing they refused, which is all we match on.
    private static func refusesToSkipReasoning(_ error: AIProxyError) -> Bool {
        guard case .unsuccessfulRequest(let statusCode, let body) = error, statusCode == 400
        else { return false }
        return body.localizedCaseInsensitiveContains("reasoning")
    }

    /// The common case: one trimmed string back, no tools, and nothing else to
    /// unpack. Defaults to no reasoning (stepping down to low effort on models
    /// that refuse to skip it) — a caller wanting deliberation should use `run`
    /// and say so.
    public func text(
        instruction: String,
        task: String,
        maxOutputTokens: Int? = nil,
        reasoning: AIReasoning? = AIReasoning(effort: .noReasoning, exclude: true),
        temperature: Double? = nil
    ) async throws -> String {
        try await run(
            instruction: instruction,
            task: task,
            maxOutputTokens: maxOutputTokens,
            reasoning: reasoning,
            temperature: temperature
        )
        .text
        .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
