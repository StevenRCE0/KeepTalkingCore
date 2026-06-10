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
    /// Apply a `s/pattern/replacement/flags` substitution to a file in place.
    case sed
    /// Write or overwrite a file.
    case writeFile = "write-file"
    /// Return metadata (size, modification date, type) for a path.
    case stat
    /// Read a file on the host and stream it back to the caller as a one-time
    /// encrypted blob (point-to-point, ephemeral — no context attachment).
    case getFile = "get-file"
    /// Receive a one-time encrypted blob the caller streamed and write it to a
    /// path on the host.
    case putFile = "put-file"

    /// Minimum structural verb required to invoke this operation. A "read" grant
    /// scope expands to `{.read, .ls, .grep}` (see `ScopeResolver`), so `ls`/`grep`
    /// gate on their own verbs while `read-file`/`stat`/`get-file` gate on `.read`.
    public var requiredVerb: KeepTalkingActionVerb {
        switch self {
            case .ls:
                return .ls
            case .grep:
                return .grep
            case .readFile, .stat, .getFile:
                return .read
            case .writeFile, .sed, .putFile:
                return .write
        }
    }
}

/// An action bundle that exposes structured filesystem access to the AI agent.
///
/// A single bundle covers all operations; the grant scope on the relation
/// controls which subset a remote caller may actually invoke.
public struct KeepTalkingFilesystemBundle: KeepTalkingActionBundle {
    public var id: UUID
    public var name: String
    public var indexDescription: String

    /// Required path prefix that sandboxes every operation. ALL caller paths are
    /// resolved strictly relative to this root, and anything resolving outside
    /// it is rejected. There is no unsandboxed mode; an empty root fails closed
    /// at execution.
    public var rootPath: String

    public init(
        id: UUID = UUID.v7(),
        name: String = "filesystem",
        indexDescription: String =
            "Access local files and directories on the action host.",
        rootPath: String
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
            case .sed:
                return
                    "Apply a sed-style s/pattern/replacement/flags substitution to a file in place. Returns a summary of what changed."
            case .writeFile:
                return "Write or overwrite the content of a file."
            case .stat:
                return "Return metadata (size, type, modification date) for a path."
            case .getFile:
                return
                    "Read a file on the host and return its bytes to you via a one-time encrypted transfer — point-to-point and ephemeral, NOT shared with the conversation. Use for binary or large files you need to pull from this host."
            case .putFile:
                return
                    "Write a file you provide onto the host's filesystem. Supply the destination `path`; the bytes are streamed privately as a one-time encrypted transfer, not published as a context attachment."
        }
    }

    /// OpenAI-compatible JSON-schema for this operation's arguments.
    public var inputSchemaProperties: [String: [String: String]] {
        switch self {
            case .ls:
                return [
                    "path": [
                        "type": "string",
                        "description":
                            "Directory to list, RELATIVE to the action's root. Use \".\" (or \"\") for the root itself; never an absolute path.",
                    ]
                ]
            case .readFile:
                return [
                    "path": [
                        "type": "string",
                        "description": "File to read, relative to the action's root.",
                    ]
                ]
            case .grep:
                return [
                    "pattern": ["type": "string", "description": "Regex pattern to search for."],
                    "path": [
                        "type": "string",
                        "description":
                            "Directory to search under, relative to the action's root (\".\" = root).",
                    ],
                ]
            case .sed:
                return [
                    "path": [
                        "type": "string",
                        "description": "File to edit in place, relative to the action's root.",
                    ],
                    "expression": [
                        "type": "string",
                        "description":
                            "A sed substitution, e.g. s/foo/bar/g (s/pattern/replacement/flags; flag 'g' = global).",
                    ],
                ]
            case .writeFile:
                return [
                    "path": [
                        "type": "string",
                        "description": "File to write, relative to the action's root.",
                    ],
                    "content": ["type": "string", "description": "Content to write."],
                ]
            case .stat:
                return [
                    "path": [
                        "type": "string",
                        "description": "Path to stat, relative to the action's root.",
                    ]
                ]
            case .getFile:
                return [
                    "path": [
                        "type": "string",
                        "description": "File on the host to read and return, RELATIVE to the action's root.",
                    ]
                ]
            case .putFile:
                return [
                    "source": [
                        "type": "string",
                        "description":
                            "Absolute path of YOUR local file to send (this is on the CALLER, so it is a real local path). Streamed to the host as a one-time encrypted transfer, not published to the conversation.",
                    ],
                    "path": [
                        "type": "string",
                        "description":
                            "Destination on the host, RELATIVE to the action's root. Intermediate directories are created automatically.",
                    ],
                ]
        }
    }

    public var requiredInputProperties: [String] {
        switch self {
            case .ls: return ["path"]
            case .readFile: return ["path"]
            case .grep: return ["pattern", "path"]
            case .sed: return ["path", "expression"]
            case .writeFile: return ["path", "content"]
            case .stat: return ["path"]
            case .getFile: return ["path"]
            case .putFile: return ["source", "path"]
        }
    }
}
