import Dispatch
import FluentKit
import FluentSQLiteDriver
import Foundation
import Logging
import NIOConcurrencyHelpers
import SQLKit

/// How a file store journals writes.
///
/// There is no way back to the rollback journal on purpose: leaving WAL needs
/// every other connection to the file closed — the extensions included — and
/// SQLite's busy handler here retries forever, so a store that tried would
/// spin rather than fail.
public enum KeepTalkingStoreJournal: Sendable, Equatable {
    /// Write-ahead logging: readers and the writer stop blocking each other,
    /// across this process's connections and the extensions' too. Set once;
    /// it persists in the file.
    case wal
    /// Leave the file's journal mode as it is.
    case unchanged

    /// WAL everywhere but iOS. There, a WAL connection keeps a shared lock on
    /// the `-shm` file while idle — a lock in the App Group container that
    /// `KeepTalkingDatabaseActivity` cannot see and the host cannot hold a
    /// suspension assertion for — and whether the system kills for it is
    /// unverified.
    public static var platformDefault: Self {
        #if os(iOS)
        .unchanged
        #else
        .wal
        #endif
    }
}

public final class KeepTalkingModelStore: KeepTalkingLocalStore,
    @unchecked Sendable
{
    public let databaseURL: URL
    public let journal: KeepTalkingStoreJournal

    private let manager: FluentManager
    private let databaseID: DatabaseID
    private let logger: Logger
    /// Guards against shutting the manager down twice — once explicitly and
    /// again from `deinit`.
    private let hasShutDown = NIOLockedValueBox(false)

    /// Construction is synchronous and does NO I/O — it registers databases,
    /// middleware and the migration list. Running the migrations is separate
    /// (`migrate()`) because it is async work.
    ///
    /// Keeping the two apart is deliberate. When construction *also* ran the
    /// migrations, callers who could not await had to bridge with a semaphore,
    /// and that bridge deadlocks in two different ways: under parallel tests the
    /// whole cooperative pool fills with waiters, and in the app the bridged
    /// work can hop to the main actor that is already blocked waiting for it.
    /// A synchronous init means neither caller has to bridge anything.
    ///
    /// Use `make(...)` when you are already in an async context.
    public init(
        databaseURL: URL? = nil,
        databaseFileName: String? = nil,
        databaseID: DatabaseID = .sqlite,
        journal: KeepTalkingStoreJournal = .platformDefault,
        gate: KeepTalkingDatabaseGateConfiguration = .automatic,
        logger: Logger = .init(label: "KeepTalking.ModelStore")
    ) throws {
        self.databaseURL = databaseURL ?? Self.defaultDatabaseURL(for: databaseFileName)
        self.databaseID = databaseID
        self.journal = journal
        self.logger = logger
        self.manager = FluentManager(
            gate: gate,
            logger: .init(label: "KeepTalking.FluentManager")
        )

        do {
            try Self.prepareDatabaseDirectory(at: self.databaseURL)
            Self.configure(
                manager: manager,
                databaseID: databaseID,
                sqliteConfiguration: .file(self.databaseURL.path)
            )
        } catch {
            self.manager.shutdown()
            throw error
        }
    }

    /// Constructs and migrates in one step, for callers already in an async
    /// context.
    public static func make(
        databaseURL: URL? = nil,
        databaseFileName: String? = nil,
        databaseID: DatabaseID = .sqlite,
        journal: KeepTalkingStoreJournal = .platformDefault,
        gate: KeepTalkingDatabaseGateConfiguration = .automatic,
        logger: Logger = .init(label: "KeepTalking.ModelStore")
    ) async throws -> KeepTalkingModelStore {
        let store = try KeepTalkingModelStore(
            databaseURL: databaseURL,
            databaseFileName: databaseFileName,
            databaseID: databaseID,
            journal: journal,
            gate: gate,
            logger: logger
        )
        try await store.migrate()
        return store
    }

    /// Applies any outstanding migrations. Must complete before the store is
    /// queried.
    public func migrate() async throws {
        try await ensureJournal()
        try await manager.autoMigrate()
        let logger = self.logger
        try await KeepTalkingUndecodableActionSweep.run(on: database) {
            logger.notice("\($0)")
        }
    }

    /// The file's current journal mode, as SQLite reports it (`wal`, `delete`, …).
    public func journalMode() async throws -> String {
        guard let sql = database as? any SQLDatabase else {
            throw KeepTalkingStoreError.notSQL
        }
        return try await Self.journalMode(on: sql)
    }

    /// Switches the file to WAL when asked to and it is not already — once;
    /// the mode persists in the file, so reopening finds it set.
    private func ensureJournal() async throws {
        guard journal == .wal, let sql = database as? any SQLDatabase else { return }
        let current = try await Self.journalMode(on: sql)
        guard current != "wal" else { return }
        let requested = "wal"
        let actual = try await Self.journalMode(on: sql, setting: requested)
        guard actual == requested else {
            throw KeepTalkingStoreError.journalModeRefused(requested: requested, actual: actual)
        }
        logger.notice("journal mode \(current) → \(actual) for \(databaseURL.lastPathComponent)")
    }

    private static func journalMode(
        on sql: any SQLDatabase,
        setting mode: String? = nil
    ) async throws -> String {
        // The pragma answers with one row either way; the value is an
        // identifier, never a bind parameter.
        let statement: SQLQueryString =
            mode.map { "PRAGMA journal_mode = \(unsafeRaw: $0)" } ?? "PRAGMA journal_mode"
        guard let row = try await sql.raw(statement).first() else {
            throw KeepTalkingStoreError.journalModeRefused(requested: mode ?? "", actual: "")
        }
        return try row.decode(column: "journal_mode", as: String.self).lowercased()
    }

    /// Drains in-flight queries and releases the event-loop group.
    ///
    /// Prefer this over just dropping the store when you know it is being
    /// retired while the process keeps running: `deinit`'s teardown races any
    /// query still in flight, and NIO traps on the resulting
    /// `EventLoopFuture.deinit`. Awaiting here lets the pool drain first.
    public func shutdown() async {
        guard
            !hasShutDown.withLockedValue({ was in
                defer { was = true }
                return was
            })
        else { return }
        await manager.shutdown()
    }

    deinit {
        // `shutdown()` blocks until the NIO event-loop group has terminated.
        // Running it inline parks whatever thread released the store — and
        // under parallel tests that is a cooperative thread, so releasing a
        // batch of stores starves the pool exactly the way `blocking {}` used
        // to. `deinit` cannot be async, so hand the wait to a utility queue and
        // return immediately. The manager is captured by value; `self` is not.
        guard
            !hasShutDown.withLockedValue({ was in
                defer { was = true }
                return was
            })
        else { return }
        let manager = self.manager
        DispatchQueue.global(qos: .utility).async {
            manager.shutdown()
        }
    }

    public var database: any Database {
        self.manager.db(self.databaseID, logger: self.logger)
    }

    public func reset() async throws {
        try await self.manager.autoRevert()
        try await self.manager.autoMigrate()
    }

    private static func defaultDatabaseURL(for fileName: String? = nil) -> URL {
        let fm = FileManager.default
        let baseDir =
            fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first
            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        return
            baseDir
            .appendingPathComponent("KeepTalking", isDirectory: true)
            .appendingPathComponent("\(fileName ?? "state").sqlite", isDirectory: false)
    }

    private static func prepareDatabaseDirectory(at databaseURL: URL) throws {
        let directory = databaseURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
    }

    fileprivate static func configure(
        manager: FluentManager,
        databaseID: DatabaseID,
        sqliteConfiguration: SQLiteConfiguration
    ) {
        manager.databases.use(
            .sqlite(sqliteConfiguration),
            as: databaseID,
            isDefault: true
        )
        // Bump a context's `updatedAt` on single-write child saves. The batched
        // sync path bulk-inserts (bypassing middleware) and touches the context
        // itself, so these don't double-fire. See ContextTouchMiddleware.
        manager.databases.middleware.use(
            ContextMessageTouchMiddleware(),
            on: databaseID
        )
        manager.databases.middleware.use(
            ContextAttachmentTouchMiddleware(),
            on: databaseID
        )
        manager.migrations.add(
            CreateKeepTalkingNodesMigration(),
            CreateKeepTalkingActionsMigration(),
            CreateKeepTalkingNodeRelationsMigration(),
            CreateNodeIdentityKeysMigration(),
            CreateNodeRelationsActionsRelationsMigration(),
            CreateKeepTalkingContextsMigration(),
            CreateKeepTalkingThreadsMigration(),
            AddThreadSemanticDocumentDigestMigration(),
            CreateKeepTalkingThreadWorkspacesMigration(),
            CreateKeepTalkingMappingsMigration(),
            AddKeepTalkingMappingActionMigration(),
            CreateNodeRelationsAliasesRelationsMigration(),
            CreateKeepTalkingOperatorContextsMigration(),
            CreateKeepTalkingContextMessagesMigration(),
            CreateKeepTalkingContextAttachmentsMigration(),
            CreateKeepTalkingBlobRecordsMigration(),
            CreateSideNotesMigration(),
            CreateKeepTalkingOutboxEntriesMigration(),
            CreateKeepTalkingTrustInvitationsMigration(),
            CreateKeepTalkingVoiceTranscriptLinesMigration(),
            DropKeepTalkingOutboxAttemptTrackingMigration(),
            AddSideNoteVersionMigration(),
            DropContextSyncMetadataMigration(),
            AddKeepTalkingMappingScopeContextMigration(),
            CreateKeepTalkingWorkspacePlansMigration(),
            AddContextDeletedMessagesMigration(),
            AddLinkPreviewsMigration(),
            AddQueryIndexesMigration(),
            to: databaseID
        )
    }
}

public final class KeepTalkingInMemoryStore: KeepTalkingLocalStore,
    @unchecked Sendable
{
    private let manager: FluentManager
    private let databaseID: DatabaseID = .sqlite
    private let hasShutDown = NIOLockedValueBox(false)

    /// Synchronous, like `KeepTalkingModelStore.init` — see its note. Call
    /// `migrate()` before querying, or use `make()`.
    public init(gate: KeepTalkingDatabaseGateConfiguration = .automatic) {
        manager = FluentManager(
            gate: gate,
            logger: .init(label: "KeepTalking.InMemoryStore")
        )
        KeepTalkingModelStore.configure(
            manager: manager,
            databaseID: databaseID,
            sqliteConfiguration: .memory
        )
    }

    public static func make(
        gate: KeepTalkingDatabaseGateConfiguration = .automatic
    ) async throws -> KeepTalkingInMemoryStore {
        let store = KeepTalkingInMemoryStore(gate: gate)
        try await store.migrate()
        return store
    }

    public func migrate() async throws {
        try await manager.autoMigrate()
        try await KeepTalkingUndecodableActionSweep.run(on: database)
    }

    /// See `KeepTalkingModelStore.shutdown()`.
    public func shutdown() async {
        guard
            !hasShutDown.withLockedValue({ was in
                defer { was = true }
                return was
            })
        else { return }
        await manager.shutdown()
    }

    deinit {
        // `shutdown()` blocks until the NIO event-loop group has terminated.
        // Running it inline parks whatever thread released the store — and
        // under parallel tests that is a cooperative thread, so releasing a
        // batch of stores starves the pool exactly the way `blocking {}` used
        // to. `deinit` cannot be async, so hand the wait to a utility queue and
        // return immediately. The manager is captured by value; `self` is not.
        guard
            !hasShutDown.withLockedValue({ was in
                defer { was = true }
                return was
            })
        else { return }
        let manager = self.manager
        DispatchQueue.global(qos: .utility).async {
            manager.shutdown()
        }
    }

    public var database: any Database {
        manager.db(databaseID)
    }

    public func reset() async throws {
        try await manager.autoRevert()
        try await manager.autoMigrate()
    }
}
