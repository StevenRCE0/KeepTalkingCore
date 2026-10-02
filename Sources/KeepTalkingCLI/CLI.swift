import Foundation
import KeepTalkingSDK

let keepTalkingUsage = """
    Usage:
      KeepTalking [--relay <url>] [--sfu-id <hex>] [--node <uuid>] [--context <uuid>] [--db-path <sqlite-file>] [--message <text>] [--openai-endpoint <url>] [--openai-api-key <key>] [--model <id>] [--act-model <id>] [--mcp <list|remove|add-http|add-stdio> ...] [--skill <list|remove|add-directory> ...]

    Environment fallbacks:
      KT_RELAY      (iroh relay URL; without it the CLI has no transport and stays local)
      KT_SFU_ID     (optional SFU endpoint id; default: looked up at <relay>/kt/sfu)
      KT_NODE       (default: random UUID)
      KT_CONTEXT    (default: 00000000-0000-0000-0000-000000000000)
      KT_DB_PATH    (optional, local sqlite file path)
      OPENAI_API_KEY    (optional, enables /ai)
      KT_OPENAI_ENDPOINT / OPENAI_ENDPOINT / OPENAI_BASE_URL (optional, OpenAI-compatible API endpoint)
      KT_MODEL          (node-wide main agent model, required for /ai)
      KT_ACT_MODEL      (node-wide ACT agent model, default: the main model)

    Examples:
      KeepTalking --relay https://signal.example/ --context 11111111-2222-3333-4444-555555555555
      KeepTalking --context 11111111-2222-3333-4444-555555555555 --node 2B2F4C53-13E7-4A0A-A1FB-FA460279EEA9
      KeepTalking --node 2B2F4C53-13E7-4A0A-A1FB-FA460279EEA9 --message "hello"
      KeepTalking --mcp add-http linear https://mcp.linear.app --header Authorization=Bearer_token
      KeepTalking --mcp add-stdio foo --env OPENAI_API_KEY=sk-... --env MODEL=gpt-4.1 -- npx -y @modelcontextprotocol/server-github
      KeepTalking --skill add-directory doc-summarizer ~/.codex/skills/doc-summarizer "Local documentation summarizer"
    Interactive commands:
      /new         create and join a new context
      /join <id>   join an existing context (prompts for encryption key)
      /trust <id> [all|context|<context-uuid>]
                   mark a node as trusted (all contexts or scoped context)
      /lure <node-id> <pubkey>
                   add a node->pubkey trust record for this node
      /actions list
                   list known actions and current grants
      /actions grant <node-id> <action-id> [context|all]
                   grant action permission to a trusted/owned node
      /mcp add-http <name> <url> [--header KEY=VALUE ...] [description]
                   register a local MCP HTTP action
      /mcp add-stdio <name> [--env KEY=VALUE ...] -- <command> [args...]
                   register a local MCP stdio action
      /mcp list    list registered MCP actions
      /mcp remove <action-id>
                   remove a local MCP action
      /skill add directory <name> <path> [description]
                   register a local skill action from a directory containing SKILL.md
      /skill list  list registered skill actions
      /skill remove <action-id>
                   remove a local skill action
      /ai <prompt> run AI tool planning and execution in active context
      /model [act] [<id>|reset]
                   show the active context's models, or override one for this
                   context (session only); reset returns to the node-wide model
      /stats       print this context's transport counters
      /quit        exit
    """

enum MCPManagementCommand {
    case list
    case remove(actionID: UUID)
    case addHTTP(
        name: String,
        url: URL,
        description: String?,
        headers: [String: String]
    )
    case addSTDIO(
        name: String,
        command: [String],
        environment: [String: String]
    )
}

enum SkillManagementCommand {
    case list
    case remove(actionID: UUID)
    case addDirectory(name: String, directory: URL, description: String?)
}

enum CliError: LocalizedError {
    case unknownFlag(String)
    case missingValue(String)
    case invalidSignalURL(String)
    case invalidDBPath(String)
    case invalidNodeID(String)
    case invalidContextID(String)
    case invalidMCPCommand(String)
    case invalidMCPURL(String)
    case invalidActionID(String)
    case invalidMCPEnvironment(String)
    case invalidMCPHeader(String)
    case invalidOpenAIEndpoint(String)
    case invalidSkillCommand(String)
    case invalidSkillDirectory(String)
    case conflictingManagementCommands

    var errorDescription: String? {
        switch self {
            case .unknownFlag(let flag):
                return "Unknown flag: \(flag)"
            case .missingValue(let flag):
                return "Missing value for \(flag)"
            case .invalidSignalURL(let raw):
                return "Invalid signal URL: \(raw)"
            case .invalidDBPath(let raw):
                return "Invalid db path: \(raw)"
            case .invalidNodeID(let raw):
                return "Invalid node UUID: \(raw)"
            case .invalidContextID(let raw):
                return "Invalid context UUID: \(raw)"
            case .invalidMCPCommand(let raw):
                return "Invalid --mcp command: \(raw)"
            case .invalidMCPURL(let raw):
                return "Invalid MCP URL: \(raw)"
            case .invalidActionID(let raw):
                return "Invalid action UUID: \(raw)"
            case .invalidMCPEnvironment(let raw):
                return "Invalid MCP env assignment: \(raw). Expected KEY=VALUE."
            case .invalidMCPHeader(let raw):
                return "Invalid MCP header assignment: \(raw). Expected KEY=VALUE."
            case .invalidOpenAIEndpoint(let raw):
                return "Invalid OpenAI endpoint URL: \(raw)"
            case .invalidSkillCommand(let raw):
                return "Invalid --skill command: \(raw)"
            case .invalidSkillDirectory(let raw):
                return "Invalid skill directory: \(raw)"
            case .conflictingManagementCommands:
                return "Specify at most one management command: --mcp or --skill."
        }
    }
}

struct CliConfig {
    let sdkConfig: KeepTalkingConfig
    let databaseURL: URL?
    let singleMessage: String?
    let openAIAPIKey: String?
    let openAIEndpoint: String?
    /// Node-wide main agent model (`--model` / `KT_MODEL`).
    let model: String?
    /// Node-wide ACT agent model (`--act-model` / `KT_ACT_MODEL`); `nil`
    /// means the main model.
    let actModel: String?
    let mcpCommand: MCPManagementCommand?
    let skillCommand: SkillManagementCommand?
    /// `--relay <url>` — the iroh relay the process-wide transport uses. Nil
    /// leaves the CLI without a transport: local commands only.
    let relayURL: String?
    /// `--sfu-id <hex>` — the SFU's endpoint id; nil looks it up at the relay.
    let sfuEndpointID: String?

    static func parse() throws -> CliConfig {
        let env = ProcessInfo.processInfo.environment
        var nodeIDRaw = env["KT_NODE"] ?? UUID().uuidString
        var contextIDRaw =
            env["KT_CONTEXT"]
            ?? "00000000-0000-0000-0000-000000000000"
        var databasePathRaw = env["KT_DB_PATH"]
        var openAIAPIKey = env["OPENAI_API_KEY"]
        var openAIEndpointRaw =
            env["KT_OPENAI_ENDPOINT"]
            ?? env["OPENAI_ENDPOINT"]
            ?? env["OPENAI_BASE_URL"]
        var model = env["KT_MODEL"]
        var actModel = env["KT_ACT_MODEL"]
        var singleMessage: String?
        var mcpCommand: MCPManagementCommand?
        var skillCommand: SkillManagementCommand?
        var relayURL = env["KT_RELAY"]
        var sfuEndpointID = env["KT_SFU_ID"]

        let args = Array(CommandLine.arguments.dropFirst())
        var index = 0
        while index < args.count {
            let arg = args[index]
            switch arg {
                case "--help", "-h":
                    print(keepTalkingUsage)
                    Foundation.exit(0)
                case "--relay":
                    index += 1
                    guard index < args.count else { throw CliError.missingValue(arg) }
                    relayURL = args[index]
                case "--sfu-id":
                    index += 1
                    guard index < args.count else { throw CliError.missingValue(arg) }
                    sfuEndpointID = args[index]
                case "--node", "--id":
                    index += 1
                    guard index < args.count else { throw CliError.missingValue(arg) }
                    nodeIDRaw = args[index]
                case "--context":
                    index += 1
                    guard index < args.count else { throw CliError.missingValue(arg) }
                    contextIDRaw = args[index]
                case "--db-path":
                    index += 1
                    guard index < args.count else { throw CliError.missingValue(arg) }
                    databasePathRaw = args[index]
                case "--message":
                    index += 1
                    guard index < args.count else { throw CliError.missingValue(arg) }
                    singleMessage = args[index]
                case "--openai-api-key":
                    index += 1
                    guard index < args.count else { throw CliError.missingValue(arg) }
                    openAIAPIKey = args[index]
                case "--openai-endpoint":
                    index += 1
                    guard index < args.count else { throw CliError.missingValue(arg) }
                    openAIEndpointRaw = args[index]
                case "--model":
                    index += 1
                    guard index < args.count else { throw CliError.missingValue(arg) }
                    model = args[index]
                case "--act-model":
                    index += 1
                    guard index < args.count else { throw CliError.missingValue(arg) }
                    actModel = args[index]
                case "--mcp":
                    index += 1
                    guard index < args.count else { throw CliError.missingValue(arg) }
                    let command = args[index]
                    switch command {
                        case "list":
                            mcpCommand = .list
                        case "remove":
                            index += 1
                            guard index < args.count else { throw CliError.missingValue("--mcp remove") }
                            guard let actionID = UUID(uuidString: args[index]) else {
                                throw CliError.invalidActionID(args[index])
                            }
                            mcpCommand = .remove(actionID: actionID)
                        case "add-http":
                            index += 1
                            guard index < args.count else { throw CliError.missingValue("--mcp add-http <name>") }
                            let name = args[index]
                            index += 1
                            guard index < args.count else { throw CliError.missingValue("--mcp add-http <url>") }
                            let urlRaw = args[index]
                            guard let url = URL(string: urlRaw) else {
                                throw CliError.invalidMCPURL(urlRaw)
                            }
                            var headers: [String: String] = [:]
                            var descriptionParts: [String] = []
                            while index + 1 < args.count {
                                let nextToken = args[index + 1]
                                if nextToken == "--header" {
                                    index += 2
                                    guard index < args.count else {
                                        throw CliError.missingValue(
                                            "--header KEY=VALUE"
                                        )
                                    }
                                    let parsed = try parseHTTPHeader(
                                        args[index]
                                    )
                                    headers[parsed.key] = parsed.value
                                    continue
                                }
                                if nextToken.hasPrefix("--") {
                                    break
                                }
                                index += 1
                                descriptionParts.append(args[index])
                            }
                            let description =
                                descriptionParts.isEmpty
                                ? nil
                                : descriptionParts.joined(separator: " ")
                            mcpCommand = .addHTTP(
                                name: name,
                                url: url,
                                description: description,
                                headers: headers
                            )
                        case "add-stdio":
                            index += 1
                            guard index < args.count else { throw CliError.missingValue("--mcp add-stdio <name>") }
                            let name = args[index]
                            let specStart = index + 1
                            let specParts =
                                specStart < args.count
                                ? Array(args[specStart...])
                                : []
                            let parsed = try parseStdioSpec(specParts)
                            let commandParts = parsed.command
                            guard !commandParts.isEmpty else {
                                throw CliError.missingValue(
                                    "--mcp add-stdio <name> [--env KEY=VALUE ...] -- <command> [args...]"
                                )
                            }
                            mcpCommand = .addSTDIO(
                                name: name,
                                command: commandParts,
                                environment: parsed.environment
                            )
                            index = args.count - 1
                        default:
                            throw CliError.invalidMCPCommand(command)
                    }
                case "--skill":
                    index += 1
                    guard index < args.count else { throw CliError.missingValue(arg) }
                    let command = args[index]
                    switch command {
                        case "list":
                            skillCommand = .list
                        case "remove":
                            index += 1
                            guard index < args.count else { throw CliError.missingValue("--skill remove") }
                            guard let actionID = UUID(uuidString: args[index]) else {
                                throw CliError.invalidActionID(args[index])
                            }
                            skillCommand = .remove(actionID: actionID)
                        case "add-directory", "add-dir":
                            index += 1
                            guard index < args.count else {
                                throw CliError.missingValue("--skill add-directory <name>")
                            }
                            let name = args[index]
                            index += 1
                            guard index < args.count else {
                                throw CliError.missingValue("--skill add-directory <path>")
                            }
                            let directory = try resolveSkillDirectoryURL(args[index])
                            var descriptionParts: [String] = []
                            while index + 1 < args.count, !args[index + 1].hasPrefix("--") {
                                index += 1
                                descriptionParts.append(args[index])
                            }
                            let description =
                                descriptionParts.isEmpty
                                ? nil
                                : descriptionParts.joined(separator: " ")
                            skillCommand = .addDirectory(
                                name: name,
                                directory: directory,
                                description: description
                            )
                        default:
                            throw CliError.invalidSkillCommand(command)
                    }
                default:
                    throw CliError.unknownFlag(arg)
            }
            index += 1
        }

        if mcpCommand != nil, skillCommand != nil {
            throw CliError.conflictingManagementCommands
        }

        guard let nodeID = UUID(uuidString: nodeIDRaw) else {
            throw CliError.invalidNodeID(nodeIDRaw)
        }
        guard let contextID = UUID(uuidString: contextIDRaw) else {
            throw CliError.invalidContextID(contextIDRaw)
        }
        let databaseURL = try resolveDatabaseURL(databasePathRaw)
        let openAIEndpoint = try normalizeOpenAIEndpoint(openAIEndpointRaw)
        let normalizedOpenAIAPIKey =
            openAIAPIKey?.trimmingCharacters(in: .whitespacesAndNewlines)

        return CliConfig(
            sdkConfig: KeepTalkingConfig(contextID: contextID, node: nodeID),
            databaseURL: databaseURL,
            singleMessage: singleMessage,
            openAIAPIKey: (normalizedOpenAIAPIKey?.isEmpty == false)
                ? normalizedOpenAIAPIKey
                : nil,
            openAIEndpoint: openAIEndpoint,
            model: model?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty,
            actModel: actModel?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty,
            mcpCommand: mcpCommand,
            skillCommand: skillCommand,
            relayURL: relayURL?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty,
            sfuEndpointID: sfuEndpointID?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        )
    }

    private static func resolveDatabaseURL(_ raw: String?) throws -> URL? {
        guard let raw, !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        if raw.hasPrefix("file://") {
            guard let url = URL(string: raw), url.isFileURL else {
                throw CliError.invalidDBPath(raw)
            }
            return url
        }
        let expanded = NSString(string: raw).expandingTildeInPath
        return URL(fileURLWithPath: expanded)
    }

    private static func resolveSkillDirectoryURL(_ raw: String) throws -> URL {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw CliError.invalidSkillDirectory(raw)
        }

        let resolved: URL
        if trimmed.hasPrefix("file://") {
            guard let parsed = URL(string: trimmed), parsed.isFileURL else {
                throw CliError.invalidSkillDirectory(raw)
            }
            resolved = parsed
        } else {
            let expanded = NSString(string: trimmed).expandingTildeInPath
            resolved = URL(fileURLWithPath: expanded)
        }

        var isDirectory: ObjCBool = false
        guard
            FileManager.default.fileExists(
                atPath: resolved.path,
                isDirectory: &isDirectory
            ),
            isDirectory.boolValue
        else {
            throw CliError.invalidSkillDirectory(raw)
        }

        return resolved
    }

    private static func parseStdioSpec(
        _ tokens: [String]
    ) throws -> (command: [String], environment: [String: String]) {
        guard !tokens.isEmpty else {
            return ([], [:])
        }

        var environment: [String: String] = [:]
        var command: [String] = []
        var index = 0
        var parsingEnv = true

        while index < tokens.count {
            let token = tokens[index]
            if token == "--" {
                parsingEnv = false
                index += 1
                continue
            }

            if parsingEnv && token == "--env" {
                index += 1
                guard index < tokens.count else {
                    throw CliError.missingValue("--env KEY=VALUE")
                }
                let assignment = tokens[index]
                guard let eq = assignment.firstIndex(of: "="), eq != assignment.startIndex else {
                    throw CliError.invalidMCPEnvironment(assignment)
                }
                let key = String(assignment[..<eq])
                let value = String(assignment[assignment.index(after: eq)...])
                environment[key] = value
            } else {
                parsingEnv = false
                command.append(token)
            }
            index += 1
        }

        return (command, environment)
    }

    private static func parseHTTPHeader(
        _ assignment: String
    ) throws -> (key: String, value: String) {
        guard let eq = assignment.firstIndex(of: "="),
            eq != assignment.startIndex
        else {
            throw CliError.invalidMCPHeader(assignment)
        }
        let key = String(assignment[..<eq]).trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard !key.isEmpty else {
            throw CliError.invalidMCPHeader(assignment)
        }
        let value = String(assignment[assignment.index(after: eq)...])
        return (key, value)
    }

    private static func normalizeOpenAIEndpoint(_ raw: String?) throws -> String? {
        guard
            let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
            !raw.isEmpty
        else {
            return nil
        }

        guard
            let components = URLComponents(string: raw),
            let scheme = components.scheme?.lowercased(),
            scheme == "http" || scheme == "https",
            let host = components.host,
            !host.isEmpty
        else {
            throw CliError.invalidOpenAIEndpoint(raw)
        }

        return raw
    }
}

extension String {
    fileprivate var nilIfEmpty: String? { isEmpty ? nil : self }
}
