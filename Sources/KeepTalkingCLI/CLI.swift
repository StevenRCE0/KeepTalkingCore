import Foundation
import KeepTalkingSDK

let keepTalkingUsage = """
Usage:
  KeepTalking [--signal-url <ws-url>] [--session <sid>] [--id <uid>] [--user-id <user-id>] [--channel <label>] [--message <text>]

Environment fallbacks:
  KT_SIGNAL_URL (default: ws://127.0.0.1:17000/ws)
  KT_SESSION    (default: ion)
  KT_ID         (default: random UUID)
  KT_USER_ID    (optional, for KV node registry)
  KT_CHANNEL    (default: keep-talking.chat)

Examples:
  KeepTalking --session room1 --id alice
  KeepTalking --id bob --message "hello from ion-sfu"

Interactive commands:
  /peer <id>   set default target peer
  /peer all    clear target (broadcast)
  /peer        show current target
  /stats       print local send/receive counters
  /quit        exit
"""

enum CliError: LocalizedError {
    case unknownFlag(String)
    case missingValue(String)
    case invalidSignalURL(String)

    var errorDescription: String? {
        switch self {
        case let .unknownFlag(flag):
            return "Unknown flag: \(flag)"
        case let .missingValue(flag):
            return "Missing value for \(flag)"
        case let .invalidSignalURL(raw):
            return "Invalid signal URL: \(raw)"
        }
    }
}

struct CliConfig {
    let sdkConfig: KeepTalkingConfig
    let singleMessage: String?

    static func parse() throws -> CliConfig {
        let env = ProcessInfo.processInfo.environment
        var signalURLRaw = env["KT_SIGNAL_URL"] ?? "ws://127.0.0.1:17000/ws"
        var session = env["KT_SESSION"] ?? "ion"
        var participantID = env["KT_ID"] ?? UUID().uuidString.lowercased()
        var userID = env["KT_USER_ID"]
        var channel = env["KT_CHANNEL"] ?? "keep-talking.chat"
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
            case "--id":
                index += 1
                guard index < args.count else { throw CliError.missingValue(arg) }
                participantID = args[index]
            case "--user-id":
                index += 1
                guard index < args.count else { throw CliError.missingValue(arg) }
                userID = args[index]
            case "--channel":
                index += 1
                guard index < args.count else { throw CliError.missingValue(arg) }
                channel = args[index]
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

        return CliConfig(
            sdkConfig: KeepTalkingConfig(
                signalURL: signalURL,
                session: session,
                participantID: participantID,
                channel: channel,
                userID: userID
            ),
            singleMessage: singleMessage
        )
    }
}
