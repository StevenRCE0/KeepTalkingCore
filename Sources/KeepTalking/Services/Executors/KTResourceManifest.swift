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

    /// The resource family — also the fallback `<KIND>` token in the env-var name
    /// (used only when a resource carries no declared object name). Family, not
    /// flow: DIRECTION expresses data flow. A `.write` `.otb` entry is a harvested
    /// output (an OTB shipped provider→caller — "an output is another OTB,
    /// inverted"); a `.write` `.attachment` entry is a summoned durable attachment.
    public enum Kind: String, Sendable {
        case attachment = "ATTACHMENT"
        case otb = "OTB"
        case fs = "FS"

        /// The lowercased family tag surfaced to the agent in `AgentResource.kind`
        /// (the env-var token, `rawValue`, stays uppercase).
        public var agentFamily: String { rawValue.lowercased() }
    }

    /// Mono-directional data flow for a manifest entry: a resource flows one way.
    /// An in-place (`.inputOutput`) FILE object is decomposed into a read entry +
    /// a write entry upstream (in `KeepTalkingIOManager.prepareCallBinding`), so
    /// it never reaches here; a read-write scratch DIRECTORY (the thread
    /// workspace / an ACP working root) projects to `.write` — it's the agent's
    /// own space to write into, read implied by the sandbox grant.
    public enum Direction: Sendable {
        case read
        case write

        public init(_ direction: KeepTalkingResourceDirection) {
            switch direction {
                case .input: self = .read
                case .output, .inputOutput: self = .write
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
        /// The declared SVO object name this resource binds to (e.g. "source",
        /// "result"). When present it drives the env-key token (`KT_<NAME>_<H8>`)
        /// so the agent references resources by their declared role rather than an
        /// opaque family tag. `nil` for catch-all context attachments that map to
        /// no declared object — those fall back to `KT_<KIND>_<H8>`.
        public let objectName: String?

        public init(
            kind: Kind,
            id: UUID,
            path: URL?,
            direction: Direction,
            displayName: String,
            isDirectory: Bool,
            objectName: String? = nil
        ) {
            self.kind = kind
            self.id = id
            self.path = path
            self.direction = direction
            self.displayName = displayName
            self.isDirectory = isDirectory
            self.objectName = objectName
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
        /// The declared object name, carried through from `Candidate` so the
        /// provider can correlate a harvested output file back to its declared
        /// `.output` slot.
        public let objectName: String?
    }

    public let entries: [Entry]
    /// The umbrella staging dir exposed as `$KT_ATTACHMENTS` (kept alongside the
    /// per-resource keys for scripts that read the whole dir).
    public let umbrellaAttachmentsDir: URL?

    public init(entries: [Entry], umbrellaAttachmentsDir: URL?) {
        self.entries = entries
        self.umbrellaAttachmentsDir = umbrellaAttachmentsDir
    }

    // MARK: - Canonical handle (agent token AND skill env-var key)

    /// The ONE canonical token for a resource — `KT_<KIND>_<HEX>` (FULL 32-hex id).
    /// This is BOTH the handle the orchestrating agent references AND the
    /// environment-variable key the skill sees as `$KT_<KIND>_<HEX>`: the build
    /// step assigns it verbatim to each manifest `Entry.envKey`, so the agent's
    /// handle and the skill's env var are literally identical for the same
    /// resource. Full hex (not a short suffix) makes it globally unique — no
    /// collision escalation — and exactly reversible via `parseAgentHandle`.
    public static func agentHandle(kind: Kind, id: UUID) -> String {
        let hex = id.uuidString.replacingOccurrences(of: "-", with: "").uppercased()
        return "KT_\(kind.rawValue)_\(hex)"
    }

    /// Inverts `agentHandle`: parses `KT_<KIND>_<HEX>` (a leading `$` tolerated)
    /// back to its family + concrete id. Returns nil for anything that isn't a
    /// well-formed KT handle (the caller then falls back to a bare-UUID parse).
    public static func parseAgentHandle(_ raw: String) -> (kind: Kind, id: UUID)? {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("$") { s.removeFirst() }
        guard s.hasPrefix("KT_") else { return nil }
        let body = String(s.dropFirst(3))  // "<TOKEN>_<HEX>"
        guard let underscore = body.lastIndex(of: "_") else { return nil }
        let token = String(body[..<underscore]).uppercased()
        let hex = String(body[body.index(after: underscore)...])
        guard let kind = Kind(rawValue: token), let id = uuidFromHex(hex) else {
            return nil
        }
        return (kind, id)
    }

    /// Reconstitutes a UUID from a 32-char dash-free hex string (the form
    /// `agentHandle` emits). Returns nil for any other shape.
    static func uuidFromHex(_ hex: String) -> UUID? {
        let h = hex.uppercased()
        guard h.count == 32, h.allSatisfy({ $0.isHexDigit }) else { return nil }
        let c = Array(h)
        let dashed =
            "\(String(c[0..<8]))-\(String(c[8..<12]))-\(String(c[12..<16]))-"
            + "\(String(c[16..<20]))-\(String(c[20..<32]))"
        return UUID(uuidString: dashed)
    }

    /// Resolves an agent-supplied resource handle to a concrete id, accepting BOTH
    /// the canonical `KT_<KIND>_<HEX>` form and a bare UUID (lenient ingest — the
    /// agent is always SHOWN KT handles, but a raw id still resolves). Returns the
    /// family when known (KT handles carry it; bare UUIDs don't).
    public static func resolveAgentHandle(_ raw: String) -> (kind: Kind?, id: UUID)? {
        if let parsed = parseAgentHandle(raw) { return (parsed.kind, parsed.id) }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let id = UUID(uuidString: trimmed) { return (nil, id) }
        return nil
    }

    // MARK: - Build

    /// Builds a manifest from already-granted candidates. Each entry's env key is
    /// the candidate's CANONICAL `agentHandle` (`KT_<KIND>_<HEX>`) — the same token
    /// the agent references, so the agent's handle and the skill's `$KT_…` env var
    /// are identical. Full-hex ids are globally unique, so no collision escalation
    /// is needed. Canonicalises every path once (so the env value, the prompt text,
    /// and the sandbox grant all agree on the /private/var form) and strips control
    /// characters from display names so a wire-controlled filename cannot forge
    /// prompt lines.
    public static func build(
        grantedCandidates: [Candidate],
        umbrellaAttachmentsDir: URL?
    ) -> KTResourceManifest {
        let entries = grantedCandidates.map { candidate in
            Entry(
                kind: candidate.kind,
                id: candidate.id,
                envKey: agentHandle(kind: candidate.kind, id: candidate.id),
                path: candidate.path?.resolvingSymlinksInPath().standardizedFileURL,
                direction: candidate.direction,
                displayName: sanitizedDisplayName(candidate.displayName),
                isDirectory: candidate.isDirectory,
                objectName: candidate.objectName
            )
        }
        return KTResourceManifest(
            entries: entries,
            umbrellaAttachmentsDir: umbrellaAttachmentsDir?
                .resolvingSymlinksInPath().standardizedFileURL
        )
    }

    private static func sanitizedDisplayName(_ name: String) -> String {
        // Strip BOTH control characters AND newlines: `.controlCharacters` omits
        // the Unicode line/paragraph separators U+2028/U+2029 (categories Zl/Zp),
        // which `.newlines` covers. A wire-controlled filename must not be able to
        // forge extra lines in the prompt block or the ACP system preamble.
        // ALSO strip the double-quote / backtick / dollar: promptBlock() renders the
        // name inside double-quotes, so an un-neutralised `"` would let a filename
        // close the field and append a same-line instruction the agent ingests as
        // trusted manifest text (single-line prompt injection); backtick/$ are
        // dropped too so a leaked name can't seed command substitution downstream.
        name
            .components(separatedBy: .controlCharacters).joined()
            .components(separatedBy: .newlines).joined()
            .components(separatedBy: CharacterSet(charactersIn: "\"`$")).joined()
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
            "- `read` items are inputs — do not modify them. `write` items accept changes; "
                + "place results you want returned at a `write` path and KeepTalking ships "
                + "them back.",
            "- For file outputs, write to the exact listed `write` variable. Do not create "
                + "an unlisted temp path and expect it to be returned.",
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

extension KTResourceManifest {
    /// The unified, path-free, Codable representation of a resource the
    /// orchestrating agent operates on — a context attachment, a produced action
    /// output, or any manifest resource. ONE vocabulary across the
    /// context-attachment listing and the action-output surfacing, so the model
    /// reasons about every resource the same way.
    ///
    /// IDENTITY is `handle` — the canonical `KT_<KIND>_<HEX>` token (see
    /// `agentHandle`), the SAME `KT_` shape a skill sees as a `$KT_…` env var,
    /// never a bare UUID and never a filesystem path. Filenames may repeat across
    /// resources and identical names are DISTINCT files; only the handle is
    /// canonical. This replaces the former standalone `KTAgentResource` so the
    /// manifest is the single source of the handle vocabulary.
    public struct AgentResource: Codable, Sendable, Equatable {
        /// `KT_<KIND>_<HEX>` — the canonical handle the agent references downstream.
        public var handle: String
        /// Resource family: "attachment" (durable, synced), "otb" (private,
        /// ephemeral), or "fs" (reached via filesystem operations).
        public var kind: String
        /// Mono data flow as the agent sees it: "read" (consumable) or "write".
        public var direction: String
        /// Filename / logical name.
        public var name: String
        public var mimeType: String?
        public var byteCount: Int?
        /// Short human description (attachment text preview / image description).
        public var summary: String?
        /// "context" (already present in the context) or "produced" (created by this call).
        public var origin: String

        public init(
            handle: String,
            kind: String,
            direction: String,
            name: String,
            mimeType: String? = nil,
            byteCount: Int? = nil,
            summary: String? = nil,
            origin: String
        ) {
            self.handle = handle
            self.kind = kind
            self.direction = direction
            self.name = name
            self.mimeType = mimeType
            self.byteCount = byteCount
            self.summary = summary
            self.origin = origin
        }

        /// Builds a resource from its concrete IDENTITY (`kind` + `id`), deriving
        /// the canonical `KT_<KIND>_<HEX>` handle — the only correct way to mint
        /// one, so the handle and the resource can never disagree.
        public init(
            kind: KTResourceManifest.Kind,
            id: UUID,
            direction: String,
            name: String,
            mimeType: String? = nil,
            byteCount: Int? = nil,
            summary: String? = nil,
            origin: String
        ) {
            self.init(
                handle: KTResourceManifest.agentHandle(kind: kind, id: id),
                kind: kind.agentFamily,
                direction: direction,
                name: name,
                mimeType: mimeType,
                byteCount: byteCount,
                summary: summary,
                origin: origin)
        }

        static func attachment(
            _ attachment: KeepTalkingContextAttachment,
            origin: String = "produced"
        ) -> Self {
            Self(
                kind: .attachment,
                id: attachment.id ?? UUID(),
                direction: "read",
                name: attachment.filename,
                mimeType: attachment.mimeType,
                byteCount: attachment.byteCount,
                summary: attachment.metadata.textPreview ?? attachment.metadata.imageDescription,
                origin: origin)
        }

        static func otb(
            id: UUID,
            name: String,
            mimeType: String?,
            byteCount: Int?,
            origin: String = "produced"
        ) -> Self {
            Self(
                kind: .otb,
                id: id,
                direction: "read",
                name: name,
                mimeType: mimeType,
                byteCount: byteCount,
                origin: origin)
        }

        static func otb(_ ref: KeepTalkingOneTimeBlobRef) -> Self {
            otb(
                id: ref.transferID,
                name: ref.filename,
                mimeType: ref.mimeType,
                byteCount: ref.byteCount)
        }

        /// The canonical JSON object embedded in agent-facing tool payloads.
        public func jsonObject() -> [String: Any] {
            var obj: [String: Any] = [
                "handle": handle,
                "kind": kind,
                "direction": direction,
                "name": name,
                "origin": origin,
            ]
            if let mimeType { obj["mime_type"] = mimeType }
            if let byteCount { obj["byte_count"] = byteCount }
            if let summary, !summary.isEmpty { obj["description"] = summary }
            return obj
        }

        /// Reconstructs a resource from its `jsonObject()` form (e.g. a
        /// `produced_resources` entry parsed back out of a tool payload).
        public init?(jsonObject: [String: Any]) {
            guard let handle = jsonObject["handle"] as? String,
                let kind = jsonObject["kind"] as? String,
                let name = jsonObject["name"] as? String
            else { return nil }
            self.handle = handle
            self.kind = kind
            self.direction = jsonObject["direction"] as? String ?? "read"
            self.name = name
            self.mimeType = jsonObject["mime_type"] as? String
            self.byteCount = jsonObject["byte_count"] as? Int
            self.summary = jsonObject["description"] as? String
            self.origin = jsonObject["origin"] as? String ?? "produced"
        }

        /// A one-line, agent-facing description carrying the resource's IDENTITY —
        /// provided to the transcript alongside any injected content so the model
        /// references the resource by `handle` (filenames may repeat; the handle is
        /// the identity).
        public func transcriptDescription() -> String {
            var fields = [
                "handle=\(handle)",
                "kind=\(kind)",
                "name=\"\(name)\"",
                "access=\(direction)",
                origin,
            ]
            if let byteCount { fields.append("\(byteCount) bytes") }
            return "resource(" + fields.joined(separator: ", ") + ")"
        }

        public var injectedContentLeadText: String {
            "[\(transcriptDescription())] — produced content is injected below. "
                + "This is the file's full content; do NOT call any tool (attachment tools, kt_send_file, etc.) to fetch it. "
                + "Reference it by its handle, or pass the handle in input_handles to a later kt_run_action:"
        }
    }
}
