import Foundation
import MCP

extension KeepTalkingClient {

    /// A resolved file input the caller has already staged locally for this run.
    public struct StagedInputResource: Sendable {
        public let id: UUID
        public let path: URL
        public let displayName: String

        public init(id: UUID, path: URL, displayName: String) {
            self.id = id
            self.path = path
            self.displayName = displayName
        }
    }

    /// Binds an action's declared SVO objects to the concrete resources resolved
    /// for ONE run — the bridge from the declared "O" (`KeepTalkingActionObject`)
    /// to the resolved `KTResourceManifest`. Pure, deterministic, provider-only.
    ///
    /// REGRESSION INVARIANT: when the descriptor declares no file objects
    /// (`descriptor.objects` nil/empty — every skill today), every input keeps a
    /// `nil` objectName, so the manifest falls back to `KT_ATTACHMENT_<H8>` /
    /// `KT_OTB_<H8>` exactly as before, and no output slots are allocated. The
    /// declared-object machinery only engages once an action opts in.
    ///
    /// - Parameters:
    ///   - attachments: Context attachments staged read-only into `$KT_ATTACHMENTS`
    ///     — always catch-all inputs (never bound to a declared object).
    ///   - otbInputs: One-time-blob file inputs the caller relayed, keyed by the
    ///     handle the call referenced; these bind to declared `.input` objects.
    ///   - attachmentsDir: The umbrella staging dir, granted read-only.
    ///   - workspaceDir: The thread workspace, granted read-write — where `.output`
    ///     slots are allocated. When `nil`, no outputs can be produced.
    func prepareCallBinding(
        action: KeepTalkingAction,
        call: KeepTalkingActionCall,
        attachments: [StagedInputResource],
        otbInputs: [(handle: UUID, url: URL)],
        attachmentsDir: URL?,
        workspaceDir: URL?
    ) -> KTCallBinding {
        let descriptor = action.descriptor
        // Pure-input file objects bind to relayed OTB inputs. `.inputOutput`
        // objects are handled as writable output slots below (one path, not two).
        let pureInputs = (descriptor?.objects ?? []).filter {
            $0.isFile && $0.direction == .input
        }
        let outputObjects = descriptor?.fileObjects(direction: .output) ?? []

        var inputs: [KTCallBinding.BoundObject] = []

        // Context attachments — catch-all, never bound to a declared object.
        for attachment in attachments {
            inputs.append(
                KTCallBinding.BoundObject(
                    objectName: nil,
                    id: attachment.id,
                    kind: .attachment,
                    path: attachment.path,
                    direction: .input,
                    displayName: attachment.displayName,
                    isDirectory: false))
        }

        // OTB inputs → declared `.input` objects. Pass 1: explicit argument match
        // (the call argument named after the object references this handle).
        // Pass 2: positional fill of any still-unbound declared input, in order.
        var boundName: [String?] = Array(repeating: nil, count: otbInputs.count)
        var consumed = Set<Int>()
        for (i, input) in otbInputs.enumerated() {
            let handle = input.handle.uuidString.lowercased()
            for j in pureInputs.indices where !consumed.contains(j) {
                guard let name = pureInputs[j].name else { continue }
                if call.arguments[name]?.stringValue?.lowercased() == handle {
                    boundName[i] = name
                    consumed.insert(j)
                    break
                }
            }
        }
        for i in otbInputs.indices where boundName[i] == nil {
            if let j = pureInputs.indices.first(where: {
                !consumed.contains($0) && pureInputs[$0].name != nil
            }) {
                boundName[i] = pureInputs[j].name
                consumed.insert(j)
            }
        }
        for (i, input) in otbInputs.enumerated() {
            inputs.append(
                KTCallBinding.BoundObject(
                    objectName: boundName[i],
                    id: input.handle,
                    kind: .otb,
                    path: input.url,
                    direction: .input,
                    displayName: input.url.lastPathComponent,
                    isDirectory: false))
        }

        // `.output` / `.inputOutput` objects → write slots under the workspace.
        var outputs: [KTCallBinding.BoundObject] = []
        if let workspaceDir {
            var usedNames = Set<String>()
            for (index, object) in outputObjects.enumerated() {
                let base =
                    object.name.flatMap(Self.sanitizeFileComponent)
                    ?? "output-\(index + 1)"
                var fileName = base
                var disambiguator = 2
                while usedNames.contains(fileName) {
                    fileName = "\(base)-\(disambiguator)"
                    disambiguator += 1
                }
                usedNames.insert(fileName)
                let direction: KeepTalkingResourceDirection =
                    object.direction == .inputOutput ? .inputOutput : .output
                outputs.append(
                    KTCallBinding.BoundObject(
                        objectName: object.name,
                        id: UUID.v7(),
                        kind: .output,
                        path: workspaceDir.appendingPathComponent(
                            fileName, isDirectory: false),
                        direction: direction,
                        displayName: object.name ?? fileName,
                        isDirectory: false))
            }
        }

        var grantedDirectories: [String: KTCallBinding.GrantedDirectory] = [:]
        if let attachmentsDir {
            grantedDirectories["KT_ATTACHMENTS"] =
                KTCallBinding.GrantedDirectory(url: attachmentsDir, direction: .input)
        }
        if let workspaceDir {
            grantedDirectories["KT_WORKSPACE"] =
                KTCallBinding.GrantedDirectory(
                    url: workspaceDir, direction: .inputOutput)
        }

        return KTCallBinding(
            inputs: inputs, outputs: outputs, grantedDirectories: grantedDirectories)
    }

    /// After a run, stream any file present at a declared `.output` slot back to
    /// the caller as a one-time blob. Returns the refs to attach to the result.
    /// Caller MUST gate on a remote caller and on the output slots actually being
    /// granted — a slot whose workspace grant was dropped points at an ungranted
    /// path the script never reached, so it stays empty and is silently skipped.
    func harvestCallOutputs(
        _ outputs: [KTCallBinding.BoundObject],
        to recipientNodeID: UUID
    ) async -> [KeepTalkingOneTimeBlobRef] {
        var refs: [KeepTalkingOneTimeBlobRef] = []
        let fileManager = FileManager.default
        for output in outputs {
            var isDirectory: ObjCBool = false
            guard
                fileManager.fileExists(
                    atPath: output.path.path, isDirectory: &isDirectory),
                !isDirectory.boolValue
            else { continue }
            let ext = output.path.pathExtension
            let mimeType =
                ext.isEmpty
                ? "application/octet-stream"
                : (MIMEType.preferredMIMEType(forExtension: ext)
                    ?? "application/octet-stream")
            if let ref = try? await sendOneTimeBlob(
                fileURL: output.path,
                filename: output.path.lastPathComponent,
                mimeType: mimeType,
                to: recipientNodeID)
            {
                refs.append(ref)
            }
        }
        return refs
    }

    /// Folds a declared object name into a safe single path component: control
    /// chars and newlines stripped, path separators neutralised, `.`/`..` rejected.
    /// Returns `nil` when nothing usable survives (caller falls back to a generic
    /// slot name) — a declared name can never escape the workspace dir.
    static func sanitizeFileComponent(_ name: String) -> String? {
        let cleaned =
            name
            .components(separatedBy: .controlCharacters).joined()
            .components(separatedBy: .newlines).joined()
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "\\", with: "_")
            .trimmingCharacters(in: .whitespaces)
        if cleaned.isEmpty || cleaned == "." || cleaned == ".." { return nil }
        return cleaned
    }
}
