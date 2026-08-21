import AIProxy
import Foundation

// MARK: - Audio Interface Agent
//
// The audio interface agent is a voice↔text bridge, not a standalone agent.
// It sits between the user's microphone/speaker and the main text agent:
//
//   User speaks → Audio model acks with voice + extracts intent via tool call
//   → Main agent processes intent → Audio model rephrases response for speech
//
// The audio model handles transcription, acknowledgement, and speech synthesis.
// The main agent handles reasoning, tool use, and knowledge retrieval.

public struct AudioInterfaceAgent: Sendable {

    public struct Configuration: Sendable {
        public let audioModel: String
        public let voice: String
        public let audioFormat: String
        public let maxBridgeTurns: Int
        public let bridgeSystemPrompt: String
        public let rephraseSystemPrompt: String
        public let ackSystemPrompt: String
        public let deferralSystemPrompt: String
        public let responseLanguages: [String]
        public let wakePhrase: String?

        /// Creates a bridge configuration.
        ///
        /// Each `…SystemPrompt` argument overrides the corresponding built-in
        /// default; passing `nil` keeps the default. In both cases the wake
        /// phrase instruction derived from `wakePhrase` and the language
        /// instruction derived from `responseLanguages` are appended to the
        /// stored prompt.
        ///
        /// - Parameters:
        ///   - audioModel: Model identifier used for every audio-model turn.
        ///   - voice: Voice name requested for synthesized audio output.
        ///   - audioFormat: Wire format requested for synthesized audio output.
        ///   - maxBridgeTurns: Maximum number of intent-extraction turns before
        ///     the bridge flow gives up.
        ///   - responseLanguages: Languages the spoken replies should use.
        ///     Entries are trimmed of surrounding whitespace, and empty or
        ///     duplicate entries are dropped. An empty list adds no language
        ///     instruction to the prompts.
        ///   - wakePhrase: The wake phrase that activates the agent. When set,
        ///     the prompts tell the model to adopt a name contained in the
        ///     phrase as its identity, and the bridge prompt to treat the
        ///     phrase opening the captured audio as the activation trigger
        ///     rather than request content. `nil` or blank adds nothing.
        ///   - bridgeSystemPrompt: System prompt for the intent-extraction
        ///     turns, which decide whether to speak back or call the delegation
        ///     tool.
        ///   - rephraseSystemPrompt: System prompt used to rephrase the main
        ///     agent's answer for spoken delivery. Also used by
        ///     `speak(text:connector:audioOutputHandler:)`.
        ///   - ackSystemPrompt: System prompt for the short acknowledgement
        ///     spoken while the delegate is running.
        ///   - deferralSystemPrompt: System prompt for the notice spoken when
        ///     the delegated turn defers instead of answering.
        public init(
            audioModel: String,
            voice: String = "alloy",
            audioFormat: String = "pcm16",
            maxBridgeTurns: Int = 3,
            responseLanguages: [String] = [],
            wakePhrase: String? = nil,
            bridgeSystemPrompt: String? = nil,
            rephraseSystemPrompt: String? = nil,
            ackSystemPrompt: String? = nil,
            deferralSystemPrompt: String? = nil
        ) {
            self.audioModel = audioModel
            self.voice = voice
            self.audioFormat = audioFormat
            self.maxBridgeTurns = maxBridgeTurns
            self.responseLanguages = responseLanguages.reduce(into: []) { result, language in
                let trimmed = language.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty, !result.contains(trimmed) else { return }
                result.append(trimmed)
            }
            let trimmedWakePhrase = wakePhrase?.trimmingCharacters(in: .whitespacesAndNewlines)
            self.wakePhrase = (trimmedWakePhrase?.isEmpty ?? true) ? nil : trimmedWakePhrase
            self.bridgeSystemPrompt =
                (bridgeSystemPrompt ?? Self.defaultBridgeSystemPrompt)
                + Self.wakeInstruction(for: self.wakePhrase, coversCapturedAudio: true)
                + Self.languageInstruction(for: self.responseLanguages)
            self.rephraseSystemPrompt =
                (rephraseSystemPrompt ?? Self.defaultRephraseSystemPrompt)
                + Self.wakeInstruction(for: self.wakePhrase, coversCapturedAudio: false)
                + Self.languageInstruction(for: self.responseLanguages)
            self.ackSystemPrompt =
                (ackSystemPrompt ?? Self.defaultAckSystemPrompt)
                + Self.wakeInstruction(for: self.wakePhrase, coversCapturedAudio: false)
                + Self.languageInstruction(for: self.responseLanguages)
            self.deferralSystemPrompt =
                (deferralSystemPrompt ?? Self.defaultDeferralSystemPrompt)
                + Self.wakeInstruction(for: self.wakePhrase, coversCapturedAudio: false)
                + Self.languageInstruction(for: self.responseLanguages)
        }

        static let defaultBridgeSystemPrompt = """
            You are a voice interface bridge. You have two jobs:
            1. Respond briefly with spoken audio.
            2. Call the `delegate_to_agent` tool only when the user has a real \
            backend intent: a fact/information question, a request that needs \
            context lookup, or an action/execution request. Do not delegate \
            greetings, thanks, acknowledgements, filler, small talk, unclear \
            speech, or purely conversational replies.

            Never tell the user you can't do something, that you're unable, that \
            it isn't possible, or otherwise refuse a request — you do not decide \
            what is possible, the backend agent does. If a request might need any \
            capability beyond pure small talk, delegate it instead of declining. \
            Only voice an inability when the backend agent's response itself \
            states one.
            """

        static let defaultRephraseSystemPrompt = """
            You are a voice interface. The user asked something and a backend \
            agent produced the answer below. Rephrase it naturally for spoken \
            delivery — concise and conversational. Respond with audio.
            """

        static let defaultAckSystemPrompt = """
            You are a voice interface. The user just made a request that is being \
            handed to a backend agent to fulfil. Acknowledge in ONE short, natural \
            spoken sentence that you're on it (e.g. "Sure, let me look into that"). \
            Do NOT attempt to answer the request yourself and do NOT invent \
            details. Respond with audio.
            """

        static let defaultDeferralSystemPrompt = """
            You are a voice interface. The user's request was started but can't \
            finish right now — it needs another step, such as a confirmation or \
            another participant. In ONE short, natural spoken sentence, tell the \
            user it's underway and that the result will appear in the \
            conversation when it's ready. Do NOT attempt to answer the request \
            and do NOT invent any result. Respond with audio.
            """

        /// Prompt appendix carrying the wake phrase. All prompts get the
        /// identity rule (a name inside the phrase is the agent's name); the
        /// bridge prompt — the only turn that hears the captured audio, which
        /// starts at the wake phrase via pre-roll — additionally gets the rule
        /// to treat that opening phrase as the trigger, not request content.
        static func wakeInstruction(for wakePhrase: String?, coversCapturedAudio: Bool) -> String {
            guard let wakePhrase else { return "" }
            var instruction =
                "\nThe user activates you by speaking the wake phrase \"\(wakePhrase)\". "
                + "If that phrase contains a name, it is your name — adopt it as your "
                + "identity when speaking about yourself."
            if coversCapturedAudio {
                instruction +=
                    " The captured request audio starts at that wake phrase, so it may "
                    + "open with it — treat it purely as the activation trigger, never "
                    + "as part of the request's content."
            }
            return instruction
        }

        static func languageInstruction(for languages: [String]) -> String {
            guard !languages.isEmpty else { return "" }
            if languages.count == 1 {
                return "\nRespond in \(languages[0]) unless the user explicitly requests another language."
            }
            return
                "\nRespond only in these languages unless the user explicitly requests another language: \(languages.joined(separator: ", "))."
        }
    }

    /// The request forwarded to the main text agent for processing.
    /// Carries everything the app needs to enqueue an agent run via
    /// `enqueueAIPrompt` or equivalent.
    public struct DelegationRequest: Sendable {
        /// The context this voice session belongs to.
        public let contextID: UUID
        /// Verbatim transcription of what the user said.
        public let transcript: String
        /// Distilled intent — suitable as the prompt text for the main agent.
        public let intent: String

        /// Creates a delegation request.
        ///
        /// - Parameters:
        ///   - contextID: The context this voice session belongs to.
        ///   - transcript: Verbatim transcription of what the user said.
        ///   - intent: Distilled intent, suitable as the main agent's prompt text.
        public init(contextID: UUID, transcript: String, intent: String) {
            self.contextID = contextID
            self.transcript = transcript
            self.intent = intent
        }
    }

    /// The full result of a bridge flow run.
    public struct BridgeResult: Sendable {
        public let contextID: UUID
        public let transcript: String
        public let intent: String
        public let delegateResponse: String
        /// The final rephrased audio output for the user.
        public let audioOutput: AIAudioOutput?
        /// The initial acknowledgement audio (from the extraction turn).
        public let ackAudioOutput: AIAudioOutput?

        /// Creates a bridge result.
        ///
        /// - Parameters:
        ///   - contextID: The context the voice session belonged to.
        ///   - transcript: Verbatim transcription of what the user said. Empty
        ///     when the audio model answered without calling the delegation tool
        ///     and reported no transcript.
        ///   - intent: The intent extracted from the user's speech.
        ///   - delegateResponse: The main agent's answer, or the deferral reason
        ///     when the agent turn suspended. Empty when no delegation happened.
        ///   - audioOutput: The final rephrased audio output for the user.
        ///   - ackAudioOutput: The initial acknowledgement audio from the
        ///     extraction turn, if the model produced any.
        public init(
            contextID: UUID,
            transcript: String,
            intent: String,
            delegateResponse: String,
            audioOutput: AIAudioOutput? = nil,
            ackAudioOutput: AIAudioOutput? = nil
        ) {
            self.contextID = contextID
            self.transcript = transcript
            self.intent = intent
            self.delegateResponse = delegateResponse
            self.audioOutput = audioOutput
            self.ackAudioOutput = ackAudioOutput
        }
    }

    /// Called when the audio agent produces audio output (ack or final).
    /// The app layer uses this to stream audio to the speaker in real time.
    public typealias AudioOutputHandler = @Sendable (AIAudioOutput) async -> Void

    /// The result of delegating an intent to the main text agent.
    public enum DelegateOutcome: Sendable {
        /// The agent produced a final answer to speak.
        case answered(String)
        /// The agent turn suspended waiting on something out of band (a
        /// confirmation, another participant, a file). The associated text is a
        /// short human reason to speak; the eventual answer arrives in the
        /// conversation, not here, so the bridge acknowledges and ends the turn.
        case deferred(reason: String)
    }

    /// Called to delegate the extracted intent to the main text agent.
    /// Returns either the agent's answer or a deferral when the turn suspends.
    public typealias Delegate = @Sendable (DelegationRequest) async throws -> DelegateOutcome

    /// Called for status updates during the bridge flow.
    public typealias StatusObserver = @Sendable (BridgeStatus) async -> Void

    public enum BridgeStatus: Sendable {
        case extracting(turn: Int)
        case ackAudioReady
        case intentExtracted(DelegationRequest)
        case delegating
        case rephrasing
        case done
        case failed(String)
    }

    private let configuration: Configuration
    public typealias LogHandler = @Sendable (String) -> Void
    public var onLog: LogHandler?

    public init(configuration: Configuration) {
        self.configuration = configuration
    }

    // MARK: - Tool definition

    static let delegateToolName = "delegate_to_agent"

    static let delegateToolDefinition: KeepTalkingActionToolDefinition = {
        .init(
            functionName: delegateToolName,
            actionID: UUID(),
            ownerNodeID: UUID(),
            source: .primitive,
            description:
                "Extract the user's intent from their speech and delegate it to a backend agent for processing.",
            parameters: [
                "type": .string("object"),
                "properties": .object([
                    "user_transcript": .object([
                        "type": .string("string"),
                        "description": .string("Verbatim transcription of what the user said."),
                    ]),
                    "intent": .object([
                        "type": .string("string"),
                        "description": .string(
                            "A clear, concise instruction describing what the user wants, extracted from their speech."
                        ),
                    ]),
                ]),
                "required": .array([.string("user_transcript"), .string("intent")]),
                "additionalProperties": .bool(false),
            ]
        )
    }()

    // MARK: - Bridge flow

    /// Run the full bridge flow: extract intent from audio → delegate to main
    /// agent → rephrase response as speech.
    ///
    /// - Parameters:
    ///   - audioData: Raw audio bytes (PCM16 or WAV, depending on `inputFormat`).
    ///   - inputFormat: Wire format of the input audio (e.g. "wav", "pcm16").
    ///   - contextID: The context this voice session belongs to. Stamped onto
    ///     the `DelegationRequest` handed to `delegate` and onto the returned
    ///     `BridgeResult`; it is not otherwise interpreted here.
    ///   - connector: The AI connector used for every audio-model turn
    ///     (extraction, acknowledgement, deferral notice, and rephrase). The
    ///     main agent is reached through `delegate`, not through this connector.
    ///   - delegate: Callback that forwards the extracted intent to the main agent.
    ///   - audioOutputHandler: Called when audio output is produced (for real-time playback).
    ///   - statusObserver: Called with status updates during the flow.
    ///   - routingContext: Optional extra system-prompt text prepended to the
    ///     intent-extraction turns, after the bridge system prompt and before
    ///     the user's audio. Ignored when `nil` or empty.
    /// - Returns: A `BridgeResult` carrying the transcript, extracted intent,
    ///   the delegate's response, and the ack/final audio outputs. When the
    ///   audio model answers the utterance itself without calling the delegate
    ///   tool, `delegateResponse` is empty and the ack audio is returned as both
    ///   `audioOutput` and `ackAudioOutput`.
    /// - Throws: `AudioInterfaceAgentError.intentExtractionFailed` if the
    ///   extraction loop uses up `Configuration.maxBridgeTurns` without the
    ///   model producing either a parsable delegation tool call or a spoken
    ///   reply. Also rethrows any error from the audio-model turns, from
    ///   `delegate`, and `CancellationError` if the task is cancelled between
    ///   extraction turns.
    public func run(
        audioData: Data,
        inputFormat: String,
        contextID: UUID,
        connector: any AIConnector,
        delegate: @escaping Delegate,
        audioOutputHandler: AudioOutputHandler? = nil,
        statusObserver: StatusObserver? = nil,
        routingContext: String? = nil
    ) async throws -> BridgeResult {
        log(
            "run() started — audioData: \(audioData.count) bytes, format: \(inputFormat), model: \(configuration.audioModel), voice: \(configuration.voice)"
        )

        // Phase 1: Extract intent from user audio
        log("phase 1: extracting intent…")
        let extraction: ExtractionResult?
        do {
            extraction = try await extractIntent(
                audioData: audioData,
                inputFormat: inputFormat,
                contextID: contextID,
                connector: connector,
                audioOutputHandler: audioOutputHandler,
                statusObserver: statusObserver,
                routingContext: routingContext
            )
        } catch {
            log("phase 1 FAILED: \(error.localizedDescription)")
            throw error
        }

        guard let extraction else {
            let msg = "Failed to extract intent after \(configuration.maxBridgeTurns) turns"
            log(msg)
            await statusObserver?(.failed(msg))
            throw AudioInterfaceAgentError.intentExtractionFailed
        }

        log("phase 1 done — transcript: \"\(extraction.transcript)\", intent: \"\(extraction.intent)\"")

        guard let request = extraction.request else {
            await statusObserver?(.done)
            log("bridge flow complete without delegation")
            return BridgeResult(
                contextID: contextID,
                transcript: extraction.transcript,
                intent: extraction.intent,
                delegateResponse: "",
                audioOutput: extraction.ackAudio,
                ackAudioOutput: extraction.ackAudio
            )
        }

        await statusObserver?(.intentExtracted(request))

        // Phase 2: Delegate to main agent
        log("phase 2: delegating to main agent…")
        await statusObserver?(.delegating)

        // Speak a brief acknowledgement *concurrently* with the (often slow)
        // delegate — but only if the extraction turn stayed silent, which is the
        // usual case: audio models emit speech XOR a tool call, so a delegating
        // turn produces no audio and the user would otherwise hear nothing until
        // the rephrased answer lands. Awaited before phase 3 so the ack never
        // overlaps the spoken answer in the player FIFO.
        let ackTask: Task<Void, Never>?
        if extraction.ackAudio == nil, let audioOutputHandler {
            ackTask = Task { [self] in
                await speakDelegationAck(
                    intent: request.intent,
                    connector: connector,
                    audioOutputHandler: audioOutputHandler
                )
            }
        } else {
            ackTask = nil
        }

        let outcome: DelegateOutcome
        do {
            outcome = try await delegate(request)
        } catch {
            ackTask?.cancel()
            _ = await ackTask?.value
            log("phase 2 FAILED (delegate threw): \(error.localizedDescription)")
            throw error
        }
        // Ensure the ack has finished streaming before the next audio begins.
        _ = await ackTask?.value

        switch outcome {
            case .deferred(let reason):
                // The backend turn suspended on an out-of-band step. Speak a
                // short status and end here; the answer will arrive in the
                // conversation. We do NOT wait it out (the voice session may be
                // gone by the time it resolves).
                log("phase 2 deferred — \(reason)")
                await statusObserver?(.rephrasing)
                let deferResult: AITurnResult
                do {
                    deferResult = try await speakDeferral(
                        reason: reason,
                        connector: connector,
                        audioOutputHandler: audioOutputHandler
                    )
                } catch {
                    log("phase 3 (deferral) FAILED: \(error.localizedDescription)")
                    throw error
                }
                await statusObserver?(.done)
                log("bridge flow complete (deferred)")
                return BridgeResult(
                    contextID: contextID,
                    transcript: request.transcript,
                    intent: request.intent,
                    delegateResponse: reason,
                    audioOutput: deferResult.audioOutput,
                    ackAudioOutput: extraction.ackAudio
                )

            case .answered(let delegateResponse):
                log(
                    "phase 2 done — delegate response (\(delegateResponse.count) chars): \(String(delegateResponse.prefix(300)))"
                )

                // Phase 3: Rephrase for speech
                log("phase 3: rephrasing for speech…")
                await statusObserver?(.rephrasing)
                let rephraseResult: AITurnResult
                do {
                    rephraseResult = try await rephraseForSpeech(
                        intent: request.intent,
                        delegateResponse: delegateResponse,
                        connector: connector,
                        audioOutputHandler: audioOutputHandler
                    )
                } catch {
                    log("phase 3 FAILED: \(error.localizedDescription)")
                    throw error
                }
                log(
                    "phase 3 done — audioOutput: \(rephraseResult.audioOutput?.data?.count ?? 0) bytes, text: \(rephraseResult.assistantText?.prefix(100) ?? "nil")"
                )

                if rephraseResult.audioOutput == nil {
                    log("WARNING: no audio output from rephrase turn")
                }
                // Audio was already streamed chunk-by-chunk via streamingAudioHandler.
                // No need to deliver the full blob again.

                await statusObserver?(.done)
                log("bridge flow complete")

                return BridgeResult(
                    contextID: contextID,
                    transcript: request.transcript,
                    intent: request.intent,
                    delegateResponse: delegateResponse,
                    audioOutput: rephraseResult.audioOutput,
                    ackAudioOutput: extraction.ackAudio
                )
        }
    }

    // MARK: - Intent extraction (Phase 1)

    private struct ExtractionResult {
        let request: DelegationRequest?
        let transcript: String
        let intent: String
        let ackAudio: AIAudioOutput?
    }

    private func extractIntent(
        audioData: Data,
        inputFormat: String,
        contextID: UUID,
        connector: any AIConnector,
        audioOutputHandler: AudioOutputHandler?,
        statusObserver: StatusObserver?,
        routingContext: String?
    ) async throws -> ExtractionResult? {
        var transcript: [AIMessage] = [.system(configuration.bridgeSystemPrompt)]
        if let routingContext, !routingContext.isEmpty {
            transcript.append(.system(routingContext))
            log("routing context injected (\(routingContext.count) chars)")
        }
        transcript.append(.user(parts: [.inputAudio(data: audioData, format: inputFormat)]))

        let streamHandler: AIStreamingAudioHandler? = audioOutputHandler.map { handler in
            AIStreamingAudioHandler { chunk in
                await handler(AIAudioOutput(data: chunk))
            }
        }

        let turnConfig = AITurnConfiguration(
            modalities: ["text", "audio"],
            audioOutput: AIAudioOutputConfig(
                voice: configuration.voice,
                format: configuration.audioFormat
            ),
            streamingAudioHandler: streamHandler
        )

        var ackAudio: AIAudioOutput?

        for turn in 1...configuration.maxBridgeTurns {
            try Task.checkCancellation()
            log(
                "extraction turn \(turn)/\(configuration.maxBridgeTurns) — sending \(transcript.count) messages to \(configuration.audioModel)"
            )
            await statusObserver?(.extracting(turn: turn))

            let result: AITurnResult
            do {
                result = try await connector.completeTurn(
                    messages: transcript,
                    tools: [Self.delegateToolDefinition],
                    model: configuration.audioModel,
                    toolChoice: .auto,
                    stage: .execution,
                    configuration: turnConfig,
                    toolExecutor: nil
                )
            } catch {
                log("extraction turn \(turn) FAILED: \(error.localizedDescription)")
                throw error
            }

            log(
                "extraction turn \(turn) result — text: \(result.assistantText?.count ?? 0) chars, toolCalls: \(result.toolCalls.count), audio: \(result.audioOutput?.data?.count ?? 0) bytes, audioID: \(result.audioOutput?.id ?? "nil")"
            )
            if let text = result.assistantText, !text.isEmpty {
                log("  assistant text: \(text.prefix(200))")
            }
            for (i, tc) in result.toolCalls.enumerated() {
                log("  toolCall[\(i)]: \(tc.name)(id=\(tc.id), args=\(tc.argumentsJSON.prefix(200)))")
            }

            // Track ack audio metadata (the actual PCM was already streamed
            // chunk-by-chunk via streamingAudioHandler).
            if let audio = result.audioOutput, audio.data != nil {
                log(
                    "  ack audio ready: \(audio.data?.count ?? 0) bytes, transcript: \(audio.transcript?.prefix(80) ?? "nil")"
                )
                ackAudio = audio
                await statusObserver?(.ackAudioReady)
            }

            // Build assistant message for transcript continuation
            let assistantMsg: AIMessage
            if result.toolCalls.isEmpty {
                assistantMsg = .assistant(
                    result.assistantText,
                    audioReference: result.audioOutput?.id
                )
            } else {
                assistantMsg = .assistantToolCalls(
                    result.toolCalls,
                    text: result.assistantText,
                    audioReference: result.audioOutput?.id
                )
            }
            transcript.append(assistantMsg)

            // Check for the delegate tool call
            if let toolCall = result.toolCalls.first(where: { $0.name == Self.delegateToolName }) {
                if let delegation = parseDelegationToolCall(toolCall, contextID: contextID) {
                    log(
                        "  delegation parsed — transcript: \"\(delegation.transcript)\", intent: \"\(delegation.intent)\""
                    )
                    // Append tool result to close the conversation properly
                    transcript.append(
                        .tool(
                            "Intent received. Delegating to backend agent.",
                            toolCallID: toolCall.id
                        ))
                    return ExtractionResult(
                        request: delegation,
                        transcript: delegation.transcript,
                        intent: delegation.intent,
                        ackAudio: ackAudio
                    )
                } else {
                    log("  WARNING: delegate_to_agent tool call found but failed to parse arguments")
                }
            }

            if result.toolCalls.isEmpty && (result.assistantText != nil || result.audioOutput != nil) {
                log("turn \(turn): model handled utterance locally; no delegation")
                return ExtractionResult(
                    request: nil,
                    transcript: result.audioOutput?.transcript ?? "",
                    intent: result.assistantText ?? result.audioOutput?.transcript ?? "",
                    ackAudio: ackAudio ?? result.audioOutput
                )
            } else if result.toolCalls.isEmpty && result.assistantText == nil && result.audioOutput == nil {
                log("turn \(turn): empty result — model returned nothing")
            }
        }

        log("extraction exhausted all \(configuration.maxBridgeTurns) turns without getting delegate_to_agent")
        return nil
    }

    private func parseDelegationToolCall(_ toolCall: AIToolCall, contextID: UUID) -> DelegationRequest? {
        guard let data = toolCall.argumentsJSON.data(using: .utf8),
            let args = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let intent = args["intent"] as? String
        else {
            log("failed to parse delegate tool call arguments: \(toolCall.argumentsJSON)")
            return nil
        }
        return DelegationRequest(
            contextID: contextID,
            transcript: args["user_transcript"] as? String ?? "",
            intent: intent
        )
    }

    // MARK: - Rephrase for speech (Phase 3)

    private func rephraseForSpeech(
        intent: String,
        delegateResponse: String,
        connector: any AIConnector,
        audioOutputHandler: AudioOutputHandler? = nil
    ) async throws -> AITurnResult {
        log(
            "rephrase: intent=\"\(intent)\", response=\(delegateResponse.count) chars, model=\(configuration.audioModel)"
        )
        let messages: [AIMessage] = [
            .system(configuration.rephraseSystemPrompt),
            .user("The user asked: \(intent)\n\nAgent response:\n\(delegateResponse)"),
        ]

        let streamHandler: AIStreamingAudioHandler? = audioOutputHandler.map { handler in
            AIStreamingAudioHandler { chunk in
                await handler(AIAudioOutput(data: chunk))
            }
        }

        let turnConfig = AITurnConfiguration(
            modalities: ["text", "audio"],
            audioOutput: AIAudioOutputConfig(
                voice: configuration.voice,
                format: configuration.audioFormat
            ),
            streamingAudioHandler: streamHandler
        )

        let result = try await connector.completeTurn(
            messages: messages,
            tools: [],
            model: configuration.audioModel,
            toolChoice: nil,
            stage: .execution,
            configuration: turnConfig,
            toolExecutor: nil
        )
        log(
            "rephrase result: text=\(result.assistantText?.count ?? 0) chars, audio=\(result.audioOutput?.data?.count ?? 0) bytes, audioID=\(result.audioOutput?.id ?? "nil")"
        )
        return result
    }

    // MARK: - Deferral notice (Phase 3, when the turn suspended)

    /// Speak a short "it's underway, the result will appear in the conversation"
    /// notice when the backend turn suspended on an out-of-band step.
    private func speakDeferral(
        reason: String,
        connector: any AIConnector,
        audioOutputHandler: AudioOutputHandler? = nil
    ) async throws -> AITurnResult {
        let streamHandler: AIStreamingAudioHandler? = audioOutputHandler.map { handler in
            AIStreamingAudioHandler { chunk in
                await handler(AIAudioOutput(data: chunk))
            }
        }
        let turnConfig = AITurnConfiguration(
            modalities: ["text", "audio"],
            audioOutput: AIAudioOutputConfig(
                voice: configuration.voice,
                format: configuration.audioFormat
            ),
            streamingAudioHandler: streamHandler
        )
        return try await connector.completeTurn(
            messages: [
                .system(configuration.deferralSystemPrompt),
                .user("Context for the user: \(reason)"),
            ],
            tools: [],
            model: configuration.audioModel,
            toolChoice: nil,
            stage: .execution,
            configuration: turnConfig,
            toolExecutor: nil
        )
    }

    // MARK: - Standalone readout

    /// Speak an already-finished answer aloud, naturally. Used to read out the
    /// result of a previously-deferred turn if the user is still on the call
    /// when it resolves. Streams audio chunk-by-chunk via `audioOutputHandler`.
    ///
    /// - Parameters:
    ///   - text: The finished answer to speak. Sent as the user message under
    ///     the configured rephrase system prompt, so the model delivers it in
    ///     natural spoken form rather than verbatim.
    ///   - connector: The AI connector used for the audio-model turn.
    ///   - audioOutputHandler: Called with each streamed audio chunk as it
    ///     arrives. The turn's aggregate result is discarded, so this handler is
    ///     the only way to receive the audio.
    /// - Throws: Any error raised by the audio-model turn.
    public func speak(
        text: String,
        connector: any AIConnector,
        audioOutputHandler: @escaping AudioOutputHandler
    ) async throws {
        let streamHandler = AIStreamingAudioHandler { chunk in
            await audioOutputHandler(AIAudioOutput(data: chunk))
        }
        let turnConfig = AITurnConfiguration(
            modalities: ["text", "audio"],
            audioOutput: AIAudioOutputConfig(
                voice: configuration.voice,
                format: configuration.audioFormat
            ),
            streamingAudioHandler: streamHandler
        )
        _ = try await connector.completeTurn(
            messages: [
                .system(configuration.rephraseSystemPrompt),
                .user(text),
            ],
            tools: [],
            model: configuration.audioModel,
            toolChoice: nil,
            stage: .execution,
            configuration: turnConfig,
            toolExecutor: nil
        )
    }

    // MARK: - Delegation acknowledgement (Phase 2, concurrent)

    /// Speak a short, content-free acknowledgement while the delegate runs.
    /// Streams audio chunk-by-chunk through the same handler the ack/rephrase
    /// turns use. Failures are swallowed — a missing ack must never sink the
    /// bridge flow, and cancellation (delegate threw) is expected.
    private func speakDelegationAck(
        intent: String,
        connector: any AIConnector,
        audioOutputHandler: @escaping AudioOutputHandler
    ) async {
        let streamHandler = AIStreamingAudioHandler { chunk in
            await audioOutputHandler(AIAudioOutput(data: chunk))
        }
        // No maxOutputTokens cap: on an audio model that ceiling counts audio
        // tokens too, so a small value truncates the spoken ack mid-word — the
        // exact "only a few vowels" failure we're fixing. Brevity is steered by
        // the prompt instead, matching `rephraseForSpeech`.
        let turnConfig = AITurnConfiguration(
            modalities: ["text", "audio"],
            audioOutput: AIAudioOutputConfig(
                voice: configuration.voice,
                format: configuration.audioFormat
            ),
            streamingAudioHandler: streamHandler
        )
        log("phase 2: speaking delegation ack…")
        do {
            _ = try await connector.completeTurn(
                messages: [
                    .system(configuration.ackSystemPrompt),
                    .user("The user's request: \(intent)"),
                ],
                tools: [],
                model: configuration.audioModel,
                toolChoice: nil,
                stage: .execution,
                configuration: turnConfig,
                toolExecutor: nil
            )
            log("delegation ack spoken")
        } catch is CancellationError {
            log("delegation ack cancelled (delegate resolved/failed first)")
        } catch {
            log("delegation ack failed (non-fatal): \(error.localizedDescription)")
        }
    }

    // MARK: - Helpers

    private func log(_ message: String) {
        onLog?("[AudioBridge] \(message)")
    }
}

// MARK: - Errors

public enum AudioInterfaceAgentError: Error, LocalizedError {
    case intentExtractionFailed
    case delegateFailed(underlying: any Error)
    case audioModelFailed(underlying: any Error)

    public var errorDescription: String? {
        switch self {
            case .intentExtractionFailed:
                return "Audio bridge failed to extract user intent after maximum turns."
            case .delegateFailed(let e):
                return "Main agent delegation failed: \(e.localizedDescription)"
            case .audioModelFailed(let e):
                return "Audio model call failed: \(e.localizedDescription)"
        }
    }
}
