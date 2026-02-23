import Foundation
import KeepTalkingSDK

let keepTalkingUsage = """
Usage:
  KeepTalking [--signal-url <ws-url>] [--session <sid>] [--node <uuid>] [--channel <label>] [--db-path <sqlite-file>] [--message <text>]

Environment fallbacks:
  KT_SIGNAL_URL (default: ws://127.0.0.1:17000/ws)
  KT_SESSION    (default: ion)
  KT_NODE       (default: random UUID)
  KT_CHANNEL    (default: keep-talking.chat)
  KT_DB_PATH    (optional, local sqlite file path)

Examples:
  KeepTalking --session room1 --node 2B2F4C53-13E7-4A0A-A1FB-FA460279EEA9
  KeepTalking --node 2B2F4C53-13E7-4A0A-A1FB-FA460279EEA9 --message "hello from ion-sfu"

Interactive commands:
  /stats       print local send/receive counters
  /quit        exit
"""

enum CliError: LocalizedError {
    case unknownFlag(String)
    case missingValue(String)
    case invalidSignalURL(String)
    case invalidDBPath(String)
    case invalidNodeID(String)

    var errorDescription: String? {
        switch self {
        case let .unknownFlag(flag):
            return "Unknown flag: \(flag)"
        case let .missingValue(flag):
            return "Missing value for \(flag)"
        case let .invalidSignalURL(raw):
            return "Invalid signal URL: \(raw)"
        case let .invalidDBPath(raw):
            return "Invalid db path: \(raw)"
        case let .invalidNodeID(raw):
            return "Invalid node UUID: \(raw)"
        }
    }
}

struct CliConfig {
    let sdkConfig: KeepTalkingConfig
    let databaseURL: URL?
    let singleMessage: String?

    static func parse() throws -> CliConfig {
        let env = ProcessInfo.processInfo.environment
        var signalURLRaw = env["KT_SIGNAL_URL"] ?? "ws://127.0.0.1:17000/ws"
        var session = env["KT_SESSION"] ?? "ion"
        var nodeIDRaw = env["KT_NODE"] ?? UUID().uuidString
        var channel = env["KT_CHANNEL"] ?? "keep-talking.chat"
        var databasePathRaw = env["KT_DB_PATH"]
        var singleMessage: String?

        let args = Array(CommandLine.arguments.dropFirst())
        var index = 0
        while index < args.count {
            let arg = args[index]
            switch arg {
            case "--help", "-h":
                print(keepTalkingUsage)
                Foundation.exit(0)
            case "--signal-url":
                index += 1
                guard index < args.count else { throw CliError.missingValue(arg) }
                signalURLRaw = args[index]
            case "--session":
                index += 1
                guard index < args.count else { throw CliError.missingValue(arg) }
                session = args[index]
            case "--node", "--id":
                index += 1
                guard index < args.count else { throw CliError.missingValue(arg) }
                nodeIDRaw = args[index]
            case "--channel":
                index += 1
                guard index < args.count else { throw CliError.missingValue(arg) }
                channel = args[index]
            case "--db-path":
                index += 1
                guard index < args.count else { throw CliError.missingValue(arg) }
                databasePathRaw = args[index]
            case "--message":
                index += 1
                guard index < args.count else { throw CliError.missingValue(arg) }
                singleMessage = args[index]
            default:
                throw CliError.unknownFlag(arg)
            }
            index += 1
        }

        guard let signalURL = URL(string: signalURLRaw) else {
            throw CliError.invalidSignalURL(signalURLRaw)
        }
        guard let nodeID = UUID(uuidString: nodeIDRaw) else {
            throw CliError.invalidNodeID(nodeIDRaw)
        }
        let databaseURL = try resolveDatabaseURL(databasePathRaw)

        return CliConfig(
            sdkConfig: KeepTalkingConfig(
                signalURL: signalURL,
                session: session,
                channel: channel,
                node: nodeID
            ),
            databaseURL: databaseURL,
            singleMessage: singleMessage
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
}
