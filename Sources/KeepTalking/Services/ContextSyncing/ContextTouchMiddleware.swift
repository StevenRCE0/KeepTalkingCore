import FluentKit
import Foundation

// Touch a context's `updatedAt` whenever one of its children is written through a
// single-model save (sending a message, a continuation-state update, an attachment
// write, …). The batched sync path uses `Collection.create(on:)`, which is a bulk
// insert that BYPASSES model middleware — there the context is touched directly by
// `upsertContext`, so these middlewares don't double-fire. See
// `KeepTalkingClient+MessagingController.saveIncomingMessages`.
//
// The touch is forward-only (`filter(updated_at < date)`) so an out-of-order or
// older child write can never regress the context's last-activity time, and it's a
// targeted `UPDATE` so it doesn't reload/rewrite the rest of the context row.

struct ContextMessageTouchMiddleware: AsyncModelMiddleware {
    func create(
        model: KeepTalkingContextMessage,
        on db: any Database,
        next: any AnyAsyncModelResponder
    ) async throws {
        try await next.create(model, on: db)
        try await touchContext(model.$context.id, to: model.timestamp, on: db)
    }

    func update(
        model: KeepTalkingContextMessage,
        on db: any Database,
        next: any AnyAsyncModelResponder
    ) async throws {
        try await next.update(model, on: db)
        try await touchContext(model.$context.id, to: model.timestamp, on: db)
    }
}

struct ContextAttachmentTouchMiddleware: AsyncModelMiddleware {
    func create(
        model: KeepTalkingContextAttachment,
        on db: any Database,
        next: any AnyAsyncModelResponder
    ) async throws {
        try await next.create(model, on: db)
        try await touchContext(model.$context.id, to: model.createdAt, on: db)
    }

    func update(
        model: KeepTalkingContextAttachment,
        on db: any Database,
        next: any AnyAsyncModelResponder
    ) async throws {
        try await next.update(model, on: db)
        try await touchContext(model.$context.id, to: model.createdAt, on: db)
    }
}

private func touchContext(
    _ contextID: UUID,
    to date: Date,
    on db: any Database
) async throws {
    try await KeepTalkingContext.query(on: db)
        .filter(\.$id == contextID)
        .filter(\.$updatedAt < date)
        .set(\.$updatedAt, to: date)
        .update()
}
