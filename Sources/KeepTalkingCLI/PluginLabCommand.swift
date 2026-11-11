import Foundation
import KeepTalkingSDK
import MCP

/// Attaches to the KT Companion as one identity: lists the Catalogue, drives a
/// call end to end, or accepts plugin proposals. A second lab with its own
/// `--node` is a second identity online.
///
///     KeepTalking pluginlab [--socket <path>] [--node <uuid>] [--label <name>]
///                           [--call <kind>] [--args <json>] [--scope <json>]
///                           [--wait <secs>] [--catalogue] [--accept-proposals] [--stay]
enum PluginLabCommand {
    private struct Args {
        var socketPath = KeepTalkingCompanionLink.socketPath()
        var node = UUID.v7()
        var label = "pluginlab"
        var call: String?
        var callArguments: [String: Value] = [:]
        var instanceScope: Value?
        var waitSeconds: TimeInterval = 120
        var stay = false
        var showCatalogue = false
        var acceptProposals = false
    }

    static func shouldHandle(_ args: [String]) -> Bool {
        args.first == "pluginlab"
    }

    static func run(_ args: [String]) async {
        do {
            try await run(parse(args))
            Foundation.exit(0)
        } catch {
            stderr("error: \(error.localizedDescription)")
            stderr(
                "usage: KeepTalking pluginlab [--socket <path>] [--node <uuid>] [--label <name>] [--call <kind>] [--args <json>] [--scope <json>] [--wait <secs>] [--catalogue] [--accept-proposals] [--stay]"
            )
            Foundation.exit(1)
        }
    }

    private static func run(_ args: Args) async throws {
        let link = KeepTalkingCompanionLink(socketPath: args.socketPath)
        await link.setEventHandler { event in
            switch event {
                case .attached: print("[pluginlab] attached socket=\(args.socketPath)")
                case .detached: print("[pluginlab] detached")
                case .catalogChanged: print("[pluginlab] catalog changed")
                case .log(let message): print("[pluginlab] \(message)")
            }
        }
        if args.acceptProposals {
            await link.setActionProposalHandler(
                { proposal in
                    print("[pluginlab] proposal from \(proposal.catalogName): \(proposal.kindName) — approved")
                    return UUID.v7()
                }, forNode: args.node)
        }
        await link.attach(node: args.node, label: args.label)
        await link.start()
        print("[pluginlab] node=\(args.node.uuidString.lowercased()) label=\(args.label)")

        if args.showCatalogue {
            try await Task.sleep(for: .seconds(3))
            for kind in await link.catalogue.availableKinds() {
                print("- \(kind.displayName) [\(kind.kindName)] from \(kind.catalogName)")
            }
        }

        if let kindName = args.call {
            let deadline = Date.now.addingTimeInterval(args.waitSeconds)
            var kind = await link.catalogue.availableKinds().first { $0.kindName == kindName }
            while kind == nil, Date.now < deadline {
                try await Task.sleep(for: .milliseconds(500))
                kind = await link.catalogue.availableKinds().first { $0.kindName == kindName }
            }
            guard let kind else { throw LabError("no connected plugin provides '\(kindName)'") }
            let outcome = try await link.callKind(
                catalogID: kind.catalogID, kindName: kindName, arguments: args.callArguments,
                instanceID: UUID.v7(), instanceScope: args.instanceScope, node: args.node)
            print("=== result (isError=\(outcome.isError)) ===")
            print(compactJSON(outcome.content))
            for entry in outcome.usage { print("\(entry.meter) = \(entry.units)") }
            print("attestation: \(outcome.record.verdict)")
            if !args.stay {
                await link.stop()
                return
            }
        }

        print("[pluginlab] attached — Ctrl-C to exit")
        while true { try await Task.sleep(for: .seconds(3600)) }
    }

    private static func compactJSON(_ value: Value) -> String {
        (try? JSONEncoder().encode(value)).flatMap { String(data: $0, encoding: .utf8) } ?? "\(value)"
    }

    private static func parse(_ args: [String]) throws -> Args {
        var parsed = Args()
        var iterator = args.makeIterator()
        func value(_ flag: String) throws -> String {
            guard let value = iterator.next() else { throw LabError("\(flag) requires a value") }
            return value
        }
        func json(_ flag: String) throws -> Value {
            try JSONDecoder().decode(Value.self, from: Data(try value(flag).utf8))
        }
        while let flag = iterator.next() {
            switch flag {
                case "--socket": parsed.socketPath = try value(flag)
                case "--node":
                    guard let node = UUID(uuidString: try value(flag)) else { throw LabError("--node needs a UUID") }
                    parsed.node = node
                case "--label": parsed.label = try value(flag)
                case "--call": parsed.call = try value(flag)
                case "--args":
                    guard case .object(let fields) = try json(flag) else { throw LabError("--args must be an object") }
                    parsed.callArguments = fields
                case "--scope": parsed.instanceScope = try json(flag)
                case "--wait": parsed.waitSeconds = TimeInterval(try value(flag)) ?? 120
                case "--stay": parsed.stay = true
                case "--catalogue": parsed.showCatalogue = true
                case "--accept-proposals": parsed.acceptProposals = true
                default: throw LabError("unknown flag \(flag)")
            }
        }
        return parsed
    }

    private struct LabError: LocalizedError {
        let errorDescription: String?
        init(_ message: String) { errorDescription = message }
    }

    private static func stderr(_ message: String) {
        FileHandle.standardError.write(Data((message + "\n").utf8))
    }
}
