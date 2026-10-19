import Foundation

/// How one turn's transcript is built, in the order
/// `withOrchestrationTranscript` applies it: what the first pass carries,
/// how stored history is cut into chunks, and which model calls the build
/// may make. Sizes are shares of the main model's input window
/// (`AIModelProfile.inputTokenBudget`), so an 8k on-device model and a
/// million-token one each get their own.
///
/// ```
/// legacy        system prompt (date, side notes, thread map) · decay-selected history · user_n
///
/// orchestrated  tools                                   ── durable
///               system (stable)                         ── durable
///               index: older threads, by name           ── durable
///               live thread, verbatim                   ── rolling
///               ── uncached from here ──
///               user_n
///               turn context: date, side notes, thread map,
///                             consult findings, cited rows, revealed threads
/// ```
///
/// Stored threads are never summarised: the newest chunks of them are read
/// verbatim by consultants before each reply, and the rest are listed by
/// name for `kt_search_threads`.
///
/// A run given no strategy builds `.legacy`.
public struct KeepTalkingOrchestrationStrategy: Sendable, Equatable {
    public enum Layout: Sendable, Equatable {
        /// Decay-selected history under one system prompt that carries
        /// everything that changes.
        case legacy
        /// The live thread verbatim under a stable, breakpointed prefix;
        /// stored threads through consults and search.
        case orchestrated
    }

    public var layout: Layout

    // MARK: 1. First pass

    /// Threads earlier `kt_search_threads` calls revealed, carried again
    /// (newest first), so a follow-up question finds them in view.
    public var revealedThreadsKept: Int

    // MARK: 2. Chunking

    /// What `kt_search_threads` returns word for word, in all; past it a
    /// result is too long and consultants read it instead.
    public var verbatimWindowShare: Double
    /// One consult's history chunk: the sweet spot for careful reading.
    public var chunkWindowShare: Double
    /// Ceiling on the stored-thread rows the turn context carries (consult
    /// citations, revealed threads): a cost cap for large windows.
    public var presentedTranscriptTokenCap: Int
    /// Held back for the reply and its tool rounds.
    public var outputReserveTokens: Int

    // MARK: 3. Fan-out

    /// Consult stored history before the reply.
    public var consultsStoredThreads: Bool
    /// How many of the newest chunks those consults read. Threads in older
    /// chunks are listed in the index by name only.
    public var consultWindowChunks: Int
    /// Consult search results too long to return verbatim.
    public var consultsLongSearchResults: Bool
    /// Most chunks one search consults.
    public var maximumSearchChunks: Int
    /// Live rows a turn's consult sees, so it can tell what the message refers to.
    public var consultLiveTailRows: Int
    public var consultEffort: AIReasoning.Effort
    public var consultMaxOutputTokens: Int

    // MARK: 4. Stitching

    /// Whether a single consult claiming the message (it resumes a stored
    /// thread) marks a turning point there. Off by default: measured, claims
    /// churned the threading; the reply is told and decides.
    public var claimsMarkTurningPoints: Bool

    public init(
        layout: Layout,
        revealedThreadsKept: Int = 5,
        verbatimWindowShare: Double = 0.2,
        chunkWindowShare: Double = 0.4,
        presentedTranscriptTokenCap: Int = 6_000,
        outputReserveTokens: Int = 8_192,
        consultsStoredThreads: Bool = true,
        consultWindowChunks: Int = 2,
        consultsLongSearchResults: Bool = true,
        maximumSearchChunks: Int = 4,
        consultLiveTailRows: Int = 8,
        consultEffort: AIReasoning.Effort = .low,
        consultMaxOutputTokens: Int = 1_200,
        claimsMarkTurningPoints: Bool = false
    ) {
        self.layout = layout
        self.revealedThreadsKept = revealedThreadsKept
        self.verbatimWindowShare = verbatimWindowShare
        self.chunkWindowShare = chunkWindowShare
        self.presentedTranscriptTokenCap = presentedTranscriptTokenCap
        self.outputReserveTokens = outputReserveTokens
        self.consultsStoredThreads = consultsStoredThreads
        self.consultWindowChunks = consultWindowChunks
        self.consultsLongSearchResults = consultsLongSearchResults
        self.maximumSearchChunks = maximumSearchChunks
        self.consultLiveTailRows = consultLiveTailRows
        self.consultEffort = consultEffort
        self.consultMaxOutputTokens = consultMaxOutputTokens
        self.claimsMarkTurningPoints = claimsMarkTurningPoints
    }

    /// Today's product layout.
    public static let legacy = KeepTalkingOrchestrationStrategy(layout: .legacy)
    /// The live thread verbatim, consults before the reply, older threads by name.
    public static let orchestrated = KeepTalkingOrchestrationStrategy(layout: .orchestrated)

    // MARK: - Sizes for a model

    /// Window assumed when the model's profile doesn't give one: sized so a
    /// chunk comes out at 32k, the size measured to read reliably.
    static let fallbackWindowTokens = 80_000

    static func tokens(share: Double, of profile: AIModelProfile?) -> Int {
        let window = profile?.inputTokenBudget ?? fallbackWindowTokens
        return max(1_000, Int(Double(window) * share))
    }

    func verbatimTokens(for profile: AIModelProfile?) -> Int { Self.tokens(share: verbatimWindowShare, of: profile) }
    func chunkTokens(for profile: AIModelProfile?) -> Int { Self.tokens(share: chunkWindowShare, of: profile) }
    /// What one search's consultants read, in all.
    func searchConsultTokens(for profile: AIModelProfile?) -> Int { maximumSearchChunks * chunkTokens(for: profile) }
    /// Revealed threads and consult citations share this in the turn context.
    func presentedTokens(for profile: AIModelProfile?) -> Int {
        min(verbatimTokens(for: profile), presentedTranscriptTokenCap)
    }
    func consultEffort(for profile: AIModelProfile?) -> AIReasoning.Effort? {
        profile.map { $0.resolvedEffort(consultEffort) } ?? consultEffort
    }
}
