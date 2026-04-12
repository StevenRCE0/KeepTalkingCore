import Foundation

/// Identifies a single filesystem capability exposed by a filesystem action.
public enum KeepTalkingFilesystemOperation: String, Codable, Sendable, Hashable,
    CaseIterable
{
    /// List directory contents.
    case ls
    /// Read the text content of a file.
    case readFile = "read-file"
    /// Search file trees with a regex pattern (like grep -r).
    case grep
    /// Write or overwrite a file.
    case writeFile = "write-file"
    /// Return metadata (size, modification date, type) for a path.
    case stat

    /// Minimum mask bit required to invoke this operation.
    public var requiredMask: KeepTalkingActionPermissionMask {
        switch self {
        case .ls, .readFile, .grep, .stat:
            return .read
        case .writeFile:
            return .write
        }
    }
}

/// An action bundle that exposes structured filesystem access to the AI agent.
///
/// A single bundle covers all five operations; the grant mask on the relation
/// controls which subset a remote caller may actually invoke.
public struct KeepTalkingFilesystemBundle: KeepTalkingActionBundle {
    public var id: UUID
    public var name: String
    public var indexDescription: String

    /// Optional path prefix used to sandbox every operation.
    /// Paths outside this root are rejected at execution time.
    /// `nil` means no sandboxing (owner's full filesystem is accessible).
    public var rootPath: String?

    public init(
        id: UUID = UUID(),
        name: String = "filesystem",
        indexDescription: String =
            "Access local files and directories on the action host.",
        rootPath: String? = nil
    ) {
        self.id = id
        self.name = name
        self.indexDescription = indexDescription
        self.rootPath = rootPath
    }
}

/// Describes one filesystem tool as it appears in the action catalog.
public struct KeepTalkingFilesystemTool: Codable, Sendable {
    public var operation: KeepTalkingFilesystemOperation
    public var description: String

    public init(
        operation: KeepTalkingFilesystemOperation,
        description: String
    ) {
        self.operation = operation
        self.description = description
    }
}

extension KeepTalkingFilesystemOperation {
    /// Human-readable description of this operation for catalog displays.
    public var toolDescription: String {
        switch self {
        case .ls:
            return "List the contents of a directory."
        case .readFile:
            return "Read the text content of a file."
        case .grep:
            return "Search file trees recursively with a regex pattern."
        case .writeFile:
            return "Write or overwrite the content of a file."
        case .stat:
            return "Return metadata (size, type, modification date) for a path."
        }
    }

    /// OpenAI-compatible JSON-schema for this operation's arguments.
    public var inputSchemaProperties: [String: [String: String]] {
        switch self {
        case .ls:
            return ["path": ["type": "string", "description": "Directory path to list."]]
        case .readFile:
            return ["path": ["type": "string", "description": "File path to read."]]
        case .grep:
            return [
                "pattern": ["type": "string", "description": "Regex pattern to search for."],
                "path": ["type": "string", "description": "Root path to search under."],
            ]
        case .writeFile:
            return [
                "path": ["type": "string", "description": "File path to write."],
                "content": ["type": "string", "description": "Content to write."],
            ]
        case .stat:
            return ["path": ["type": "string", "description": "Path to stat."]]
        }
    }

    public var requiredInputProperties: [String] {
        switch self {
        case .ls: return ["path"]
        case .readFile: return ["path"]
        case .grep: return ["pattern", "path"]
        case .writeFile: return ["path", "content"]
        case .stat: return ["path"]
        }
    }
}
