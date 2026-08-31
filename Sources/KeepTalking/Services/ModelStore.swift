import Dispatch
import FluentKit
import FluentSQLiteDriver
import Foundation
import Logging
import NIOConcurrencyHelpers

public final class KeepTalkingModelStore: KeepTalkingLocalStore,
    @unchecked Sendable
{
    public let databaseURL: URL

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
        logger: Logger = .init(label: "KeepTalking.ModelStore")
    ) throws {
        self.databaseURL = databaseURL ?? Self.defaultDatabaseURL(for: databaseFileName)
        self.databaseID = databaseID
        self.logger = logger
        self.manager = FluentManager(
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
        logger: Logger = .init(label: "KeepTalking.ModelStore")
    ) async throws -> KeepTalkingModelStore {
        let store = try KeepTalkingModelStore(
            databaseURL: databaseURL,
            databaseFileName: databaseFileName,
            databaseID: databaseID,
            logger: logger
        )
        try await store.migrate()
        return store
    }

    /// Applies any outstanding migrations. Must complete before the store is
    /// queried.
    public func migrate() async throws {
        try await manager.autoMigrate()
        let logger = self.logger
        try await KeepTalkingUndecodableActionSweep.run(on: database) {
            logger.notice("\($0)")
        }
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
            to: databaseID
        )
    }
}

public final class KeepTalkingInMemoryStore: KeepTalkingLocalStore,
    @unchecked Sendable
{
    private let manager = FluentManager(
        logger: .init(label: "KeepTalking.InMemoryStore")
    )
    private let databaseID: DatabaseID = .sqlite
    private let hasShutDown = NIOLockedValueBox(false)

    /// Synchronous, like `KeepTalkingModelStore.init` — see its note. Call
    /// `migrate()` before querying, or use `make()`.
    public init() {
        KeepTalkingModelStore.configure(
            manager: manager,
            databaseID: databaseID,
            sqliteConfiguration: .memory
        )
    }

    public static func make() async throws -> KeepTalkingInMemoryStore {
        let store = KeepTalkingInMemoryStore()
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
