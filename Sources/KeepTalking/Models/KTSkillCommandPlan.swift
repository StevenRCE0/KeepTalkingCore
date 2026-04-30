import Foundation
import MCP

/// A single atomic, human-reviewable operation in a skill execution plan.
public struct KTSkillAtomicCommand: Codable, Sendable, Identifiable {
    public var id: UUID
    public var index: Int
    public var descriptor: KeepTalkingActionDescriptor
    public var intent: String
    /// The tool name the AI agent calls (e.g. "convert_video").
    public var toolName: String?
    /// Script path relative to the skill directory (e.g. "scripts/convert_video.py").
    public var scriptPath: String?
    /// Raw JSON Schema (object) that fully describes the tool's input. When present, this
    /// replaces the generic `{arguments: object}` wrapper produced by `atomicTools()` for
    /// `execute` / `call-tool` verbs, letting the model expose a script's real parameter
    /// shape (named arguments, types, required fields) instead of a free-form blob.
    public var argumentsSchema: String?

    public init(
        id: UUID = UUID(),
        index: Int,
        descriptor: KeepTalkingActionDescriptor,
        intent: String,
        toolName: String? = nil,
        scriptPath: String? = nil,
        argumentsSchema: String? = nil
    ) {
        self.id = id
        self.index = index
        self.descriptor = descriptor
        self.intent = intent
        self.toolName = toolName
        self.scriptPath = scriptPath
        self.argumentsSchema = argumentsSchema
    }

    private enum CodingKeys: String, CodingKey {
        case id, index, descriptor, intent, toolName, scriptPath, argumentsSchema
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = (try? c.decode(UUID.self, forKey: .id)) ?? UUID()
        self.index = try c.decode(Int.self, forKey: .index)
        self.descriptor = try c.decode(KeepTalkingActionDescriptor.self, forKey: .descriptor)
        self.intent = try c.decode(String.self, forKey: .intent)
        self.toolName = try c.decodeIfPresent(String.self, forKey: .toolName)
        self.scriptPath = try c.decodeIfPresent(String.self, forKey: .scriptPath)
        self.argumentsSchema = try c.decodeIfPresent(String.self, forKey: .argumentsSchema)
    }
}

public struct KTSkillCommandPlan: Codable, Sendable {
    public var skillActionID: UUID
    public var skillName: String
    public var rationale: String
    public var requiredEnv: [String]
    public var requiredDirectories: [String]
    /// Labelled file keys the skill needs the user to point at (e.g. a script entry
    /// point, a config file). Distinct from `requiredDirectories` — the host opens
    /// a file picker, not a folder picker, when collecting these.
    public var requiredFiles: [String]
    /// Network hosts the skill needs egress to (e.g. "api.github.com").
    public var requiredNetworkHosts: [String]
    /// Subset of `requiredNetworkHosts` the user explicitly granted at plan time.
    public var grantedNetworkHosts: [String]
    public var commands: [KTSkillAtomicCommand]
    public var suggestedManifest: String?
    public var suggestedScripts: [String: String]?  // [Path: Content]
    /// Tool declarations to write into the SKILL.md frontmatter as `scripts.<name>: <path>`.
    /// For new skills this is derived from suggestedScripts; for existing skills it reflects
    /// what the analyser found in the scripts/ directory.
    public var toolDeclarations: [String: String]?
    /// Parameters collected interactively during planning (env values, directory paths,
    /// file paths). Ready to be stored directly in the skill bundle's `parameters` dict.
    public var collectedParameters: [String: String]?

    public init(
        skillActionID: UUID,
        skillName: String,
        rationale: String,
        requiredEnv: [String] = [],
        requiredDirectories: [String] = [],
        requiredFiles: [String] = [],
        requiredNetworkHosts: [String] = [],
        grantedNetworkHosts: [String] = [],
        commands: [KTSkillAtomicCommand]
    ) {
        self.skillActionID = skillActionID
        self.skillName = skillName
        self.rationale = rationale
        self.requiredEnv = requiredEnv
        self.requiredDirectories = requiredDirectories
        self.requiredFiles = requiredFiles
        self.requiredNetworkHosts = requiredNetworkHosts
        self.grantedNetworkHosts = grantedNetworkHosts
        self.commands = commands
        self.suggestedManifest = nil
        self.suggestedScripts = nil
    }

    private enum CodingKeys: String, CodingKey {
        case skillActionID, skillName, rationale, requiredEnv, requiredDirectories,
            requiredFiles, requiredNetworkHosts, grantedNetworkHosts, commands,
            suggestedManifest, suggestedScripts, toolDeclarations, collectedParameters
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.skillActionID = try c.decode(UUID.self, forKey: .skillActionID)
        self.skillName = try c.decode(String.self, forKey: .skillName)
        self.rationale = try c.decode(String.self, forKey: .rationale)
        self.requiredEnv = (try? c.decode([String].self, forKey: .requiredEnv)) ?? []
        self.requiredDirectories = (try? c.decode([String].self, forKey: .requiredDirectories)) ?? []
        self.requiredFiles = (try? c.decode([String].self, forKey: .requiredFiles)) ?? []
        self.requiredNetworkHosts = (try? c.decode([String].self, forKey: .requiredNetworkHosts)) ?? []
        self.grantedNetworkHosts = (try? c.decode([String].self, forKey: .grantedNetworkHosts)) ?? []
        self.commands = try c.decode([KTSkillAtomicCommand].self, forKey: .commands)
        self.suggestedManifest = try c.decodeIfPresent(String.self, forKey: .suggestedManifest)
        self.suggestedScripts = try c.decodeIfPresent([String: String].self, forKey: .suggestedScripts)
        self.toolDeclarations = try c.decodeIfPresent([String: String].self, forKey: .toolDeclarations)
        self.collectedParameters = try c.decodeIfPresent([String: String].self, forKey: .collectedParameters)
    }
}

extension KTSkillCommandPlan {
    /// Generates an atomic MCP toolset from the planned commands.
    public func atomicTools() -> [MCP.Tool] {
        var tools: [MCP.Tool] = []
        for cmd in commands {
            guard let verb = cmd.descriptor.action?.verbs?.first else {
                continue
            }
            let name = "kt_cmd_\(cmd.index)_\(verb.rawValue)"

            // If the planner attached a full JSON Schema, use it verbatim as the
            // tool input schema. This is the path for execute/call-tool commands
            // that wrap a specific script with named arguments.
            if let raw = cmd.argumentsSchema,
                let data = raw.data(using: .utf8),
                let schemaValue = try? JSONDecoder().decode(MCP.Value.self, from: data)
            {
                let tool = MCP.Tool(
                    name: name,
                    description: "[\(verb.rawValue.uppercased())] \(cmd.intent)",
                    inputSchema: schemaValue
                )
                tools.append(tool)
                continue
            }

            var properties: [String: MCP.Value] = [:]
            var required: [MCP.Value] = []

            switch verb {
                case .write:
                    properties["content"] = .object([
                        "type": .string("string"),
                        "description": .string("The content to write."),
                    ])
                    required.append(.string("content"))
                case .execute, .callTool:
                    properties["arguments"] = .object([
                        "type": .string("object"),
                        "description": .string("Optional arguments for the execution."),
                        "additionalProperties": .bool(true),
                    ])
                case .network:
                    properties["body"] = .object([
                        "type": .string("string"),
                        "description": .string("Optional request body."),
                    ])
                case .grep:
                    properties["pattern"] = .object([
                        "type": .string("string"),
                        "description": .string("Regex pattern to search for."),
                    ])
                    required.append(.string("pattern"))
                case .read, .ls:
                    // No inputs needed
                    break
            }

            var schemaDict: [String: MCP.Value] = [
                "type": .string("object"),
                "properties": .object(properties),
                "additionalProperties": .bool(false),
            ]
            if !required.isEmpty {
                schemaDict["required"] = .array(required)
            }

            let tool = MCP.Tool(
                name: name,
                description: "[\(verb.rawValue.uppercased())] \(cmd.intent)",
                inputSchema: .object(schemaDict)
            )
            tools.append(tool)
        }
        return tools
    }
}
