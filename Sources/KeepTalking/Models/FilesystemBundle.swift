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
    /// Read a local file and register it as a context blob attachment.
    case fileToBlob = "file-to-blob"
    /// Copy a context blob attachment to a local filesystem path.
    case blobToFile = "blob-to-file"

    /// Minimum mask bit required to invoke this operation.
    public var requiredMask: KeepTalkingActionPermissionMask {
        switch self {
        case .ls, .readFile, .grep, .stat, .fileToBlob:
            return .read
        case .writeFile, .blobToFile:
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
        case .fileToBlob:
            return "Read a local file and upload it as a blob attachment scoped to the current context."
        case .blobToFile:
            return "Copy a context blob attachment identified by blob_id to a local filesystem path."
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
        case .fileToBlob:
            return [
                "path": [
                    "type": "string",
                    "description": "Local file path to upload into the context blob store.",
                ],
                "filename": [
                    "type": "string",
                    "description": "Optional display filename. Defaults to the last path component.",
                ],
            ]
        case .blobToFile:
            return [
                "blob_id": [
                    "type": "string",
                    "description": "Blob ID of the context attachment to copy.",
                ],
                "path": [
                    "type": "string",
                    "description": "Destination local filesystem path to write the blob data.",
                ],
            ]
        }
    }

    public var requiredInputProperties: [String] {
        switch self {
        case .ls: return ["path"]
        case .readFile: return ["path"]
        case .grep: return ["pattern", "path"]
        case .writeFile: return ["path", "content"]
        case .stat: return ["path"]
        case .fileToBlob: return ["path"]
        case .blobToFile: return ["blob_id", "path"]
        }
    }
}
