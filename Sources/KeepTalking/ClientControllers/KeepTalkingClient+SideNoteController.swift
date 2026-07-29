import FluentKit
import Foundation

/// The single write path for side notes.
///
/// Every writer goes through here — the two LLM tool executors in the SDK and
/// the three app views that previously mutated rows through raw Fluent. That
/// centralisation is the whole point: the version counter has to be allocated
/// inside the same transaction as the write, and a bump left to call sites is a
/// bump that one of five callers eventually forgets. A forgotten bump does not
/// fail loudly; it silently loses the next merge.
extension KeepTalkingClient {

    /// Trimmed, and normalized to a single Unicode form.
    ///
    /// Swift compares strings by canonical equivalence; the unique index on
    /// `(context, key)` compares bytes. Without normalizing, "café" typed as
    /// precomposed and as `e` + combining acute are one key to every lookup in
    /// this file and two rows to SQLite — so the insert succeeds, the context
    /// holds a duplicate key, and the merge's `Dictionary(uniquingKeysWith:)`
    /// silently drops one of them. Normalizing on the way in keeps the two
    /// notions of equality agreeing.
    static func normalizedSideNoteKey(_ key: String) -> String {
        key
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .precomposedStringWithCanonicalMapping
    }

    // MARK: - Writes

    /// Creates or updates a note by `(context, key)`, allocating the next
    /// version and pushing the change to peers.
    @discardableResult
    public func upsertSideNote(
        key: String,
        value: String,
        in contextID: UUID
    ) async throws -> KeepTalkingSideNoteDTO {
        let trimmedKey = Self.normalizedSideNoteKey(key)
        guard !trimmedKey.isEmpty else {
            throw KeepTalkingClientError.invalidSideNote("key must not be empty")
        }
        // Sync sends the whole set at once, so every write has to keep that set
        // inside the transport budget. Refusing here is what makes the budget
        // unreachable — the alternative is a write that succeeds locally and
        // then silently stops the context's side notes from syncing at all.
        guard trimmedKey.utf8.count <= KeepTalkingSideNoteLimits.maximumKeyBytes else {
            throw KeepTalkingClientError.invalidSideNote(
                "key is \(trimmedKey.utf8.count) bytes, over the \(KeepTalkingSideNoteLimits.maximumKeyBytes)-byte limit"
            )
        }
        guard value.utf8.count <= KeepTalkingSideNoteLimits.maximumValueBytes else {
            throw KeepTalkingClientError.invalidSideNote(
                "value is \(value.utf8.count) bytes, over the \(KeepTalkingSideNoteLimits.maximumValueBytes)-byte limit"
            )
        }
        try await assertLiveNoteCapacity(for: trimmedKey, in: contextID)

        let dto = try await writeSideNote(
            key: trimmedKey,
            value: value,
            isArchived: false,
            in: contextID
        )
        await publishSideNoteChange(dto, in: contextID)
        return dto
    }

    /// Refuses a new live note once the context is full. Updating a note that
    /// already exists — including reviving a tombstone — is always allowed,
    /// since neither grows the live set.
    private func assertLiveNoteCapacity(
        for key: String,
        in contextID: UUID
    ) async throws {
        let existing = try await KeepTalkingSideNote.query(on: localStore.database)
            .filter(\.$context.$id == contextID)
            .filter(\.$key == key)
            .first()
        guard existing == nil || existing?.isArchived == true else { return }

        let liveCount = try await KeepTalkingSideNote.query(on: localStore.database)
            .filter(\.$context.$id == contextID)
            .filter(\.$isArchived == false)
            .count()
        // Reviving a tombstone replaces a dead row with a live one, so it needs
        // the same headroom a brand-new key does.
        guard liveCount < KeepTalkingSideNoteLimits.maximumLiveNotes else {
            throw KeepTalkingClientError.invalidSideNote(
                "context already holds \(liveCount) notes, the maximum is \(KeepTalkingSideNoteLimits.maximumLiveNotes); archive one first"
            )
        }
    }

    /// Archives a note. The row survives as a tombstone — it keeps its key and
    /// version so peers can tell "deleted" from "never seen", and both readers
    /// already filter archived notes out of the prompt.
    @discardableResult
    public func archiveSideNote(
        key: String,
        in contextID: UUID
    ) async throws -> KeepTalkingSideNoteDTO? {
        // Normalized on the same terms as `upsertSideNote`, which is what stored
        // the row: without this, archiving " todo" finds nothing and silently
        // no-ops against a note the user can plainly see.
        let trimmedKey = Self.normalizedSideNoteKey(key)
        let existing = try await KeepTalkingSideNote.query(on: localStore.database)
            .filter(\.$context.$id == contextID)
            .filter(\.$key == trimmedKey)
            .first()
        guard existing != nil else { return nil }
        let dto = try await writeSideNote(
            key: trimmedKey,
            value: "",
            isArchived: true,
            in: contextID
        )
        try await pruneTombstones(in: contextID)
        await publishSideNoteChange(dto, in: contextID)
        return dto
    }

    /// Deletes the oldest tombstones once a context holds more than
    /// `maximumTombstones`.
    ///
    /// Tombstones are what let a peer tell "deleted" from "never seen", so they
    /// have to outlive the delete — but not forever. Kept forever they are a
    /// monotonically growing share of a fixed transport budget, and the context
    /// eventually cannot sync side notes at all. Oldest-first by version
    /// counter, which is the context's write order.
    private func pruneTombstones(in contextID: UUID) async throws {
        let tombstones = try await KeepTalkingSideNote.query(on: localStore.database)
            .filter(\.$context.$id == contextID)
            .filter(\.$isArchived == true)
            .sort(\.$versionCounter, .descending)
            .all()
        guard tombstones.count > KeepTalkingSideNoteLimits.maximumTombstones else {
            return
        }
        let expired = tombstones.dropFirst(
            KeepTalkingSideNoteLimits.maximumTombstones
        )
        for tombstone in expired {
            try await tombstone.delete(on: localStore.database)
        }
        onLog?(
            "[side-note] pruned \(expired.count) tombstone(s) in context=\(contextID.uuidString.lowercased()) to stay inside the sync budget"
        )
    }

    /// Allocates the counter and writes the row in one transaction, so two
    /// concurrent local writes cannot land on the same counter.
    private func writeSideNote(
        key: String,
        value: String,
        isArchived: Bool,
        in contextID: UUID
    ) async throws -> KeepTalkingSideNoteDTO {
        let writer = config.node
        return try await localStore.database.transaction { db in
            let maximum =
                try await KeepTalkingSideNote.query(on: db)
                .filter(\.$context.$id == contextID)
                .max(\.$versionCounter) ?? 0

            if let existing = try await KeepTalkingSideNote.query(on: db)
                .filter(\.$context.$id == contextID)
                .filter(\.$key == key)
                .first()
            {
                existing.value = value
                existing.isArchived = isArchived
                existing.versionCounter = maximum + 1
                existing.versionWriter = writer
                try await existing.save(on: db)
                return KeepTalkingSideNoteDTO(existing)
            }

            let note = KeepTalkingSideNote(
                contextID: contextID,
                key: key,
                value: value,
                isArchived: isArchived,
                versionCounter: maximum + 1,
                versionWriter: writer
            )
            try await note.save(on: db)
            return KeepTalkingSideNoteDTO(note)
        }
    }

    // MARK: - Reads

    /// Every note in the context, tombstones included, ordered by key.
    /// Tombstones are part of the synced set — see `KeepTalkingSideNoteDigest`.
    func allSideNoteDTOs(in contextID: UUID) async throws
        -> [KeepTalkingSideNoteDTO]
    {
        try await KeepTalkingSideNote.query(on: localStore.database)
            .filter(\.$context.$id == contextID)
            .all()
            .map(KeepTalkingSideNoteDTO.init)
            .sorted { $0.key < $1.key }
    }

    func sideNoteDigest(in contextID: UUID) async throws -> Data {
        KeepTalkingSideNoteDigest.digest(of: try await allSideNoteDTOs(in: contextID))
    }

    // MARK: - Merge

    /// Merges an incoming set by `(context, key)`, taking a note only when its
    /// version is strictly greater. Returns whether anything changed.
    ///
    /// No delete-and-recreate: the row id is local and stays local. The old
    /// merge adopted the sender's id on a losing comparison, which meant a
    /// merge could change a row's primary key.
    @discardableResult
    func mergeSideNotes(
        _ incoming: [KeepTalkingSideNoteDTO],
        contextID: UUID
    ) async throws -> Bool {
        guard !incoming.isEmpty else { return false }

        let changed = try await applyMergedSideNotes(incoming, contextID: contextID)
        if changed {
            // Prune here as well as on archive, by the same deterministic rule.
            // Pruning changes the digest, so a node that only pruned its own
            // archives would disagree forever with one that learned those
            // tombstones by sync: it would re-adopt the very rows the other had
            // dropped. Applying the rule after every change means both sides
            // reduce the same merged set to the same retained tombstones.
            try await pruneTombstones(in: contextID)
        }
        return changed
    }

    private func applyMergedSideNotes(
        _ incoming: [KeepTalkingSideNoteDTO],
        contextID: UUID
    ) async throws -> Bool {
        try await localStore.database.transaction { db -> Bool in
            var changed = false
            let existing = try await KeepTalkingSideNote.query(on: db)
                .filter(\.$context.$id == contextID)
                .all()
            let byKey = Dictionary(
                existing.map { ($0.key, $0) },
                uniquingKeysWith: { first, _ in first }
            )

            for dto in incoming {
                if let local = byKey[dto.key] {
                    guard dto.version > local.version else { continue }
                    local.value = dto.value ?? ""
                    local.isArchived = dto.isArchived
                    local.versionCounter = dto.versionCounter
                    local.versionWriter = dto.versionWriter
                    try await local.save(on: db)
                    changed = true
                } else {
                    let note = KeepTalkingSideNote(
                        contextID: contextID,
                        key: dto.key,
                        value: dto.value ?? "",
                        isArchived: dto.isArchived,
                        versionCounter: dto.versionCounter,
                        versionWriter: dto.versionWriter
                    )
                    try await note.save(on: db)
                    changed = true
                }
            }
            return changed
        }
    }

    // MARK: - Propagation

    /// Fire-and-forget push of one changed note, plus the local change notice.
    ///
    /// Events drive propagation; the maintenance heartbeat's digest compare is
    /// the fallback that catches whatever a push missed.
    private func publishSideNoteChange(
        _ dto: KeepTalkingSideNoteDTO,
        in contextID: UUID
    ) async {
        try? rtcClient.sendEnvelope(
            KeepTalkingContextSyncEnvelope.sideNotesPush(
                KeepTalkingContextSyncSideNotesPush(
                    context: contextID,
                    origin: config.node,
                    sideNotes: [dto]
                )
            )
        )
        await notifySideNotesChanged(contextID)
    }

    func notifySideNotesChanged(_ contextID: UUID) async {
        await onSideNotesChanged?(contextID)
    }
}
