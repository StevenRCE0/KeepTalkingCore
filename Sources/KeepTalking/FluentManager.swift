import FluentKit
import Logging
import NIOConcurrencyHelpers
import NIOCore
import NIOPosix
import SQLKit

/// `FluentManager` manages Fluent databases, migrations, and lifecycle resources.
public final class FluentManager: Sendable {
    private let threadPool: NIOLockedValueBox<NIOThreadPool>
    private let eventLoopGroup: any EventLoopGroup
    /// Admission for every database this manager hands out. Sized to the
    /// event loops, since the SQLite driver opens one connection per loop.
    let gate: DatabaseGate
    private let migrationLogLevelBox: NIOLockedValueBox<Logger.Level>
    private let logger: Logger

    /// Databases registry for configured database connections.
    public let databases: Databases

    /// Migrations registry.
    public let migrations: Migrations

    /// Log level used by migration operations.
    public var migrationLogLevel: Logger.Level {
        get { self.migrationLogLevelBox.withLockedValue { $0 } }
        set { self.migrationLogLevelBox.withLockedValue { $0 = newValue } }
    }

    public init(
        threadPool: NIOThreadPool = NIOThreadPool(numberOfThreads: System.coreCount),
        eventLoopGroup: any EventLoopGroup = MultiThreadedEventLoopGroup(numberOfThreads: System.coreCount),
        gate: KeepTalkingDatabaseGateConfiguration = .automatic,
        logger: Logger = Logger(label: "FluentManager"),
        migrationLogLevel: Logger.Level = .info
    ) {
        self.threadPool = .init(threadPool)
        self.eventLoopGroup = eventLoopGroup
        self.gate = DatabaseGate(
            configuration: gate,
            connections: eventLoopGroup.makeIterator().reduce(0) { count, _ in count + 1 }
        )
        self.logger = logger
        self.databases = Databases(threadPool: threadPool, on: eventLoopGroup)
        self.migrations = Migrations()
        self.migrationLogLevelBox = .init(migrationLogLevel)
        self.threadPool.withLockedValue { $0.start() }
    }

    /// Resolves a database connection by identifier, reporting its work to
    /// ``KeepTalkingDatabaseActivity``.
    public func db(_ id: DatabaseID? = nil, logger: Logger = .init(label: "Fluent")) -> any Database {
        guard
            let db = self.databases.database(
                id,
                logger: logger,
                on: self.eventLoopGroup.any(),
            )
        else {
            fatalError("No database configured for \(id?.string ?? "default")")
        }
        // The SDK only configures SQLite, whose Fluent database is an
        // `SQLDatabase`. The wrapper must be one too — see its doc comment.
        guard let sqlDatabase = db as? any Database & SQLDatabase else {
            fatalError("Database \(id?.string ?? "default") is not an SQLDatabase")
        }
        return ActivityReportingDatabase(base: sqlDatabase, gate: gate)
    }

    /// Runs pending forward migrations without prompting.
    public func autoMigrate() async throws {
        // The migrator resolves its own databases, bypassing `db()`.
        KeepTalkingDatabaseActivity.begin()
        defer { KeepTalkingDatabaseActivity.end() }
        let migrator = Migrator(
            databases: self.databases,
            migrations: self.migrations,
            logger: Logger(label: "Fluent.Migrator"),
            on: self.eventLoopGroup.any(),
            migrationLogLevel: self.migrationLogLevelBox.withLockedValue { $0 }
        )
        try await migrator.setupIfNeeded().flatMap {
            migrator.prepareBatch()
        }.get()
    }

    /// Reverts all applied migration batches without prompting.
    public func autoRevert() async throws {
        KeepTalkingDatabaseActivity.begin()
        defer { KeepTalkingDatabaseActivity.end() }
        let migrator = Migrator(
            databases: self.databases,
            migrations: self.migrations,
            logger: Logger(label: "Fluent.Migrator"),
            on: self.eventLoopGroup.any(),
            migrationLogLevel: self.migrationLogLevelBox.withLockedValue { $0 }
        )
        try await migrator.setupIfNeeded().flatMap {
            migrator.revertAllBatches()
        }.get()
    }

    /// Gracefully shuts down databases, thread pool, and event loop group.
    public func shutdown() async {
        await self.databases.shutdownAsync()

        self.threadPool.withLockedValue { pool in
            pool.shutdownGracefully { _ in }
        }
        do {
            try await self.eventLoopGroup.shutdownGracefully()
        } catch {
            self.logger.error("Failed to shut down event loop group: \(error.localizedDescription)")
        }
    }

    /// Synchronous shutdown variant.
    public func shutdown() {
        self.databases.shutdown()

        self.threadPool.withLockedValue { pool in
            pool.shutdownGracefully { _ in }
        }
        do {
            try self.eventLoopGroup.syncShutdownGracefully()
        } catch {
            self.logger.error("Failed to shut down event loop group: \(error.localizedDescription)")
        }
    }
}
