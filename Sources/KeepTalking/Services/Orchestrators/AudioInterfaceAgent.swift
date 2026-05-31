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

public struct AudioInterfaceAgent {

    public struct Configuration: Sendable {
        public let audioModel: String
        public let voice: String
        public let audioFormat: String
        public let maxBridgeTurns: Int
        public let bridgeSystemPrompt: String
        public let rephraseSystemPrompt: String

        public init(
            audioModel: String,
            voice: String = "alloy",
            audioFormat: String = "pcm16",
            maxBridgeTurns: Int = 3,
            bridgeSystemPrompt: String? = nil,
            rephraseSystemPrompt: String? = nil
        ) {
            self.audioModel = audioModel
            self.voice = voice
            self.audioFormat = audioFormat
            self.maxBridgeTurns = maxBridgeTurns
            self.bridgeSystemPrompt = bridgeSystemPrompt ?? Self.defaultBridgeSystemPrompt
            self.rephraseSystemPrompt = rephraseSystemPrompt ?? Self.defaultRephraseSystemPrompt
        }

        static let defaultBridgeSystemPrompt = """
            You are a voice interface bridge. You have two jobs:
            1. Acknowledge the user's request with brief spoken audio.
            2. Call the `delegate_to_agent` tool with the extracted intent.
            You may do these in one turn or across two turns. \
            The audio acknowledgment is for the user to hear. \
            The tool call is for a backend agent to process.
            """

        static let defaultRephraseSystemPrompt = """
            You are a voice interface. The user asked something and a backend \
            agent produced the answer below. Rephrase it naturally for spoken \
            delivery — concise and conversational. Respond with audio.
            """
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

    /// Called to delegate the extracted intent to the main text agent.
    /// Returns the agent's text response.
    public typealias Delegate = @Sendable (DelegationRequest) async throws -> String

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
    ///   - connector: The AI connector to use for both audio model and main agent calls.
    ///   - delegate: Callback that forwards the extracted intent to the main agent.
    ///   - audioOutputHandler: Called when audio output is produced (for real-time playback).
    ///   - statusObserver: Called with status updates during the flow.
    public func run(
        audioData: Data,
        inputFormat: String,
        contextID: UUID,
        connector: any AIConnector,
        delegate: @escaping Delegate,
        audioOutputHandler: AudioOutputHandler? = nil,
        statusObserver: StatusObserver? = nil
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
                statusObserver: statusObserver
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

        log("phase 1 done — transcript: \"\(extraction.request.transcript)\", intent: \"\(extraction.request.intent)\"")
        await statusObserver?(.intentExtracted(extraction.request))

        // Phase 2: Delegate to main agent
        log("phase 2: delegating to main agent…")
        await statusObserver?(.delegating)
        let delegateResponse: String
        do {
            delegateResponse = try await delegate(extraction.request)
        } catch {
            log("phase 2 FAILED (delegate threw): \(error.localizedDescription)")
            throw error
        }
        log(
            "phase 2 done — delegate response (\(delegateResponse.count) chars): \(String(delegateResponse.prefix(300)))"
        )

        // Phase 3: Rephrase for speech
        log("phase 3: rephrasing for speech…")
        await statusObserver?(.rephrasing)
        let rephraseResult: AITurnResult
        do {
            rephraseResult = try await rephraseForSpeech(
                intent: extraction.request.intent,
                delegateResponse: delegateResponse,
                connector: connector
            )
        } catch {
            log("phase 3 FAILED: \(error.localizedDescription)")
            throw error
        }
        log(
            "phase 3 done — audioOutput: \(rephraseResult.audioOutput?.data?.count ?? 0) bytes, text: \(rephraseResult.assistantText?.prefix(100) ?? "nil")"
        )

        if let audio = rephraseResult.audioOutput {
            log("delivering rephrase audio to handler (\(audio.data?.count ?? 0) bytes)")
            await audioOutputHandler?(audio)
        } else {
            log("WARNING: no audio output from rephrase turn")
        }

        await statusObserver?(.done)
        log("bridge flow complete")

        return BridgeResult(
            contextID: contextID,
            transcript: extraction.request.transcript,
            intent: extraction.request.intent,
            delegateResponse: delegateResponse,
            audioOutput: rephraseResult.audioOutput,
            ackAudioOutput: extraction.ackAudio
        )
    }

    // MARK: - Intent extraction (Phase 1)

    private struct ExtractionResult {
        let request: DelegationRequest
        let ackAudio: AIAudioOutput?
    }

    private func extractIntent(
        audioData: Data,
        inputFormat: String,
        contextID: UUID,
        connector: any AIConnector,
        audioOutputHandler: AudioOutputHandler?,
        statusObserver: StatusObserver?
    ) async throws -> ExtractionResult? {
        var transcript: [AIMessage] = [
            .system(configuration.bridgeSystemPrompt),
            .user(parts: [.inputAudio(data: audioData, format: inputFormat)]),
        ]

        let turnConfig = AITurnConfiguration(
            modalities: ["text", "audio"],
            audioOutput: AIAudioOutputConfig(
                voice: configuration.voice,
                format: configuration.audioFormat
            )
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

            // Surface ack audio to the user immediately
            if let audio = result.audioOutput, audio.data != nil {
                log(
                    "  ack audio ready: \(audio.data?.count ?? 0) bytes, transcript: \(audio.transcript?.prefix(80) ?? "nil")"
                )
                ackAudio = audio
                await audioOutputHandler?(audio)
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
                    return ExtractionResult(request: delegation, ackAudio: ackAudio)
                } else {
                    log("  WARNING: delegate_to_agent tool call found but failed to parse arguments")
                }
            }

            // Model didn't call the tool — nudge it
            if result.toolCalls.isEmpty && (result.assistantText != nil || result.audioOutput != nil) {
                log("turn \(turn): model responded but didn't call delegate_to_agent — nudging")
                transcript.append(
                    .user(
                        "Now please call the delegate_to_agent tool with the extracted intent from the audio."
                    ))
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
        connector: any AIConnector
    ) async throws -> AITurnResult {
        log(
            "rephrase: intent=\"\(intent)\", response=\(delegateResponse.count) chars, model=\(configuration.audioModel)"
        )
        let messages: [AIMessage] = [
            .system(configuration.rephraseSystemPrompt),
            .user("The user asked: \(intent)\n\nAgent response:\n\(delegateResponse)"),
        ]

        let turnConfig = AITurnConfiguration(
            modalities: ["text", "audio"],
            audioOutput: AIAudioOutputConfig(
                voice: configuration.voice,
                format: configuration.audioFormat
            )
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
