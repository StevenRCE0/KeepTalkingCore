#if os(macOS)
import FluentKit
import Foundation

/// A per-call directory holding the context's ready attachments, named with
/// their real filenames, ready to be granted read access and handed to a skill
/// script. Backed by hardlinks where possible, so the content-addressed blobs
/// are never copied or mutated.
struct KeepTalkingStagedAttachments {
    /// Canonical (symlink-resolved) directory path, so it matches the granted
    /// seatbelt subpath and what the kernel resolves at access time.
    let directory: URL
    let files: [(id: UUID, filename: String, path: String)]
}

extension KeepTalkingClient {

    /// Materializes the `.ready` attachments of `contextID` into a fresh per-call
    /// scratch directory under the writable temp root, named with their real
    /// (sanitized, collision-disambiguated) filenames. Returns nil when there's
    /// nothing stageable. Skips attachments whose bytes aren't present locally —
    /// partial availability degrades gracefully rather than failing the skill.
    /// Never mutates the content-addressed originals.
    func stageContextAttachments(in contextID: UUID) async -> KeepTalkingStagedAttachments? {
        guard let attachments = try? await contextAttachments(in: contextID),
            !attachments.isEmpty,
            let records = try? await blobRecordsByBlobID(attachments.map(\.blobID))
        else { return nil }

        // Stage under the same temp root the seatbelt baseline grants, then
        // resolve symlinks so the path we grant is canonical.
        let tempRoot = DefaultProcessExecutionSupport.resolveWritableTempDirectory(
            environment: ProcessInfo.processInfo.environment
        )
        let scratch = URL(fileURLWithPath: tempRoot, isDirectory: true)
            .appendingPathComponent(
                "kt-attach-\(UUID().uuidString.lowercased())", isDirectory: true)
        let fileManager = FileManager.default
        guard
            (try? fileManager.createDirectory(
                at: scratch, withIntermediateDirectories: true)) != nil
        else { return nil }
        let canonical = scratch.resolvingSymlinksInPath()

        var staged: [(id: UUID, filename: String, path: String)] = []
        var usedNames = Set<String>()
        for (index, attachment) in attachments.enumerated() {
            guard let record = records[attachment.blobID],
                record.availability == .ready,
                let relativePath = record.relativePath
            else { continue }
            let source = blobStore.fileURL(forRelativePath: relativePath)
            guard fileManager.fileExists(atPath: source.path) else { continue }

            let base = sanitizedAttachmentFilename(attachment.filename, index: index)
            let name = usedNames.contains(base) ? "\(index)_\(base)" : base
            usedNames.insert(name)
            let destination = canonical.appendingPathComponent(name, isDirectory: false)

            // Hardlink (instant, no extra bytes) when on the same volume; fall
            // back to a copy across devices. The original blob is untouched.
            do {
                try fileManager.linkItem(at: source, to: destination)
            } catch {
                guard (try? fileManager.copyItem(at: source, to: destination)) != nil
                else { continue }
            }
            staged.append((id: attachment.id ?? UUID(), filename: name, path: destination.path))
        }

        guard !staged.isEmpty else {
            try? fileManager.removeItem(at: canonical)
            return nil
        }
        return KeepTalkingStagedAttachments(directory: canonical, files: staged)
    }

    func cleanupStagedAttachments(_ staged: KeepTalkingStagedAttachments) {
        try? FileManager.default.removeItem(at: staged.directory)
    }

    /// Strips path separators and traversal from a remote-controlled filename so
    /// it can't escape the scratch dir.
    private func sanitizedAttachmentFilename(_ filename: String, index: Int) -> String {
        let base = (filename as NSString).lastPathComponent
            .replacingOccurrences(of: "/", with: "_")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if base.isEmpty || base == "." || base == ".." {
            return "attachment_\(index)"
        }
        return base
    }
}
#endif
