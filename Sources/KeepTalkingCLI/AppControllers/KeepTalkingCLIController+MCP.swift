import Foundation
import KeepTalkingSDK

extension KeepTalkingCLIController {
    func runMCPManagementCommand(_ command: MCPManagementCommand) async throws {
        switch command {
            case .list:
                await listMCPActions()
            case .remove(let actionID):
                try await client.removeMCPAction(actionID: actionID)
                print("[mcp] removed action=\(actionID.uuidString.lowercased())")
            case .addHTTP(let name, let url, let description, let headers):
                try await registerHTTPMCPAction(
                    name: name,
                    url: url,
                    description: description ?? "",
                    headers: headers
                )
            case .addSTDIO(let name, let command, let environment):
                try await registerStdioMCPActionInternal(
                    name: name,
                    command: command,
                    environment: environment
                )
        }
    }

    func listMCPActions() async {
        do {
            let actions = try await client.listAvailableActions()
                .filter { $0.isMCP }
            if actions.isEmpty {
                print("[mcp] none")
                return
            }
            print("[mcp] total=\(actions.count)")
            for action in actions {
                print("- id=\(action.actionID.uuidString.lowercased()) name=\(action.name)")
                if !action.description.isEmpty {
                    print("  desc=\(action.description)")
                }
            }
        } catch {
            fputs("List MCP actions failed: \(error.localizedDescription)\n", stderr)
        }
    }

    func removeMCPAction(actionIDRaw: String) async {
        let trimmedActionID = actionIDRaw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let actionID = UUID(uuidString: trimmedActionID) else {
            print("Invalid action UUID: \(trimmedActionID)")
            return
        }
        do {
            try await client.removeMCPAction(actionID: actionID)
            print("[mcp] removed action=\(actionID.uuidString.lowercased())")
        } catch {
            fputs("MCP remove failed: \(error.localizedDescription)\n", stderr)
        }
    }

    func registerHTTPMCPAction(
        name: String,
        urlRaw: String,
        description: String,
        headers: [String: String]
    ) async {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedURL = urlRaw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty, !trimmedURL.isEmpty else {
            print("Usage: /mcp add http <name> <url> [--header KEY=VALUE ...] [description]")
            return
        }
        guard let url = URL(string: trimmedURL) else {
            print("Invalid MCP URL: \(trimmedURL)")
            return
        }
        do {
            try await registerHTTPMCPAction(
                name: trimmedName,
                url: url,
                description: description,
                headers: headers
            )
        } catch {
            fputs("MCP registration failed: \(error.localizedDescription)\n", stderr)
        }
    }

    func registerStdioMCPAction(
        name: String,
        command: [String],
        environment: [String: String]
    ) async {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else {
            print("Usage: /mcp add stdio <name> [--env KEY=VALUE ...] -- <command> [args...]")
            return
        }
        guard !command.isEmpty else {
            print("Usage: /mcp add stdio <name> [--env KEY=VALUE ...] -- <command> [args...]")
            return
        }
        do {
            try await registerStdioMCPActionInternal(
                name: trimmedName,
                command: command,
                environment: environment
            )
        } catch {
            fputs("MCP stdio registration failed: \(error.localizedDescription)\n", stderr)
        }
    }

    private func registerHTTPMCPAction(
        name: String,
        url: URL,
        description: String,
        headers: [String: String]
    ) async throws {
        let trimmedDescription = description.trimmingCharacters(in: .whitespacesAndNewlines)
        let indexDescription =
            trimmedDescription.isEmpty
            ? "MCP server: \(name)"
            : trimmedDescription

        let action = try await client.registerMCPAction(
            bundle: KeepTalkingMCPBundle(
                name: name,
                indexDescription: indexDescription,
                service: .http(
                    url: url,
                    payload: Data(),
                    headers: headers,
                    scope: nil
                )
            )
        )
        let actionID = action.id?.uuidString.lowercased() ?? "unknown"
        let headerLabel =
            headers.isEmpty
            ? "none"
            : headers.sorted { $0.key < $1.key }
                .map { "\($0.key)=\($0.value)" }
                .joined(separator: ",")
        print(
            "[mcp] registered action=\(actionID) type=http name=\(name) url=\(url.absoluteString) headers=\(headerLabel)"
        )
    }

    func installMCPHTTPAuthHandler(on targetClient: KeepTalkingClient) {
        targetClient.setMCPHTTPAuthURLHandler {
            actionID, url, message in
            return await Self.handleMCPHTTPAuthURL(
                actionID: actionID,
                url: url,
                message: message
            )
        }
    }

    private static func handleMCPHTTPAuthURL(
        actionID: UUID,
        url: URL,
        message: String
    ) async -> KeepTalkingMCPHTTPAuthResult {
        let actionLabel = actionID.uuidString.lowercased()
        print("[mcp][http][auth] action=\(actionLabel) \(message)")
        print("[mcp][http][auth] open this URL to authenticate: \(url.absoluteString)")
        openURLInDefaultBrowser(url)

        print(
            "Paste callback URL (or press Enter to cancel): ",
            terminator: ""
        )
        guard let raw = readLine(strippingNewline: true) else {
            return .cancelled
        }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return .cancelled
        }
        guard let callbackURL = URL(string: trimmed), callbackURL.scheme != nil else {
            fputs("Invalid callback URL.\n", stderr)
            return .declined
        }
        return .completed(callbackURL: callbackURL)
    }

    private static func openURLInDefaultBrowser(_ url: URL) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = [url.absoluteString]
        do {
            try process.run()
        } catch {
            // Best-effort only. URL is still printed for manual open.
        }
    }

    private func registerStdioMCPActionInternal(
        name: String,
        command: [String],
        environment: [String: String]
    ) async throws {
        let action = try await client.registerMCPAction(
            bundle: KeepTalkingMCPBundle(
                name: name,
                indexDescription: "MCP stdio server: \(name)",
                service: .stdio(
                    arguments: command,
                    environment: environment
                )
            )
        )
        let actionID = action.id?.uuidString.lowercased() ?? "unknown"
        let commandLabel = command.joined(separator: " ")
        let envLabel: String
        if environment.isEmpty {
            envLabel = "none"
        } else {
            envLabel =
                environment
                .sorted { $0.key < $1.key }
                .map { "\($0.key)=\($0.value)" }
                .joined(separator: ",")
        }
        print("[mcp] registered action=\(actionID) type=stdio name=\(name) command=\(commandLabel) env=\(envLabel)")
    }
}
