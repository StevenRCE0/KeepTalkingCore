import FluentKit
import Foundation
import SQLKit

/// The one place keyed reads of `kt_context_messages` are written.
///
/// Keys are read raw — `timestamp` as the stored `Double`, never through
/// Fluent's rounding `Date` decode — so every predicate here is exact and
/// every result is a prefix of the store's own `(timestamp, id)` order. Rows
/// are then fetched by id, attachments eager-loaded. Every query runs off
/// the `(context, timestamp, id)` index.
enum MessageRangeReader {
    static let table = KeepTalkingContextMessage.schema
    /// Ids per `IN` list — well under SQLite's variable limit.
    static let idChunk = 500

    // MARK: - Keys

    static func keys(
        forIDs ids: some Collection<UUID>,
        in contextID: UUID,
        on sql: any SQLDatabase
    ) async throws -> [UUID: KeepTalkingMessageKey] {
        var keys: [UUID: KeepTalkingMessageKey] = [:]
        let unique = Array(Set(ids))
        for start in stride(from: 0, to: unique.count, by: idChunk) {
            let chunk = unique[start..<min(start + idChunk, unique.count)]
            var statement: SQLQueryString =
                "SELECT id, timestamp FROM \(ident: table) WHERE context = \(bind: contextID.uuidString) AND id IN ("
            for (offset, id) in chunk.enumerated() {
                if offset > 0 { statement.appendLiteral(", ") }
                statement.appendInterpolation(bind: id.uuidString)
            }
            statement.appendLiteral(")")
            for key in try await sql.raw(statement).all().map(decodeKey) {
                keys[key.id] = key
            }
        }
        return keys
    }

    static func keys(
        in contextID: UUID,
        range: KeepTalkingMessageRange,
        direction: KeepTalkingMessagePageDirection,
        limit: Int,
        on sql: any SQLDatabase
    ) async throws -> [KeepTalkingMessageKey] {
        guard limit > 0 else { return [] }
        var statement: SQLQueryString = "SELECT id, timestamp FROM \(ident: table) WHERE "
        appendPredicate(contextID: contextID, range: range, to: &statement)
        switch direction {
            case .forward: statement.appendLiteral(" ORDER BY timestamp ASC, id ASC")
            case .backward: statement.appendLiteral(" ORDER BY timestamp DESC, id DESC")
        }
        statement.appendLiteral(" LIMIT \(limit)")
        return try await sql.raw(statement).all().map(decodeKey)
    }

    static func count(
        in contextID: UUID,
        range: KeepTalkingMessageRange,
        on sql: any SQLDatabase
    ) async throws -> Int {
        var statement: SQLQueryString = "SELECT COUNT(*) AS n FROM \(ident: table) WHERE "
        appendPredicate(contextID: contextID, range: range, to: &statement)
        guard let row = try await sql.raw(statement).first() else { return 0 }
        return try row.decode(column: "n", as: Int.self)
    }

    static func key(
        atOffset offset: Int,
        in contextID: UUID,
        range: KeepTalkingMessageRange,
        on sql: any SQLDatabase
    ) async throws -> KeepTalkingMessageKey? {
        guard offset >= 0 else { return nil }
        var statement: SQLQueryString = "SELECT id, timestamp FROM \(ident: table) WHERE "
        appendPredicate(contextID: contextID, range: range, to: &statement)
        statement.appendLiteral(" ORDER BY timestamp ASC, id ASC LIMIT 1 OFFSET \(offset)")
        return try await sql.raw(statement).first().map(decodeKey)
    }

    // MARK: - Rows

    /// The rows for `keys`, in key order, with what `attachments` asks for.
    static func rows(
        for keys: [KeepTalkingMessageKey],
        attachments: KeepTalkingMessagePageAttachments,
        on database: any Database
    ) async throws -> KeepTalkingMessagePage {
        guard !keys.isEmpty else { return KeepTalkingMessagePage() }
        var byID: [UUID: KeepTalkingContextMessage] = [:]
        let ids = keys.map(\.id)
        for start in stride(from: 0, to: ids.count, by: idChunk) {
            let chunk = Array(ids[start..<min(start + idChunk, ids.count)])
            let query = KeepTalkingContextMessage.query(on: database).filter(\.$id ~~ chunk)
            if attachments != .none {
                query.with(\.$attachments)
            }
            for message in try await query.all() {
                if let id = message.id { byID[id] = message }
            }
        }
        let ordered = keys.compactMap { byID[$0.id] }
        var page = KeepTalkingMessagePage(
            messages: ordered,
            keysByID: Dictionary(uniqueKeysWithValues: keys.map { ($0.id, $0) })
        )
        if attachments == .rowsAndBlobRecords {
            page.blobRecords = try await blobRecords(for: ordered, on: database)
        }
        return page
    }

    static func blobRecords(
        for messages: [KeepTalkingContextMessage],
        on database: any Database
    ) async throws -> [String: KeepTalkingBlobRecord] {
        let blobIDs = Array(Set(messages.flatMap { $0.attachments.map(\.blobID) }))
        guard !blobIDs.isEmpty else { return [:] }
        var records: [String: KeepTalkingBlobRecord] = [:]
        for start in stride(from: 0, to: blobIDs.count, by: idChunk) {
            let chunk = Array(blobIDs[start..<min(start + idChunk, blobIDs.count)])
            for record in try await KeepTalkingBlobRecord.query(on: database).filter(\.$id ~~ chunk).all() {
                if let id = record.id { records[id] = record }
            }
        }
        return records
    }

    // MARK: - SQL

    private static func appendPredicate(
        contextID: UUID,
        range: KeepTalkingMessageRange,
        to statement: inout SQLQueryString
    ) {
        statement.appendLiteral("context = ")
        statement.appendInterpolation(bind: contextID.uuidString)
        switch range.lower {
            case .start:
                break
            case .before(let key):
                appendCut(key, comparison: ">", orEqual: true, to: &statement)
            case .after(let key):
                appendCut(key, comparison: ">", orEqual: false, to: &statement)
            case .end:
                statement.appendLiteral(" AND 0")
        }
        switch range.upper {
            case .end:
                break
            case .after(let key):
                appendCut(key, comparison: "<", orEqual: true, to: &statement)
            case .before(let key):
                appendCut(key, comparison: "<", orEqual: false, to: &statement)
            case .start:
                statement.appendLiteral(" AND 0")
        }
    }

    /// `(timestamp ⋈ t OR (timestamp = t AND id ⋈ i))`, with `⋈=` when the
    /// cut's own row is inside.
    private static func appendCut(
        _ key: KeepTalkingMessageKey,
        comparison: String,
        orEqual: Bool,
        to statement: inout SQLQueryString
    ) {
        statement.appendLiteral(" AND (timestamp \(comparison) ")
        statement.appendInterpolation(bind: key.timestamp)
        statement.appendLiteral(" OR (timestamp = ")
        statement.appendInterpolation(bind: key.timestamp)
        statement.appendLiteral(" AND id \(comparison)\(orEqual ? "=" : "") ")
        statement.appendInterpolation(bind: key.id.uuidString)
        statement.appendLiteral("))")
    }

    private static func decodeKey(_ row: any SQLRow) throws -> KeepTalkingMessageKey {
        let id = try row.decode(column: "id", as: String.self)
        guard let uuid = UUID(uuidString: id) else {
            throw KeepTalkingMessageRangeError.malformedID(id)
        }
        return KeepTalkingMessageKey(
            timestamp: try row.decode(column: "timestamp", as: Double.self),
            id: uuid
        )
    }

    static func sql(_ database: any Database) throws -> any SQLDatabase {
        guard let sql = database as? any SQLDatabase else {
            throw KeepTalkingStoreError.notSQL
        }
        return sql
    }
}

public enum KeepTalkingMessageRangeError: Error {
    case malformedID(String)
}
