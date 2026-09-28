import Foundation
import NIOConcurrencyHelpers

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// MARK: - KeepTalkingModelCatalog

/// A local, on-disk copy of the models.dev registry (https://models.dev, MIT),
/// indexed into `AIModelProfile`s.
///
/// models.dev lists what every provider's models can do — tool calling,
/// attachments, input modalities, context/output limits, and reasoning
/// options. The catalog downloads `api.json` on request, keeps the raw file at
/// `cacheURL`, and answers `profile(forModel:providerID:)` from memory.
///
/// Nothing here fetches on its own: the host decides when a refresh is worth a
/// network call (the app does it when the AI Providers settings open) and
/// calls `loadCached()` early so profiles are there before the first turn.
/// Until something is loaded every lookup returns `nil`, which the agent loop
/// reads as "no known limits".
public final class KeepTalkingModelCatalog: Sendable {
    public static let sourceURL = URL(string: "https://models.dev/api.json")!
    /// How old the cached file may get before `refresh()` fetches again.
    public static let defaultMaxAge: TimeInterval = 24 * 60 * 60

    /// Where the raw `api.json` lives between launches.
    public let cacheURL: URL
    private let sourceURL: URL
    private let session: URLSession

    private struct State {
        var index: Index?
        var fetchedAt: Date?
        var inFlightRefresh: Task<Bool, Error>?
    }
    private let state = NIOLockedValueBox(State())

    public init(
        cacheURL: URL,
        sourceURL: URL = KeepTalkingModelCatalog.sourceURL,
        session: URLSession = .shared
    ) {
        self.cacheURL = cacheURL
        self.sourceURL = sourceURL
        self.session = session
    }

    /// `<Application Support>/KeepTalking/ModelCatalog/models.dev.json` — a
    /// reasonable default for hosts that don't care where the file goes.
    public static func defaultCacheURL() -> URL {
        let base =
            FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return
            base
            .appendingPathComponent("KeepTalking", isDirectory: true)
            .appendingPathComponent("ModelCatalog", isDirectory: true)
            .appendingPathComponent("models.dev.json")
    }

    // MARK: Status

    /// When the loaded data was downloaded. `nil` before anything is loaded.
    public var fetchedAt: Date? {
        state.withLockedValue { $0.fetchedAt }
    }

    public var isLoaded: Bool {
        state.withLockedValue { $0.index != nil }
    }

    // MARK: Loading

    /// Loads the cached file into memory if nothing is loaded yet. Parsing the
    /// ~5 MB file runs off the caller's executor. Returns whether a catalog is
    /// loaded afterwards; a missing or unreadable cache is not an error.
    @discardableResult
    public func loadCached() async -> Bool {
        if isLoaded { return true }
        let cacheURL = self.cacheURL
        let loaded = await Task.detached(priority: .utility) { () -> (Index, Date)? in
            guard let data = try? Data(contentsOf: cacheURL),
                let index = try? Index(modelsDevJSON: data)
            else { return nil }
            let modified =
                (try? FileManager.default.attributesOfItem(atPath: cacheURL.path)[.modificationDate]
                    as? Date) ?? .distantPast
            return (index, modified)
        }.value
        guard let loaded else { return false }
        let (index, fetchedAt) = loaded
        state.withLockedValue { state in
            // A refresh that landed while we parsed is newer; keep it.
            guard state.index == nil else { return }
            state.index = index
            state.fetchedAt = fetchedAt
        }
        return true
    }

    /// Downloads a fresh copy when the cached one is older than `maxAge`
    /// (or missing), validates it, writes it to `cacheURL`, and swaps it in.
    /// Concurrent calls share one download. Returns whether new data was
    /// fetched; throws only when a needed fetch fails, leaving the previous
    /// catalog in place.
    @discardableResult
    public func refresh(maxAge: TimeInterval = KeepTalkingModelCatalog.defaultMaxAge) async throws -> Bool {
        await loadCached()
        let task: Task<Bool, Error> = state.withLockedValue { state in
            if let inFlight = state.inFlightRefresh { return inFlight }
            if let fetchedAt = state.fetchedAt, state.index != nil,
                Date().timeIntervalSince(fetchedAt) < maxAge
            {
                return Task { false }
            }
            let task = Task { try await self.download() }
            state.inFlightRefresh = task
            return task
        }
        defer {
            state.withLockedValue { state in
                if state.inFlightRefresh == task { state.inFlightRefresh = nil }
            }
        }
        return try await task.value
    }

    private func download() async throws -> Bool {
        let (data, response) = try await session.data(from: sourceURL)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw URLError(.badServerResponse)
        }
        // Parse before touching the cache so a bad payload never replaces a
        // good file.
        let index = try Index(modelsDevJSON: data)
        let directory = cacheURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: cacheURL, options: .atomic)
        let now = Date()
        state.withLockedValue { state in
            state.index = index
            state.fetchedAt = now
        }
        return true
    }

    // MARK: Lookup

    /// The profile for `model` as served by `providerID` (a models.dev
    /// provider id such as `openrouter`, `openai`, `anthropic`).
    ///
    /// Tries, in order: the exact id under that provider; the id without an
    /// OpenRouter variant suffix (`:free`, `:thinking`); a `vendor/model` id
    /// under the vendor's own listing; then the id under any provider. The
    /// fallbacks cover custom OpenAI-compatible endpoints and ids typed in a
    /// slightly different namespace than the registry uses.
    public func profile(forModel model: String, providerID: String? = nil) -> AIModelProfile? {
        guard let index = state.withLockedValue({ $0.index }) else { return nil }
        return index.profile(forModel: model, providerID: providerID)
    }

    /// Model ids the catalog lists under `providerID`, sorted.
    public func modelIDs(providerID: String) -> [String] {
        guard let index = state.withLockedValue({ $0.index }) else { return [] }
        return index.byProvider[providerID.lowercased()].map { $0.keys.sorted() } ?? []
    }
}

// MARK: - Index

extension KeepTalkingModelCatalog {
    struct Index: Sendable {
        /// provider id → model id → profile. Keys are lowercased.
        let byProvider: [String: [String: AIModelProfile]]
        /// model id → profile, first hit across providers (well-known
        /// providers first, then alphabetical), for provider-agnostic lookups.
        let anyProvider: [String: AIModelProfile]

        static let preferredProviderOrder = ["openai", "anthropic", "openrouter", "google"]

        init(byProvider: [String: [String: AIModelProfile]]) {
            self.byProvider = byProvider
            let order =
                Self.preferredProviderOrder.filter { byProvider[$0] != nil }
                + byProvider.keys.sorted().filter { !Self.preferredProviderOrder.contains($0) }
            var any: [String: AIModelProfile] = [:]
            for providerID in order {
                for (modelID, profile) in byProvider[providerID] ?? [:] where any[modelID] == nil {
                    any[modelID] = profile
                }
            }
            self.anyProvider = any
        }

        init(modelsDevJSON data: Data) throws {
            let providers = try JSONDecoder().decode([String: Lossy<ModelsDev.Provider>].self, from: data)
            var byProvider: [String: [String: AIModelProfile]] = [:]
            for (providerID, provider) in providers {
                guard let models = provider.value?.models else { continue }
                var profiles: [String: AIModelProfile] = [:]
                for (modelID, model) in models {
                    guard let model = model.value else { continue }
                    profiles[modelID.lowercased()] = model.profile
                }
                if !profiles.isEmpty {
                    byProvider[providerID.lowercased()] = profiles
                }
            }
            guard !byProvider.isEmpty else {
                throw DecodingError.dataCorrupted(
                    .init(codingPath: [], debugDescription: "models.dev payload listed no models")
                )
            }
            self.init(byProvider: byProvider)
        }

        func profile(forModel model: String, providerID: String?) -> AIModelProfile? {
            let id = model.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !id.isEmpty else { return nil }
            let base = id.split(separator: ":", maxSplits: 1).first.map(String.init) ?? id
            let slash = base.firstIndex(of: "/")
            let vendor = slash.map { String(base[..<$0]) }
            let bare = slash.map { String(base[base.index(after: $0)...]) }

            if let providerID = providerID?.lowercased(), let models = byProvider[providerID] {
                if let hit = models[id] ?? models[base] { return hit }
            }
            if let vendor, let bare, let hit = byProvider[vendor]?[bare] { return hit }
            if let hit = anyProvider[id] ?? anyProvider[base] { return hit }
            if let bare, let hit = anyProvider[bare] { return hit }
            return nil
        }
    }
}

// MARK: - models.dev wire shape

/// Decodes one value, yielding `nil` instead of failing the whole payload —
/// a provider adding a field in a new shape must not blank the catalog.
struct Lossy<Value: Decodable>: Decodable {
    let value: Value?

    init(from decoder: any Decoder) throws {
        value = try? Value(from: decoder)
    }
}

enum ModelsDev {
    struct Provider: Decodable {
        let models: [String: Lossy<Model>]
    }

    struct Model: Decodable {
        struct Modalities: Decodable {
            let input: [String]?
        }
        struct Limit: Decodable {
            let context: Int?
            let input: Int?
            let output: Int?
        }
        struct ReasoningOption: Decodable {
            let type: String
            let values: [String]?
        }

        let attachment: Bool?
        let reasoning: Bool?
        let toolCall: Bool?
        let modalities: Modalities?
        let limit: Limit?
        let reasoningOptions: [Lossy<ReasoningOption>]?

        enum CodingKeys: String, CodingKey {
            case attachment
            case reasoning
            case toolCall = "tool_call"
            case modalities
            case limit
            case reasoningOptions = "reasoning_options"
        }

        var profile: AIModelProfile {
            AIModelProfile(
                supportsToolCalling: toolCall ?? true,
                supportsAttachments: attachment ?? true,
                inputModalities: Set(
                    (modalities?.input ?? []).compactMap { AIModelProfile.InputModality(rawValue: $0) }
                ),
                contextWindow: limit?.context.flatMap { $0 > 0 ? $0 : nil },
                maxInputTokens: limit?.input.flatMap { $0 > 0 ? $0 : nil },
                maxOutputTokens: limit?.output.flatMap { $0 > 0 ? $0 : nil },
                reasoning: reasoningProfile
            )
        }

        /// models.dev lists up to three knobs per model. Graded effort wins
        /// when present (a toggle beside it adds "off"); a budget comes next,
        /// a bare toggle last. `reasoning: true` with no knob is always-on.
        /// `max` has no KT effort and is left out of the menu.
        var reasoningProfile: AIModelProfile.Reasoning {
            guard reasoning == true else { return .unsupported }
            let options = (reasoningOptions ?? []).compactMap(\.value)
            let hasToggle = options.contains { $0.type == "toggle" }
            if let effort = options.first(where: { $0.type == "effort" }) {
                var efforts = (effort.values ?? []).compactMap(Self.effort(fromModelsDev:))
                if hasToggle, !efforts.contains(.noReasoning) {
                    efforts.insert(.noReasoning, at: 0)
                }
                if !efforts.isEmpty { return .efforts(efforts) }
            }
            if options.contains(where: { $0.type == "budget_tokens" }) { return .budget }
            if hasToggle { return .toggle }
            return .alwaysOn
        }

        static func effort(fromModelsDev raw: String) -> AIReasoning.Effort? {
            switch raw.lowercased() {
                case "none": return .noReasoning
                case "minimal": return .minimal
                case "low": return .low
                case "medium": return .medium
                case "high": return .high
                case "xhigh": return .xhigh
                default: return nil
            }
        }
    }
}
