import Foundation

/// Single source of truth for the per-run resource manifest exposed to skill
/// scripts and ACP agents. Every file/dir a run may touch — context attachments,
/// one-time-blob inputs, filesystem-action roots — becomes an `Entry` with a
/// stable environment-variable handle `KT_<KIND>_<H8>`. The SAME entry array
/// drives both the injected environment dict (`environmentVariables()`) and the
/// agent-facing prompt block (`promptBlock()`), so the two can never diverge.
///
/// Emission is honoured only where a sandboxed subprocess receives an environment
/// (macOS); callers gate invocation to those paths. The type itself is a plain,
/// cross-platform-testable value with no platform-specific APIs.
public struct KTResourceManifest: Sendable {

    /// The resource family — also the `<KIND>` token in the env-var name.
    public enum Kind: String, Sendable {
        case attachment = "ATTACHMENT"
        case otb = "OTB"
        case fs = "FS"
    }

    /// Sandbox-relevant data flow for a resource, projected from the SDK's
    /// `KeepTalkingResourceDirection`.
    public enum Direction: Sendable {
        case read
        case write
        case readWrite

        public init(_ direction: KeepTalkingResourceDirection) {
            switch direction {
                case .input: self = .read
                case .output: self = .write
                case .inputOutput: self = .readWrite
            }
        }
    }

    /// A candidate resource handed to `build` before env-key assignment. The
    /// caller passes ONLY resources whose path the sandbox actually granted (or
    /// resources reached via filesystem operations) — the manifest never
    /// re-derives reachability, so advertising stays coupled to the real grant.
    public struct Candidate: Sendable {
        public let kind: Kind
        public let id: UUID
        /// Local absolute path the env var resolves to, or `nil` when the resource
        /// is reached through filesystem operations (e.g. a remote fs root).
        public let path: URL?
        public let direction: Direction
        public let displayName: String
        public let isDirectory: Bool

        public init(
            kind: Kind,
            id: UUID,
            path: URL?,
            direction: Direction,
            displayName: String,
            isDirectory: Bool
        ) {
            self.kind = kind
            self.id = id
            self.path = path
            self.direction = direction
            self.displayName = displayName
            self.isDirectory = isDirectory
        }
    }

    /// A resolved manifest entry: a candidate with its final, collision-free
    /// env-var key and canonicalised path.
    public struct Entry: Sendable {
        public let kind: Kind
        public let id: UUID
        public let envKey: String
        public let path: URL?
        public let direction: Direction
        public let displayName: String
        public let isDirectory: Bool
    }

    public let entries: [Entry]
    /// The umbrella staging dir exposed as `$KT_ATTACHMENTS` (kept alongside the
    /// per-resource keys for scripts that read the whole dir).
    public let umbrellaAttachmentsDir: URL?

    public init(entries: [Entry], umbrellaAttachmentsDir: URL?) {
        self.entries = entries
        self.umbrellaAttachmentsDir = umbrellaAttachmentsDir
    }

    // MARK: - Key derivation

    /// The `<H8>` suffix: the trailing `length` hex chars of the UUID, uppercased.
    /// Sourced from the TRAILING (random) field because resource IDs are UUID v7
    /// (time-prefixed) — the leading hex collides for IDs minted close together.
    static func hexSuffix(_ id: UUID, length: Int) -> String {
        let hex = id.uuidString.replacingOccurrences(of: "-", with: "")
        return String(hex.suffix(length)).uppercased()
    }

    /// The env-var key for a resource at a given suffix length.
    static func envKey(kind: Kind, id: UUID, length: Int = 8) -> String {
        "KT_\(kind.rawValue)_\(hexSuffix(id, length: length))"
    }

    // MARK: - Build

    /// Builds a manifest from already-granted candidates. Assigns collision-free
    /// env keys (escalating the hex suffix when two same-kind resources share a
    /// short suffix), canonicalises every path once (so the env value, the prompt
    /// text, and the sandbox grant all agree on the /private/var form), and strips
    /// control characters from display names so a wire-controlled filename cannot
    /// forge prompt lines.
    public static func build(
        grantedCandidates: [Candidate],
        umbrellaAttachmentsDir: URL?
    ) -> KTResourceManifest {
        let keys = assignKeys(grantedCandidates)
        let entries = zip(grantedCandidates, keys).map { candidate, key in
            Entry(
                kind: candidate.kind,
                id: candidate.id,
                envKey: key,
                path: candidate.path?.resolvingSymlinksInPath().standardizedFileURL,
                direction: candidate.direction,
                displayName: sanitizedDisplayName(candidate.displayName),
                isDirectory: candidate.isDirectory
            )
        }
        return KTResourceManifest(
            entries: entries,
            umbrellaAttachmentsDir: umbrellaAttachmentsDir?
                .resolvingSymlinksInPath().standardizedFileURL
        )
    }

    /// Assigns each candidate a unique env key, escalating the hex-suffix length
    /// (8 → 12 → 16 → 32) only for keys that collide. Distinct UUIDs of the same
    /// kind are unique at full length, so termination is guaranteed.
    private static func assignKeys(_ candidates: [Candidate]) -> [String] {
        var keys = candidates.map { envKey(kind: $0.kind, id: $0.id, length: 8) }
        for length in [12, 16, 32] {
            var counts: [String: Int] = [:]
            for key in keys { counts[key, default: 0] += 1 }
            let collided = Set(counts.filter { $0.value > 1 }.keys)
            if collided.isEmpty { break }
            for index in candidates.indices where collided.contains(keys[index]) {
                keys[index] = envKey(
                    kind: candidates[index].kind,
                    id: candidates[index].id,
                    length: length
                )
            }
        }
        return keys
    }

    private static func sanitizedDisplayName(_ name: String) -> String {
        // Strip BOTH control characters AND newlines: `.controlCharacters` omits
        // the Unicode line/paragraph separators U+2028/U+2029 (categories Zl/Zp),
        // which `.newlines` covers. A wire-controlled filename must not be able to
        // forge extra lines in the prompt block or the ACP system preamble.
        name
            .components(separatedBy: .controlCharacters).joined()
            .components(separatedBy: .newlines).joined()
    }

    // MARK: - Emission

    /// The environment dict to merge into a script/agent subprocess. Each entry
    /// with a local path contributes `<envKey> = <path>`; the umbrella dir
    /// contributes `KT_ATTACHMENTS`. Resources reached via filesystem operations
    /// (no local path) contribute no variable — they are described in the prompt.
    public func environmentVariables() -> [String: String] {
        var env: [String: String] = [:]
        for entry in entries {
            if let path = entry.path {
                env[entry.envKey] = path.path
            }
        }
        if let umbrella = umbrellaAttachmentsDir {
            env["KT_ATTACHMENTS"] = umbrella.path
        }
        return env
    }

    /// The agent-facing description of the manifest, rendered from the SAME entry
    /// array as `environmentVariables()`. Returns `nil` when there is nothing to
    /// describe. Every example double-quotes the variable because staged names and
    /// temp roots can contain spaces.
    public func promptBlock() -> String? {
        guard !entries.isEmpty || umbrellaAttachmentsDir != nil else { return nil }

        let exampleKey = entries.first?.envKey ?? "KT_ATTACHMENT_00000000"
        var lines: [String] = [
            "## KeepTalking resources (this run)",
            "",
            "KeepTalking has provisioned the items below into your environment. Each is "
                + "an environment variable whose value is an ABSOLUTE PATH. Reference "
                + "resources by their variable — never hardcode the path, never invent a "
                + "variable not listed here. Always quote it; paths can contain spaces:",
            "",
            "    cat \"$\(exampleKey)\"",
            "",
            "Available this run:",
        ]

        for entry in entries {
            let type = entry.isDirectory ? "dir " : "file"
            let access: String
            switch entry.direction {
                case .read: access = "read"
                case .write: access = "write"
                case .readWrite: access = "read/write"
            }
            var line = "  $\(entry.envKey)  \(type)  \"\(entry.displayName)\"  \(access)"
            if entry.path == nil {
                line += "  (access via filesystem operations)"
            }
            lines.append(line)
        }

        lines.append(contentsOf: [
            "",
            "Usage:",
            "- A `file` variable is the path to that file; a `dir` variable is a directory "
                + "you may traverse. Always quote: ls \"$VAR\".",
            "- `read` items are inputs — do not modify them. `write` and `read/write` items "
                + "accept changes; place results you want returned at a `write` path and "
                + "KeepTalking ships them back.",
            "- Items marked \"access via filesystem operations\" are remote; reach them with "
                + "the filesystem tools (list/read/get-file/put-file), not a local path.",
            "- Only touch a resource the task actually needs.",
        ])

        if umbrellaAttachmentsDir != nil {
            lines.append("")
            lines.append("(Staged files are also gathered under $KT_ATTACHMENTS.)")
        }

        return lines.joined(separator: "\n")
    }
}
