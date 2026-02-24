import Foundation
import KeepTalkingSDK

let keepTalkingUsage = """
Usage:
  KeepTalking [--signal-url <ws-url>] [--node <uuid>] [--context <uuid>] [--db-path <sqlite-file>] [--message <text>] [--p2p-peer <peer-id>] [--p2p-timeout <seconds>] [--stun-url <stun-url>]

Environment fallbacks:
  KT_SIGNAL_URL (default: ws://127.0.0.1:17000/ws)
  KT_NODE       (default: random UUID)
  KT_CONTEXT    (default: 00000000-0000-0000-0000-000000000000)
  KT_DB_PATH    (optional, local sqlite file path)
  KT_P2P_PEER_ID    (optional, preferred remote peer ID)
  KT_P2P_TIMEOUT    (default: 5)
  KT_STUN_URL       (default: stun:stun.l.google.com:19302)

Examples:
  KeepTalking --context 11111111-2222-3333-4444-555555555555 --node 2B2F4C53-13E7-4A0A-A1FB-FA460279EEA9
  KeepTalking --node 2B2F4C53-13E7-4A0A-A1FB-FA460279EEA9 --message "hello from ion-sfu"

Interactive commands:
  /new         create and join a new context
  /join <id>   join an existing context
  /trust <id>  mark a node as trusted
  /stats       print local send/receive counters
  /p2p         manually start a p2p upgrade trial
  /quit        exit
"""

enum CliError: LocalizedError {
    case unknownFlag(String)
    case missingValue(String)
    case invalidSignalURL(String)
    case invalidDBPath(String)
    case invalidNodeID(String)
    case invalidContextID(String)
    case invalidP2PTimeout(String)

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
        case let .invalidContextID(raw):
            return "Invalid context UUID: \(raw)"
        case let .invalidP2PTimeout(raw):
            return "Invalid p2p timeout: \(raw)"
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
        var nodeIDRaw = env["KT_NODE"] ?? UUID().uuidString
        var contextIDRaw = env["KT_CONTEXT"]
            ?? "00000000-0000-0000-0000-000000000000"
        var databasePathRaw = env["KT_DB_PATH"]
        var p2pPeerID = env["KT_P2P_PEER_ID"]
        var p2pTimeoutRaw = env["KT_P2P_TIMEOUT"] ?? "5"
        var stunURLs = [env["KT_STUN_URL"] ?? "stun:stun.l.google.com:19302"]
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
            case "--p2p-peer":
                index += 1
                guard index < args.count else { throw CliError.missingValue(arg) }
                p2pPeerID = args[index]
            case "--p2p-timeout":
                index += 1
                guard index < args.count else { throw CliError.missingValue(arg) }
                p2pTimeoutRaw = args[index]
            case "--stun-url":
                index += 1
                guard index < args.count else { throw CliError.missingValue(arg) }
                stunURLs.append(args[index])
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
        guard let p2pTimeout = TimeInterval(p2pTimeoutRaw), p2pTimeout > 0 else {
            throw CliError.invalidP2PTimeout(p2pTimeoutRaw)
        }
        guard let nodeID = UUID(uuidString: nodeIDRaw) else {
            throw CliError.invalidNodeID(nodeIDRaw)
        }
        guard let contextID = UUID(uuidString: contextIDRaw) else {
            throw CliError.invalidContextID(contextIDRaw)
        }
        let databaseURL = try resolveDatabaseURL(databasePathRaw)
        stunURLs = Array(Set(stunURLs.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })).sorted()

        return CliConfig(
            sdkConfig: KeepTalkingConfig(
                signalURL: signalURL,
                contextID: contextID,
                node: nodeID,
                p2pPreferredRemoteID: p2pPeerID,
                p2pAttemptTimeoutSeconds: p2pTimeout,
                p2pStunServers: stunURLs
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
