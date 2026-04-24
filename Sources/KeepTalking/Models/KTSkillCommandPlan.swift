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

    public init(
        id: UUID = UUID(),
        index: Int,
        descriptor: KeepTalkingActionDescriptor,
        intent: String,
        toolName: String? = nil,
        scriptPath: String? = nil
    ) {
        self.id = id
        self.index = index
        self.descriptor = descriptor
        self.intent = intent
        self.toolName = toolName
        self.scriptPath = scriptPath
    }
}

public struct KTSkillCommandPlan: Codable, Sendable {
    public var skillActionID: UUID
    public var skillName: String
    public var rationale: String
    public var requiredEnv: [String]
    public var requiredDirectories: [String]
    public var commands: [KTSkillAtomicCommand]
    public var suggestedManifest: String?
    public var suggestedScripts: [String: String]?  // [Path: Content]
    /// Tool declarations to write into the SKILL.md frontmatter as `scripts.<name>: <path>`.
    /// For new skills this is derived from suggestedScripts; for existing skills it reflects
    /// what the analyser found in the scripts/ directory.
    public var toolDeclarations: [String: String]?
    /// Parameters collected interactively during planning (env values, directory paths).
    /// These are ready to be stored directly in the skill bundle's `parameters` dict.
    public var collectedParameters: [String: String]?

    public init(
        skillActionID: UUID,
        skillName: String,
        rationale: String,
        requiredEnv: [String] = [],
        requiredDirectories: [String] = [],
        commands: [KTSkillAtomicCommand]
    ) {
        self.skillActionID = skillActionID
        self.skillName = skillName
        self.rationale = rationale
        self.requiredEnv = requiredEnv
        self.requiredDirectories = requiredDirectories
        self.commands = commands
        self.suggestedManifest = nil
        self.suggestedScripts = nil
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
