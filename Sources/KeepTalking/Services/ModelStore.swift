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
            try Self.configure(
                manager: manager,
                databaseID: databaseID,
                sqliteConfiguration: .file(self.databaseURL.path)
            )
        } catch {
            self.manager.shutdown()
            throw error
        }
    }

    deinit {
        self.manager.shutdown()
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
    ) throws {
        manager.databases.use(
            .sqlite(sqliteConfiguration),
            as: databaseID,
            isDefault: true
        )
        manager.migrations.add(
            CreateKeepTalkingNodesMigration(),
            CreateKeepTalkingActionsMigration(),
            CreateKeepTalkingNodeRelationsMigration(),
            CreateNodeIdentityKeysMigration(),
            CreateNodeRelationsActionsRelationsMigration(),
            CreateKeepTalkingContextsMigration(),
            CreateKeepTalkingThreadsMigration(),
            CreateKeepTalkingMappingsMigration(),
            CreateKeepTalkingOperatorContextsMigration(),
            CreateContextGroupSecretsMigration(),
            CreateKeepTalkingContextMessagesMigration(),
            CreateKeepTalkingContextAttachmentsMigration(),
            CreateKeepTalkingBlobRecordsMigration(),
            to: databaseID
        )
        try blocking {
            try await manager.autoMigrate()
        }
    }
}

public final class KeepTalkingInMemoryStore: KeepTalkingLocalStore,
    @unchecked Sendable
{
    private let manager = FluentManager(
        logger: .init(label: "KeepTalking.InMemoryStore")
    )
    private let databaseID: DatabaseID = .sqlite

    public init() {
        do {
            try KeepTalkingModelStore.configure(
                manager: manager,
                databaseID: databaseID,
                sqliteConfiguration: .memory
            )
        } catch {
            fatalError(
                "Failed to initialize in-memory store: \(error.localizedDescription)"
            )
        }
    }

    deinit {
        self.manager.shutdown()
    }

    public var database: any Database {
        manager.db(databaseID)
    }
}
