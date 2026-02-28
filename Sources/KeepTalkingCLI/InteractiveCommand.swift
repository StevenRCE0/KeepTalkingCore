import Foundation

enum InteractiveCommand {
    case quit
    case stats
    case p2pTrial
    case newContext
    case join(String)
    case send(String)
    case trust(nodeID: String, scope: String)
    case lure(nodeID: String, publicKey: String)
    case actionsList
    case actionsGrant(nodeID: String, actionID: String, scope: String)
    case ai(String)
    case mcpList
    case mcpRemove(String)
    case mcpAddHTTP(name: String, url: String, description: String)
    case mcpAddSTDIO(
        name: String,
        command: [String],
        environment: [String: String]
    )
    case skillList
    case skillRemove(String)
    case skillAddDirectory(name: String, path: String, description: String)

    static func parse(_ rawLine: String) -> InteractiveCommand? {
        let text = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            return nil
        }

        if text == "/quit" || text == "/exit" {
            return .quit
        }
        if text == "/stats" {
            return .stats
        }
        if text == "/p2p" || text == "/p2p-trial" {
            return .p2pTrial
        }
        if text == "/new" {
            return .newContext
        }
        if text.hasPrefix("/join") {
            let parts = text.split(maxSplits: 1, whereSeparator: \.isWhitespace)
            let context = parts.count > 1 ? String(parts[1]) : ""
            return .join(context)
        }
        if text.hasPrefix("/trust") {
            let parts = text.split(maxSplits: 2, whereSeparator: \.isWhitespace)
            let node = parts.count > 1 ? String(parts[1]) : ""
            let scope = parts.count > 2 ? String(parts[2]) : "all"
            return .trust(nodeID: node, scope: scope)
        }
        if text.hasPrefix("/lure") {
            let parts = text.split(maxSplits: 2, whereSeparator: \.isWhitespace)
            let node = parts.count > 1 ? String(parts[1]) : ""
            let publicKey = parts.count > 2 ? String(parts[2]) : ""
            return .lure(nodeID: node, publicKey: publicKey)
        }
        if text.hasPrefix("/ai") {
            let prefix = "/ai"
            let prompt =
                text.count > prefix.count
                ? String(
                    text.dropFirst(prefix.count).trimmingCharacters(
                        in: .whitespacesAndNewlines
                    )
                ) : ""
            return .ai(prompt)
        }

        if text.hasPrefix("/actions") {
            let parts = text.split(maxSplits: 4, whereSeparator: \.isWhitespace)
            if parts.count == 1 || parts[1] == "list" {
                return .actionsList
            }
            if parts.count >= 4, parts[1] == "grant" {
                let nodeID = String(parts[2])
                let actionID = String(parts[3])
                let scope = parts.count > 4 ? String(parts[4]) : "context"
                return .actionsGrant(
                    nodeID: nodeID,
                    actionID: actionID,
                    scope: scope
                )
            }
            return .actionsList
        }

        if text.hasPrefix("/mcp") {
            let parts = text.split(whereSeparator: \.isWhitespace).map(String.init)
            if parts.count == 1 || parts[1] == "list" {
                return .mcpList
            }
            if parts.count >= 3, parts[1] == "remove" {
                return .mcpRemove(parts[2])
            }
            if parts.count >= 5, parts[1] == "add", parts[2] == "http" {
                let name = parts[3]
                let url = parts[4]
                let description = parts.count > 5 ? parts[5...].joined(separator: " ") : ""
                return .mcpAddHTTP(name: name, url: url, description: description)
            }
            if parts.count >= 5, parts[1] == "add", parts[2] == "stdio" {
                let name = parts[3]
                let spec = Array(parts[4...])
                if let parsed = parseStdioSpec(spec) {
                    return .mcpAddSTDIO(
                        name: name,
                        command: parsed.command,
                        environment: parsed.environment
                    )
                }
                return .mcpAddSTDIO(name: name, command: [], environment: [:])
            }
            return .mcpList
        }

        if text.hasPrefix("/skill") {
            let parts = text.split(whereSeparator: \.isWhitespace).map(String.init)
            if parts.count == 1 || parts[1] == "list" {
                return .skillList
            }
            if parts.count >= 3, parts[1] == "remove" {
                return .skillRemove(parts[2])
            }
            if parts.count >= 5, parts[1] == "add", parts[2] == "directory" {
                let name = parts[3]
                let path = parts[4]
                let description = parts.count > 5 ? parts[5...].joined(separator: " ") : ""
                return .skillAddDirectory(
                    name: name,
                    path: path,
                    description: description
                )
            }
            return .skillList
        }

        return .send(text)
    }

    private static func parseStdioSpec(
        _ tokens: [String]
    ) -> (command: [String], environment: [String: String])? {
        guard !tokens.isEmpty else {
            return nil
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
                    return nil
                }
                let assignment = tokens[index]
                guard let eq = assignment.firstIndex(of: "="), eq != assignment.startIndex else {
                    return nil
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

        guard !command.isEmpty else {
            return nil
        }
        return (command, environment)
    }
}
