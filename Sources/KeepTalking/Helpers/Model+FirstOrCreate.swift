import FluentKit
import Foundation

/// `find` then `save` is two statements with an await between them, and the
/// gate serialises only the writes: two callers both see no row, and the
/// second insert either fails a unique key or lands a duplicate where there
/// is none. A transaction holds the store's single writer slot for its whole
/// block, so deciding and inserting inside one is what makes get-or-create
/// atomic. The read outside it is the fast path for a row that exists.
///
/// Only rows that several callers may legitimately bring into being belong
/// here: a peer first seen, a relation first formed. A context is created
/// once, by name, and required everywhere else.
extension Model {
    public static func firstOrCreate(
        on database: any Database,
        matching: @escaping @Sendable (QueryBuilder<Self>) -> QueryBuilder<Self>,
        choosing choose: @escaping @Sendable ([Self]) -> Self? = { $0.first },
        create: @escaping @Sendable () -> Self
    ) async throws -> Self {
        if let existing = choose(try await matching(query(on: database)).all()) {
            return existing
        }
        return try await database.transaction { db in
            if let existing = choose(try await matching(query(on: db)).all()) {
                return existing
            }
            let row = create()
            try await row.save(on: db)
            return row
        }
    }
}
