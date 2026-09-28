import Foundation

// MARK: - AIModelProfile

/// What one model can do, as far as the agent loop cares: whether it takes
/// tools and attachments, how much it can read and write, and which reasoning
/// efforts it accepts.
///
/// Profiles come from `KeepTalkingModelCatalog` (models.dev) and reach the
/// client through `KeepTalkingClient.setModelProfileResolver(_:)`. A model
/// with no profile runs exactly as it did before profiles existed — every
/// field here narrows behaviour, none of them widens it.
public struct AIModelProfile: Sendable, Hashable, Codable {
    public enum InputModality: String, Sendable, Hashable, Codable, CaseIterable {
        case text
        case image
        case pdf
        case audio
        case video
    }

    /// How the model's reasoning can be steered.
    public enum Reasoning: Sendable, Hashable, Codable {
        /// The model never reasons; no effort is sent.
        case unsupported
        /// Reasoning is always on and exposes no knob.
        case alwaysOn
        /// Reasoning can be switched on or off, with no graded effort.
        case toggle
        /// Reasoning is steered by a thinking-token budget. Connectors map
        /// the KT effort onto a budget (see `AnthropicConnector`).
        case budget
        /// Graded effort; the model accepts exactly these values.
        case efforts([AIReasoning.Effort])
    }

    public var supportsToolCalling: Bool
    /// Whether the model accepts files and images as input at all.
    public var supportsAttachments: Bool
    /// Input modalities the model reads natively. Empty means unknown.
    public var inputModalities: Set<InputModality>
    /// Total context window in tokens (input + output), when known.
    public var contextWindow: Int?
    /// Separate input ceiling for models whose window is split
    /// (e.g. 400k context with 272k input).
    public var maxInputTokens: Int?
    public var maxOutputTokens: Int?
    public var reasoning: Reasoning

    public init(
        supportsToolCalling: Bool = true,
        supportsAttachments: Bool = true,
        inputModalities: Set<InputModality> = [],
        contextWindow: Int? = nil,
        maxInputTokens: Int? = nil,
        maxOutputTokens: Int? = nil,
        reasoning: Reasoning = .efforts(AIReasoning.Effort.allCases)
    ) {
        self.supportsToolCalling = supportsToolCalling
        self.supportsAttachments = supportsAttachments
        self.inputModalities = inputModalities
        self.contextWindow = contextWindow
        self.maxInputTokens = maxInputTokens
        self.maxOutputTokens = maxOutputTokens
        self.reasoning = reasoning
    }
}

// MARK: - Attachments

extension AIModelProfile {
    /// Whether image parts can be sent. A model that takes attachments but
    /// lists its modalities without `image` (a PDF-only model) cannot.
    public var acceptsImages: Bool {
        supportsAttachments && (inputModalities.isEmpty || inputModalities.contains(.image))
    }
}

// MARK: - Reasoning

extension AIModelProfile {
    public var supportsReasoning: Bool {
        if case .unsupported = reasoning { return false }
        return true
    }

    /// Efforts a user can pick for this model, in `AIReasoning.Effort.allCases`
    /// order. Empty when there is nothing to choose — the model either never
    /// reasons or always does on its own terms.
    ///
    /// A toggle is offered as off/on, with `.medium` standing in for "on";
    /// OpenRouter and the direct APIs all read a mid effort as "reason".
    public var selectableEfforts: [AIReasoning.Effort] {
        switch reasoning {
            case .unsupported, .alwaysOn:
                return []
            case .toggle:
                return [.noReasoning, .medium]
            case .budget:
                return [.noReasoning, .low, .medium, .high, .xhigh]
            case .efforts(let efforts):
                return AIReasoning.Effort.allCases.filter(efforts.contains)
        }
    }

    /// Whether this model reads efforts as a plain on/off switch.
    public var reasoningIsToggle: Bool {
        if case .toggle = reasoning { return true }
        return false
    }

    /// Snaps a requested effort onto one this model accepts.
    ///
    /// `nil` stays `nil` (provider default). A model that can't be steered
    /// gets `nil` whatever was asked. An effort the model doesn't list moves
    /// to the nearest one it does; asking to switch reasoning off on a model
    /// that can't falls back to the provider default rather than to some
    /// other level the user never picked.
    public func resolvedEffort(_ requested: AIReasoning.Effort?) -> AIReasoning.Effort? {
        guard let requested else { return nil }
        let selectable = selectableEfforts
        guard !selectable.isEmpty else { return nil }
        if selectable.contains(requested) { return requested }
        if requested == .noReasoning { return nil }
        let levels = selectable.filter { $0 != .noReasoning }
        guard let requestedRank = requested.rank else { return nil }
        return levels.min { lhs, rhs in
            abs((lhs.rank ?? 0) - requestedRank) < abs((rhs.rank ?? 0) - requestedRank)
        }
    }
}

extension AIReasoning.Effort: CaseIterable {
    public static let allCases: [AIReasoning.Effort] = [
        .noReasoning, .minimal, .low, .medium, .high, .xhigh,
    ]

    /// Ordinal of a graded effort; `nil` for `.noReasoning`.
    fileprivate var rank: Int? {
        switch self {
            case .noReasoning: return nil
            case .minimal: return 0
            case .low: return 1
            case .medium: return 2
            case .high: return 3
            case .xhigh: return 4
        }
    }
}

// MARK: - Context budget

extension AIModelProfile {
    /// Tokens the prompt side of a request may use: the model's input ceiling,
    /// or its window minus room for the reply (a quarter of the window, capped
    /// at the model's own output limit). `nil` when the window is unknown.
    public var inputTokenBudget: Int? {
        if let maxInputTokens, maxInputTokens > 0 {
            if let contextWindow, contextWindow > 0 {
                return min(maxInputTokens, contextWindow - outputReserve(contextWindow))
            }
            return maxInputTokens
        }
        guard let contextWindow, contextWindow > 0 else { return nil }
        return contextWindow - outputReserve(contextWindow)
    }

    private func outputReserve(_ contextWindow: Int) -> Int {
        let quarter = contextWindow / 4
        guard let maxOutputTokens, maxOutputTokens > 0 else { return quarter }
        return min(quarter, maxOutputTokens)
    }
}

// MARK: - Token estimate

extension AIMessage {
    /// Rough token count, erring high. UTF-8 bytes / 4 tracks English at about
    /// four characters a token and lands near one token per CJK character
    /// (three bytes each), which is where real tokenizers sit for both. Images
    /// and audio are charged a flat rate — the exact cost depends on the
    /// provider's own resizing and is never cheaper than this by much.
    public var approximateTokenCount: Int {
        var total = 4
        switch content {
            case .text(let text):
                total += Self.approximateTokens(text)
            case .parts(let parts):
                for part in parts {
                    switch part {
                        case .text(let text): total += Self.approximateTokens(text)
                        case .imageURL: total += 1_000
                        case .inputAudio: total += 1_000
                    }
                }
            case nil:
                break
        }
        for call in toolCalls {
            total += Self.approximateTokens(call.name) + Self.approximateTokens(call.argumentsJSON)
        }
        return total
    }

    static func approximateTokens(_ text: String) -> Int {
        (text.utf8.count + 3) / 4
    }

    /// This message with every image part replaced by `placeholder`, for a
    /// model that cannot read images. Other content passes through untouched.
    public func replacingImageParts(with placeholder: String) -> AIMessage {
        guard case .parts(let parts) = content,
            parts.contains(where: { if case .imageURL = $0 { return true } else { return false } })
        else { return self }
        let replaced: [Part] = parts.map { part in
            if case .imageURL = part { return .text(placeholder) }
            return part
        }
        return AIMessage(
            role: role,
            content: .parts(replaced),
            toolCalls: toolCalls,
            toolCallID: toolCallID,
            name: name,
            audioReference: audioReference
        )
    }
}

extension Array where Element == AIMessage {
    /// Keeps the newest messages whose combined estimate fits `tokenBudget`,
    /// dropping from the oldest end. Returns the kept suffix and how many
    /// messages fell off.
    func trimmedToTokenBudget(_ tokenBudget: Int) -> (messages: [AIMessage], droppedCount: Int) {
        var remaining = tokenBudget
        var keptFrom = count
        for index in indices.reversed() {
            let cost = self[index].approximateTokenCount
            guard cost <= remaining else { break }
            remaining -= cost
            keptFrom = index
        }
        return (Array(self[keptFrom...]), keptFrom)
    }
}
