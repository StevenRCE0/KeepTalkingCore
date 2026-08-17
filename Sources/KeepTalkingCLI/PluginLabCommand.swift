import Foundation
import KeepTalkingSDK
import MCP

/// KTPP lab host — the Phase-1 demo driver for plugin action catalogs.
///
/// Serves the plugin attach socket via `KeepTalkingPluginHost`, auto-approves
/// pairing (printing the identity fingerprint a real UI would show), lists the
/// kinds a companion registers, and can drive a call end to end — printing the
/// result, the plugin-signed usage receipt verdict, and a ledger verification.
///
///     KeepTalking pluginlab [--socket <path>] [--call <kind>] [--args <json>]
///                           [--scope <json>] [--wait <secs>] [--stay]
enum PluginLabCommand {
    private struct Args {
        /// Defaults to a node-derived path like the app's. In practice you
        /// pass `--socket` (or run the app, which owns the real one): the lab
        /// is a headless stand-in for the app host, not a second listener
        /// competing with it.
        var socketPath: String = KeepTalkingPluginHost.socketPath(forNode: UUID.v7())
        var node: UUID?
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
            usage()
            Foundation.exit(1)
        }
    }

    private static func run(_ args: Args) async throws {
        let hostNodeID = args.node ?? UUID.v7()
        let host = KeepTalkingPluginHost(hostNodeID: hostNodeID, socketPath: args.socketPath)

        await host.setEventHandler { event in
            switch event {
                case .listening(let socketPath):
                    print("[pluginlab] listening socket=\(socketPath)")
                    print("[pluginlab] discovery=\((socketPath as NSString).deletingLastPathComponent)/ktpp.json")
                case .paired(let catalogID, let info, let fingerprint, let endorsedBy):
                    print("[pluginlab] paired catalog=\(catalogID.uuidString.lowercased())")
                    print("            plugin=\(info.name) v\(info.version) by \(info.vendor)")
                    print("            fingerprint=\(fingerprint)")
                    if let endorsedBy {
                        print(
                            "            endorsed by companion \(endorsedBy.uuidString.lowercased()) — no prompt needed"
                        )
                    }
                case .kindsRegistered(let catalogID, let kinds):
                    print(
                        "[pluginlab] kinds registered catalog=\(catalogID.uuidString.lowercased()) manifest=\(kinds.manifestVersion)"
                    )
                    for kind in kinds.kinds {
                        print("            - \(kind.kindName): \(kind.indexDescription)")
                        if let scopeSchema = kind.scopeSchema, case .object(let keys) = scopeSchema {
                            print("              scope keys: \(keys.keys.sorted().joined(separator: ", "))")
                        }
                    }
                    for meter in kinds.meters ?? [] {
                        print("            meter \(meter.name) (per \(meter.quantum))")
                    }
                case .sessionClosed(let catalogID):
                    print("[pluginlab] session closed catalog=\(catalogID.uuidString.lowercased())")
                case .log(let message):
                    print("[pluginlab] \(message)")
            }
        }

        // The lab stands in for the app's pairing consent UI: show the
        // fingerprint, approve automatically.
        await host.setPairingApprovalHandler { info, fingerprint in
            print("[pluginlab] pairing request from \(info.name) (\(fingerprint)) — auto-approving (lab)")
            return true
        }

        // Stands in for the app's confirmation sheet: accept plugin-proposed
        // action creation and report the instance it would have minted.
        if args.acceptProposals {
            await host.setActionProposalHandler { proposal in
                let instanceID = UUID.v7()
                print("")
                print("=== action proposal from \(proposal.catalogName) ===")
                print("kind: \(proposal.kindName)")
                print("name: \(proposal.suggestedName)")
                if let reason = proposal.reason { print("reason: \(reason)") }
                if let scope = proposal.suggestedScope {
                    print("suggested scope: \(compactJSON(scope))")
                }
                print("→ approved (lab); instance=\(instanceID.uuidString.lowercased())")
                return instanceID
            }
        }

        try await host.start()
        print("[pluginlab] host node=\(hostNodeID.uuidString.lowercased())")
        print("[pluginlab] export KT_PLUGIN_SOCKET=\(args.socketPath)")

        if args.showCatalogue {
            // Give a connecting companion a moment to register before reading.
            try await Task.sleep(nanoseconds: 4_000_000_000)
            let kinds = await host.catalogue.availableKinds()
            print("")
            print("=== Catalogue (\(kinds.count) kind(s) available to instantiate) ===")
            for kind in kinds {
                print("- \(kind.displayName)  [\(kind.kindName)]")
                print("    from: \(kind.catalogName) (\(kind.vendor))  available=\(kind.isAvailable)")
                print("    scope keys: \(kind.scopeKeys.joined(separator: ", "))")
            }
        }

        if let kindName = args.call {
            print("[pluginlab] waiting up to \(Int(args.waitSeconds))s for a companion registering '\(kindName)' …")
            let catalogID = try await host.waitForKind(kindName, timeout: args.waitSeconds)

            // The lab mints an ephemeral instance the way the app's Add-action
            // flow would mint a persistent one (primitive-style instantiation).
            let instanceID = UUID.v7()
            print("[pluginlab] instantiated kind=\(kindName) instance=\(instanceID.uuidString.lowercased())")
            if let scope = args.instanceScope {
                print("[pluginlab] instance scope=\(compactJSON(scope))")
            }

            let outcome = try await host.callKind(
                catalogID: catalogID,
                kindName: kindName,
                arguments: args.callArguments,
                instanceID: instanceID,
                instanceScope: args.instanceScope
            )

            print("")
            print("=== call result (isError=\(outcome.isError)) ===")
            printContent(outcome.content)
            print("")
            print("=== receipt ===")
            switch outcome.receiptStatus {
                case .valid:
                    print("receipt: VALID (plugin-signed, bound to this authorization + result)")
                case .missing:
                    print("receipt: MISSING (recorded; v0 policy is record-only)")
                case .invalid(let reason):
                    print("receipt: INVALID — \(reason)")
            }
            for entry in outcome.usage {
                print("usage: \(entry.meter) = \(entry.units)")
            }

            let report = await host.verifyLedger()
            print("")
            print("=== ledger ===")
            print("records=\(report.recordCount) sound=\(report.isSound)")
            for issue in report.issues {
                print("issue: \(issue)")
            }

            if !args.stay {
                await host.stop()
                return
            }
        }

        print("[pluginlab] serving — Ctrl-C to exit")
        while true {
            try await Task.sleep(nanoseconds: 3_600_000_000_000)
        }
    }

    private static func printContent(_ content: Value) {
        if case .array(let items) = content {
            for item in items {
                if case .object(let fields) = item,
                    case .string(let type)? = fields["type"],
                    type == "text",
                    case .string(let text)? = fields["text"]
                {
                    print(text)
                } else {
                    print(compactJSON(item))
                }
            }
        } else {
            print(compactJSON(content))
        }
    }

    private static func compactJSON(_ value: Value) -> String {
        guard let data = try? JSONEncoder().encode(value),
            let string = String(data: data, encoding: .utf8)
        else { return "\(value)" }
        return string
    }

    private static func parse(_ args: [String]) throws -> Args {
        var parsed = Args()
        var iterator = args.makeIterator()
        while let flag = iterator.next() {
            switch flag {
                case "--socket":
                    parsed.socketPath = try requireValue(&iterator, for: flag)
                case "--node":
                    // Serve the same path a given node's app would, so a
                    // companion paired to that node reconnects unchanged.
                    let raw = try requireValue(&iterator, for: flag)
                    guard let node = UUID(uuidString: raw) else {
                        throw LabError.badFlag("--node needs a UUID")
                    }
                    parsed.node = node
                    parsed.socketPath = KeepTalkingPluginHost.socketPath(forNode: node)
                case "--call":
                    parsed.call = try requireValue(&iterator, for: flag)
                case "--args":
                    let json = try requireValue(&iterator, for: flag)
                    let value = try JSONDecoder().decode(Value.self, from: Data(json.utf8))
                    guard case .object(let fields) = value else {
                        throw LabError.badFlag("--args must be a JSON object")
                    }
                    parsed.callArguments = fields
                case "--scope":
                    let json = try requireValue(&iterator, for: flag)
                    parsed.instanceScope = try JSONDecoder().decode(Value.self, from: Data(json.utf8))
                case "--wait":
                    parsed.waitSeconds = TimeInterval(try requireValue(&iterator, for: flag)) ?? 120
                case "--stay":
                    parsed.stay = true
                case "--catalogue":
                    parsed.showCatalogue = true
                case "--accept-proposals":
                    parsed.acceptProposals = true
                default:
                    throw LabError.badFlag("unknown flag \(flag)")
            }
        }
        return parsed
    }

    private static func requireValue(
        _ iterator: inout IndexingIterator<[String]>, for flag: String
    ) throws -> String {
        guard let value = iterator.next() else {
            throw LabError.badFlag("\(flag) requires a value")
        }
        return value
    }

    private enum LabError: LocalizedError {
        case badFlag(String)
        var errorDescription: String? {
            if case .badFlag(let message) = self { return message }
            return nil
        }
    }

    private static func usage() {
        stderr(
            """
            Usage:
              KeepTalking pluginlab [--socket <path>] [--call <kind>] [--args <json>] \
            [--scope <json>] [--wait <secs>] [--stay]
            """)
    }

    private static func stderr(_ message: String) {
        FileHandle.standardError.write(Data((message + "\n").utf8))
    }
}
