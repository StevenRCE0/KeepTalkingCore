import Foundation

/// The path-free, device-side projection of ONE declared SVO object — what the
/// MAIN / orchestration agent sees so it can plan data flow BETWEEN actions
/// without ever learning a provider-side path. Rendered from
/// `KeepTalkingActionObject` (name + direction + description) with the concrete
/// resource/path stripped by construction — that strip is the safety of the
/// two-view split (a compromised orchestrator prompt can't name a provider path
/// because none is rendered device-side).
public struct KeepTalkingObjectContract: Codable, Sendable {
    /// The call-argument name, verbatim (planner → run round-trip fidelity).
    public var name: String
    public var direction: KeepTalkingResourceDirection
    public var description: String
    public var isFile: Bool

    public init(
        name: String,
        direction: KeepTalkingResourceDirection,
        description: String,
        isFile: Bool
    ) {
        self.name = name
        self.direction = direction
        self.description = description
        self.isFile = isFile
    }
}

/// The result of binding an action's declared objects to CONCRETE resources at
/// call time, on the PROVIDER, for ONE run — the bridge from the declared SVO
/// "O" (`KeepTalkingActionObject`) to the resolved `KTResourceManifest`. Built by
/// `prepareCallBinding(...)` between staging and executor invocation, replacing
/// the ad-hoc positional candidate loop.
///
/// Lives ONLY on the provider for the duration of the run and never crosses the
/// wire — remote callers see `KeepTalkingObjectContract`, never these paths.
public struct KTCallBinding: Sendable {

    /// A declared object resolved to a concrete local path for this run.
    public struct BoundObject: Sendable {
        /// The declared object's name (e.g. "source", "result"); `nil` for the
        /// catch-all context-attachment inputs that map to no declared object.
        public var objectName: String?
        /// Resource provenance — the attachment id, OTB handle, or a minted slot
        /// id for outputs. Carried so a BoundObject maps 1:1 to a manifest
        /// `Candidate` (its `id` + `kind`) with no lost distinction, and so a
        /// harvested output correlates back to its slot.
        public var id: UUID
        public var kind: KTResourceManifest.Kind
        public var path: URL
        public var direction: KeepTalkingResourceDirection
        /// Sanitized, control-char-stripped name surfaced in the prompt.
        public var displayName: String
        public var isDirectory: Bool

        public init(
            objectName: String?,
            id: UUID,
            kind: KTResourceManifest.Kind,
            path: URL,
            direction: KeepTalkingResourceDirection,
            displayName: String,
            isDirectory: Bool
        ) {
            self.objectName = objectName
            self.id = id
            self.kind = kind
            self.path = path
            self.direction = direction
            self.displayName = displayName
            self.isDirectory = isDirectory
        }

        /// The manifest candidate this resolved object contributes.
        public var manifestCandidate: KTResourceManifest.Candidate {
            KTResourceManifest.Candidate(
                kind: kind,
                id: id,
                path: path,
                direction: KTResourceManifest.Direction(direction),
                displayName: displayName,
                isDirectory: isDirectory,
                objectName: objectName
            )
        }
    }

    /// A directory to grant in the sandbox policy with a specific direction.
    public struct GrantedDirectory: Sendable {
        public var url: URL
        public var direction: KeepTalkingResourceDirection

        public init(url: URL, direction: KeepTalkingResourceDirection) {
            self.url = url
            self.direction = direction
        }
    }

    /// Resolved INPUT resources (granted, staged local paths). Fail-closed: only
    /// resources whose path the sandbox actually granted appear here.
    public var inputs: [BoundObject]

    /// Allocated OUTPUT slots under the thread workspace; any file present at one
    /// of these paths after the run is harvested back as a one-time-blob output.
    public var outputs: [BoundObject]

    /// Object-named directories to grant in the sandbox policy
    /// (label → (url, direction)) — replaces the hardcoded
    /// `["KT_ATTACHMENTS": …]`; the `$KT_ATTACHMENTS` umbrella stays as one entry.
    public var grantedDirectories: [String: GrantedDirectory]

    public init(
        inputs: [BoundObject],
        outputs: [BoundObject],
        grantedDirectories: [String: GrantedDirectory]
    ) {
        self.inputs = inputs
        self.outputs = outputs
        self.grantedDirectories = grantedDirectories
    }
}
