import Foundation
import KeepTalkingSDK

/// A named provider + models the CLI runs agents with — the CLI's counterpart
/// of the app's `LLMProvider` row plus its role selection, kept in a JSON file
/// so a provider is set up once instead of re-typed as flags every run.
///
/// Keys are best kept out of the file: `apiKeyEnv` names the environment
/// variable that holds one (each kind has a default), and `apiKey` is only the
/// fallback for a machine where that's impractical.
struct CLIProviderProfile: Codable, Sendable, Equatable {
    enum Kind: String, Codable, Sendable, CaseIterable {
        case openrouter
        case openai
        case anthropic
        /// Any OpenAI-compatible Chat Completions server; needs `endpoint`.
        case custom

        var defaultKeyEnvironmentVariable: String {
            switch self {
                case .openrouter: return "OPENROUTER_API_KEY"
                case .openai, .custom: return "OPENAI_API_KEY"
                case .anthropic: return "ANTHROPIC_API_KEY"
            }
        }

        /// models.dev provider id for capability lookups; nil when unknown.
        var catalogProviderID: String? {
            switch self {
                case .openrouter: return "openrouter"
                case .openai: return "openai"
                case .anthropic: return "anthropic"
                case .custom: return nil
            }
        }
    }

    var name: String
    var kind: Kind
    var model: String
    var actModel: String?
    var endpoint: String?
    var apiKeyEnv: String?
    var apiKey: String?
    /// `AIReasoning.Effort` raw value (`minimal`, `low`, …).
    var effort: String?
    var languages: [String]?
    /// `--api-key` for this run: wins over everything, never saved.
    var overrideAPIKey: String?

    private enum CodingKeys: String, CodingKey {
        case name, kind, model, actModel, endpoint, apiKeyEnv, apiKey, effort, languages
    }

    /// The key this profile resolves to right now, and where it came from.
    func resolvedAPIKey(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> (key: String, source: String)? {
        if let overrideAPIKey, !overrideAPIKey.isEmpty { return (overrideAPIKey, "--api-key") }
        let variable = apiKeyEnv ?? kind.defaultKeyEnvironmentVariable
        if let value = environment[variable]?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty {
            return (value, "$\(variable)")
        }
        if let apiKey = apiKey?.trimmingCharacters(in: .whitespacesAndNewlines), !apiKey.isEmpty {
            return (apiKey, "profile file")
        }
        return nil
    }

    var reasoningEffort: AIReasoning.Effort? {
        effort.flatMap(AIReasoning.Effort.init(rawValue:))
    }

    /// The connector this profile describes.
    func makeConnector() throws -> any AIConnector {
        guard let key = resolvedAPIKey()?.key else {
            throw CLIProfileError.missingKey(
                profile: name,
                variable: apiKeyEnv ?? kind.defaultKeyEnvironmentVariable
            )
        }
        switch kind {
            case .openrouter:
                return try OpenAIConnector(apiKey: key, endpoint: endpoint, backend: .openRouter)
            case .openai:
                return try OpenAIConnector(apiKey: key, endpoint: endpoint, backend: .openAI)
            case .custom:
                guard let endpoint else { throw CLIProfileError.customNeedsEndpoint(profile: name) }
                return try OpenAIConnector(apiKey: key, endpoint: endpoint, backend: .custom(baseURL: endpoint))
            case .anthropic:
                return try AnthropicConnector(apiKey: key, endpoint: endpoint)
        }
    }

    /// One line for `profile list`, never the key itself.
    var summary: String {
        var parts = ["\(kind.rawValue)", "model=\(model)"]
        if let actModel { parts.append("act=\(actModel)") }
        if let effort { parts.append("effort=\(effort)") }
        if let endpoint { parts.append("endpoint=\(endpoint)") }
        if let languages, !languages.isEmpty { parts.append("languages=\(languages.joined(separator: ","))") }
        let keySource = resolvedAPIKey()?.source ?? "missing ($\(apiKeyEnv ?? kind.defaultKeyEnvironmentVariable))"
        parts.append("key=\(keySource)")
        return parts.joined(separator: "  ")
    }
}

enum CLIProfileError: LocalizedError {
    case missingKey(profile: String, variable: String)
    case customNeedsEndpoint(profile: String)
    case unknownProfile(String)
    case invalidKind(String)
    case invalidEffort(String)
    case usage(String)

    var errorDescription: String? {
        switch self {
            case .missingKey(let profile, let variable):
                return
                    "Profile '\(profile)' has no API key: set $\(variable) or store one with `profile add … --api-key`."
            case .customNeedsEndpoint(let profile):
                return "Profile '\(profile)' is kind 'custom' and needs --endpoint."
            case .unknownProfile(let name):
                return "No provider profile named '\(name)'. See `KeepTalking profile list`."
            case .invalidKind(let raw):
                return
                    "Unknown provider '\(raw)'. Expected one of: \(CLIProviderProfile.Kind.allCases.map(\.rawValue).joined(separator: ", "))."
            case .invalidEffort(let raw):
                return "Unknown effort '\(raw)'. Expected one of: noReasoning, minimal, low, medium, high, xhigh."
            case .usage(let text):
                return text
        }
    }
}

/// The profile file: `$KT_PROFILES`, else `~/.keeptalking/cli-profiles.json`.
struct CLIProviderProfileStore: Codable, Sendable {
    var defaultProfile: String?
    var profiles: [CLIProviderProfile]

    static var fileURL: URL {
        if let raw = ProcessInfo.processInfo.environment["KT_PROFILES"], !raw.isEmpty {
            return URL(fileURLWithPath: NSString(string: raw).expandingTildeInPath)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".keeptalking/cli-profiles.json")
    }

    static func load() throws -> CLIProviderProfileStore {
        let url = fileURL
        guard FileManager.default.fileExists(atPath: url.path) else {
            return CLIProviderProfileStore(defaultProfile: nil, profiles: [])
        }
        return try JSONDecoder().decode(CLIProviderProfileStore.self, from: Data(contentsOf: url))
    }

    /// Written owner-only: the file may hold a key.
    func save() throws {
        let url = Self.fileURL
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    func profile(named name: String) -> CLIProviderProfile? {
        profiles.first { $0.name == name }
    }

    /// `--profile`, else `$KT_PROFILE`, else the stored default.
    func selected(explicitName: String?) throws -> CLIProviderProfile? {
        let name = explicitName ?? ProcessInfo.processInfo.environment["KT_PROFILE"] ?? defaultProfile
        guard let name else { return nil }
        guard let profile = profile(named: name) else { throw CLIProfileError.unknownProfile(name) }
        return profile
    }
}

/// `KeepTalking profile …` — manage the profile file, and check one works.
enum ProfileCommand {
    static func shouldHandle(_ args: [String]) -> Bool {
        args.first == "profile" || args.first == "profiles"
    }

    static let usage = """
        Usage:
          KeepTalking profile list
          KeepTalking profile add <name> --provider <openrouter|openai|anthropic|custom> --model <id>
                                  [--act-model <id>] [--endpoint <url>] [--key-env <VAR> | --api-key <key>]
                                  [--effort <minimal|low|medium|high|…>] [--language <lang> ...]
                                  [--default]
          KeepTalking profile remove <name>
          KeepTalking profile default <name>
          KeepTalking profile test [<name>]     one tiny completion through the profile

        File: $KT_PROFILES or ~/.keeptalking/cli-profiles.json (written 0600).
        Select one per run with --profile <name> or $KT_PROFILE; flags (--model, --act-model,
        --effort, --api-key) override the selected profile's fields.
        """

    static func run(_ args: [String]) async {
        do {
            try await execute(Array(args.dropFirst()))
        } catch {
            FileHandle.standardError.write(Data("Error: \(error.localizedDescription)\n".utf8))
            Foundation.exit(1)
        }
    }

    private static func execute(_ args: [String]) async throws {
        guard let action = args.first else {
            print(usage)
            return
        }
        var store = try CLIProviderProfileStore.load()
        switch action {
            case "list":
                if store.profiles.isEmpty {
                    print(
                        "No profiles in \(CLIProviderProfileStore.fileURL.path). Add one with `KeepTalking profile add`."
                    )
                }
                for profile in store.profiles {
                    let marker = profile.name == store.defaultProfile ? "*" : " "
                    print("\(marker) \(profile.name)  \(profile.summary)")
                }
            case "add":
                let profile = try parseAdd(Array(args.dropFirst()))
                store.profiles.removeAll { $0.name == profile.profile.name }
                store.profiles.append(profile.profile)
                if profile.makeDefault || store.defaultProfile == nil {
                    store.defaultProfile = profile.profile.name
                }
                try store.save()
                print("Saved '\(profile.profile.name)': \(profile.profile.summary)")
            case "remove":
                guard args.count >= 2 else { throw CLIProfileError.usage(usage) }
                guard store.profile(named: args[1]) != nil else { throw CLIProfileError.unknownProfile(args[1]) }
                store.profiles.removeAll { $0.name == args[1] }
                if store.defaultProfile == args[1] { store.defaultProfile = store.profiles.first?.name }
                try store.save()
                print("Removed '\(args[1])'.")
            case "default":
                guard args.count >= 2 else { throw CLIProfileError.usage(usage) }
                guard store.profile(named: args[1]) != nil else { throw CLIProfileError.unknownProfile(args[1]) }
                store.defaultProfile = args[1]
                try store.save()
                print("Default profile: \(args[1])")
            case "test":
                let name = args.count >= 2 ? args[1] : nil
                guard let profile = try store.selected(explicitName: name) else {
                    throw CLIProfileError.usage("No profile selected and no default set.")
                }
                try await test(profile)
            default:
                throw CLIProfileError.usage(usage)
        }
    }

    private static func parseAdd(_ args: [String]) throws -> (profile: CLIProviderProfile, makeDefault: Bool) {
        guard let name = args.first, !name.hasPrefix("--") else { throw CLIProfileError.usage(usage) }
        var kind: CLIProviderProfile.Kind?
        var model: String?
        var actModel: String?
        var endpoint: String?
        var keyEnv: String?
        var apiKey: String?
        var effort: String?
        var languages: [String] = []
        var makeDefault = false

        var index = 1
        func value(_ flag: String) throws -> String {
            index += 1
            guard index < args.count else { throw CliError.missingValue(flag) }
            return args[index]
        }
        while index < args.count {
            let flag = args[index]
            switch flag {
                case "--provider", "--kind":
                    let raw = try value(flag)
                    guard let parsed = CLIProviderProfile.Kind(rawValue: raw) else {
                        throw CLIProfileError.invalidKind(raw)
                    }
                    kind = parsed
                case "--model": model = try value(flag)
                case "--act-model": actModel = try value(flag)
                case "--endpoint": endpoint = try value(flag)
                case "--key-env": keyEnv = try value(flag)
                case "--api-key": apiKey = try value(flag)
                case "--effort":
                    let raw = try value(flag)
                    guard AIReasoning.Effort(rawValue: raw) != nil else { throw CLIProfileError.invalidEffort(raw) }
                    effort = raw
                case "--language": languages.append(try value(flag))
                case "--default": makeDefault = true
                default: throw CliError.unknownFlag(flag)
            }
            index += 1
        }
        guard let kind, let model else {
            throw CLIProfileError.usage("profile add needs --provider and --model.\n\n\(usage)")
        }
        if kind == .custom, endpoint == nil { throw CLIProfileError.customNeedsEndpoint(profile: name) }
        return (
            CLIProviderProfile(
                name: name,
                kind: kind,
                model: model,
                actModel: actModel,
                endpoint: endpoint,
                apiKeyEnv: keyEnv,
                apiKey: apiKey,
                effort: effort,
                languages: languages.isEmpty ? nil : languages
            ),
            makeDefault
        )
    }

    /// One tool-less, few-token completion: proves key, endpoint and model.
    private static func test(_ profile: CLIProviderProfile) async throws {
        print("Testing '\(profile.name)': \(profile.summary)")
        let connector = try profile.makeConnector()
        let started = Date()
        let result = try await connector.completeTurn(
            messages: [.system("Reply with the single word OK."), .user("ping")],
            tools: [],
            model: profile.model,
            toolChoice: nil,
            stage: .execution,
            configuration: AITurnConfiguration(
                reasoning: profile.reasoningEffort.map { AIReasoning(effort: $0) },
                maxOutputTokens: 64
            ),
            toolExecutor: nil
        )
        let elapsed = Date().timeIntervalSince(started)
        print("Reply: \(result.assistantText ?? "<none>")  (\(String(format: "%.1f", elapsed)) s)")
        if let usage = result.usage { print("Usage: \(usage.logDescription)") }
    }
}
