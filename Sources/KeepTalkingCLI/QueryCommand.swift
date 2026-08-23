import FluentKit
import Foundation
import KeepTalkingSDK

enum QueryCommand {

    static func shouldHandle(_ args: [String]) -> Bool {
        guard let first = args.first else { return false }
        return first == "context" || first == "message"
    }

    static func run(_ args: [String]) async {
        do {
            let config = try parseArgs(args)
            try await execute(config)
        } catch {
            FileHandle.standardError.write(
                Data("Error: \(error.localizedDescription)\n".utf8)
            )
            Foundation.exit(1)
        }
    }

    // MARK: - Types

    private enum OutputFormat: String, Sendable {
        case table
        case json
    }

    private struct Config: Sendable {
        let resource: String
        let format: OutputFormat
        let limit: Int
        let databaseURL: URL?
        let contextID: UUID?
    }

    // MARK: - Parsing

    private static func parseArgs(_ args: [String]) throws -> Config {
        guard args.count >= 2 else { throw QueryError.usage }
        let resource = args[0]
        let action = args[1]
        guard action == "list" else { throw QueryError.unknownAction(action) }

        let env = ProcessInfo.processInfo.environment
        var format: OutputFormat = .table
        var limit = 50
        var databaseURL: URL?
        var contextID: UUID?

        var i = 2
        while i < args.count {
            switch args[i] {
                case "--format":
                    i += 1
                    guard i < args.count else {
                        throw QueryError.missingValue("--format")
                    }
                    guard let f = OutputFormat(rawValue: args[i]) else {
                        throw QueryError.invalidFormat(args[i])
                    }
                    format = f
                case "--limit":
                    i += 1
                    guard i < args.count else {
                        throw QueryError.missingValue("--limit")
                    }
                    guard let n = Int(args[i]), n > 0 else {
                        throw QueryError.invalidLimit(args[i])
                    }
                    limit = n
                case "--db-path":
                    i += 1
                    guard i < args.count else {
                        throw QueryError.missingValue("--db-path")
                    }
                    databaseURL = resolveDatabasePath(args[i])
                case "--context":
                    i += 1
                    guard i < args.count else {
                        throw QueryError.missingValue("--context")
                    }
                    guard let id = UUID(uuidString: args[i]) else {
                        throw QueryError.invalidContextID(args[i])
                    }
                    contextID = id
                default:
                    throw QueryError.unknownFlag(args[i])
            }
            i += 1
        }

        if databaseURL == nil,
            let envPath = env["KT_DB_PATH"],
            !envPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            databaseURL = resolveDatabasePath(envPath)
        }

        return Config(
            resource: resource,
            format: format,
            limit: limit,
            databaseURL: databaseURL,
            contextID: contextID
        )
    }

    // MARK: - Execution

    private static func execute(_ config: Config) async throws {
        let store: any KeepTalkingLocalStore
        if let url = config.databaseURL {
            store = try await KeepTalkingModelStore.make(databaseURL: url)
        } else {
            store = try await KeepTalkingClient.makeDefaultLocalStore()
        }

        switch config.resource {
            case "context":
                try await listContexts(on: store.database, config: config)
            case "message":
                try await listMessages(on: store.database, config: config)
            default:
                throw QueryError.unknownResource(config.resource)
        }
    }

    // MARK: - Context List

    private static func listContexts(
        on db: any Database, config: Config
    ) async throws {
        let rows = try await KeepTalkingContext.query(on: db)
            .sort(\.$updatedAt, .descending)
            .range(..<config.limit)
            .all()

        switch config.format {
            case .table:
                guard !rows.isEmpty else {
                    print("No contexts found.")
                    return
                }
                let df = makeDateFormatter()
                print(
                    "\(pad("ID", to: 36))  Updated"
                )
                print(
                    "\(String(repeating: "─", count: 36))  "
                        + String(repeating: "─", count: 19)
                )
                for ctx in rows {
                    let id = ctx.id?.uuidString.lowercased() ?? "—"
                    print(
                        "\(pad(id, to: 36))  \(df.string(from: ctx.updatedAt))"
                    )
                }
                print("\n\(rows.count) context(s)")

            case .json:
                let iso = ISO8601DateFormatter()
                let out = rows.map { ctx in
                    ContextOutput(
                        id: ctx.id?.uuidString.lowercased() ?? "",
                        updatedAt: iso.string(from: ctx.updatedAt)
                    )
                }
                printJSON(out)
        }
    }

    // MARK: - Message List

    private static func listMessages(
        on db: any Database, config: Config
    ) async throws {
        var query = KeepTalkingContextMessage.query(on: db)
        if let cid = config.contextID {
            query = query.filter(\.$context.$id, .equal, cid)
        }
        let rows =
            try await query
            .sort(\.$timestamp, .descending)
            .range(..<config.limit)
            .all()

        let showContext = config.contextID == nil

        switch config.format {
            case .table:
                guard !rows.isEmpty else {
                    print("No messages found.")
                    return
                }
                let df = makeDateFormatter()
                if showContext {
                    print(
                        "\(pad("Timestamp", to: 19))  "
                            + "\(pad("Context", to: 8))  "
                            + "\(pad("Sender", to: 16))  "
                            + "\(pad("Type", to: 14))  "
                            + "Content"
                    )
                    print(String(repeating: "─", count: 110))
                } else {
                    print(
                        "\(pad("Timestamp", to: 19))  "
                            + "\(pad("Sender", to: 16))  "
                            + "\(pad("Type", to: 14))  "
                            + "Content"
                    )
                    print(String(repeating: "─", count: 100))
                }
                for msg in rows {
                    let ts = df.string(from: msg.timestamp)
                    let sender = senderLabel(msg.sender)
                    let type = typeLabel(msg.type)
                    let content = truncate(msg.content, to: 50)
                    if showContext {
                        let ctx = String(
                            msg.$context.id.uuidString.prefix(8)
                        ).lowercased()
                        print(
                            "\(pad(ts, to: 19))  "
                                + "\(pad(ctx, to: 8))  "
                                + "\(pad(sender, to: 16))  "
                                + "\(pad(type, to: 14))  "
                                + content
                        )
                    } else {
                        print(
                            "\(pad(ts, to: 19))  "
                                + "\(pad(sender, to: 16))  "
                                + "\(pad(type, to: 14))  "
                                + content
                        )
                    }
                }
                print("\n\(rows.count) message(s)")

            case .json:
                let iso = ISO8601DateFormatter()
                let out = rows.map { msg in
                    MessageOutput(
                        id: msg.id?.uuidString.lowercased() ?? "",
                        contextID: msg.$context.id.uuidString.lowercased(),
                        timestamp: iso.string(from: msg.timestamp),
                        sender: encodeSender(msg.sender),
                        type: typeLabel(msg.type),
                        content: msg.content
                    )
                }
                printJSON(out)
        }
    }

    // MARK: - JSON Output DTOs

    private struct ContextOutput: Encodable {
        let id: String
        let updatedAt: String
    }

    private struct MessageOutput: Encodable {
        let id: String
        let contextID: String
        let timestamp: String
        let sender: SenderOutput
        let type: String
        let content: String
    }

    private struct SenderOutput: Encodable {
        let type: String
        let nodeID: String?
        let name: String?
        let model: String?
    }

    // MARK: - Helpers

    private static func senderLabel(
        _ sender: KeepTalkingContextMessage.Sender
    ) -> String {
        switch sender {
            case .node(let node):
                return String(node.uuidString.prefix(8)).lowercased()
            case .autonomous(let name, _, _):
                return name
        }
    }

    private static func encodeSender(
        _ sender: KeepTalkingContextMessage.Sender
    ) -> SenderOutput {
        switch sender {
            case .node(let node):
                return SenderOutput(
                    type: "node",
                    nodeID: node.uuidString.lowercased(),
                    name: nil,
                    model: nil
                )
            case .autonomous(let name, let node, let model):
                return SenderOutput(
                    type: "autonomous",
                    nodeID: node?.uuidString.lowercased(),
                    name: name,
                    model: model
                )
        }
    }

    private static func typeLabel(
        _ type: KeepTalkingContextMessage.MessageType
    ) -> String {
        switch type {
            case .message: return "message"
            case .thinking: return "thinking"
            case .intermediate: return "intermediate"
            case .markTurningPoint: return "mark"
            case .markChitterChatter: return "chitter"
            case .agentTurnContinuation: return "continuation"
            case .transcript: return "transcript"
            case .haywire: return "haywire"
            case .voiceCallSeal: return "voice-seal"
        }
    }

    private static func pad(_ string: String, to width: Int) -> String {
        if string.count >= width { return String(string.prefix(width)) }
        return string + String(repeating: " ", count: width - string.count)
    }

    private static func truncate(_ string: String, to maxLength: Int) -> String {
        let flat = string.replacingOccurrences(of: "\n", with: "\\n")
        if flat.count <= maxLength { return flat }
        return String(flat.prefix(maxLength - 1)) + "…"
    }

    private static func makeDateFormatter() -> DateFormatter {
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return df
    }

    private static func printJSON<T: Encodable>(_ value: T) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(value),
            let json = String(data: data, encoding: .utf8)
        else { return }
        print(json)
    }

    private static func resolveDatabasePath(_ raw: String) -> URL? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.hasPrefix("file://") {
            return URL(string: trimmed)
        }
        return URL(
            fileURLWithPath: NSString(string: trimmed).expandingTildeInPath
        )
    }
}

// MARK: - Errors

private enum QueryError: LocalizedError {
    case usage
    case unknownAction(String)
    case unknownResource(String)
    case unknownFlag(String)
    case missingValue(String)
    case invalidFormat(String)
    case invalidLimit(String)
    case invalidContextID(String)

    var errorDescription: String? {
        switch self {
            case .usage:
                return
                    "Usage: keeptalking <context|message> list [--format table|json] [--limit N] [--db-path PATH] [--context UUID]"
            case .unknownAction(let s):
                return "Unknown action '\(s)'. Supported: list"
            case .unknownResource(let s):
                return "Unknown resource '\(s)'. Supported: context, message"
            case .unknownFlag(let s):
                return "Unknown flag: \(s)"
            case .missingValue(let s):
                return "Missing value for \(s)"
            case .invalidFormat(let s):
                return "Invalid format '\(s)'. Supported: table, json"
            case .invalidLimit(let s):
                return "Invalid limit '\(s)'. Must be a positive integer."
            case .invalidContextID(let s):
                return "Invalid context UUID: \(s)"
        }
    }
}
