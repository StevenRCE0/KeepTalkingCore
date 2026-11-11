import FluentKit
import Foundation

struct AttachmentBlobClaimMiddleware: AsyncModelMiddleware {
    func create(
        model: KeepTalkingContextAttachment, on db: any Database, next: any AnyAsyncModelResponder
    ) async throws {
        try await next.create(model, on: db)
        try await claim(model, on: db)
    }

    func update(
        model: KeepTalkingContextAttachment, on db: any Database, next: any AnyAsyncModelResponder
    ) async throws {
        try await next.update(model, on: db)
        try await claim(model, on: db)
    }

    private func claim(_ model: KeepTalkingContextAttachment, on db: any Database) async throws {
        try await KeepTalkingBlobClaim.reconcile(
            .attachment(try model.requireID()), blobIDs: [model.blobID], contextID: model.$context.id, on: db)
    }
}

struct MappingBlobClaimMiddleware: AsyncModelMiddleware {
    func create(model: KeepTalkingMapping, on db: any Database, next: any AnyAsyncModelResponder) async throws {
        try await next.create(model, on: db)
        try await claim(model, on: db)
    }

    func update(model: KeepTalkingMapping, on db: any Database, next: any AnyAsyncModelResponder) async throws {
        try await next.update(model, on: db)
        try await claim(model, on: db)
    }

    private func claim(_ model: KeepTalkingMapping, on db: any Database) async throws {
        try await KeepTalkingBlobClaim.reconcile(
            .mapping(try model.requireID()), blobIDs: model.blobIDs, contextID: model.claimContextID, on: db)
    }
}

struct WorkspaceStageBlobClaimMiddleware: AsyncModelMiddleware {
    func create(
        model: KeepTalkingWorkspaceStageRow, on db: any Database, next: any AnyAsyncModelResponder
    ) async throws {
        try await next.create(model, on: db)
        try await claim(model, on: db)
    }

    func update(
        model: KeepTalkingWorkspaceStageRow, on db: any Database, next: any AnyAsyncModelResponder
    ) async throws {
        try await next.update(model, on: db)
        try await claim(model, on: db)
    }

    private func claim(_ model: KeepTalkingWorkspaceStageRow, on db: any Database) async throws {
        try await KeepTalkingBlobClaim.reconcile(
            .workspaceStage(try model.requireID()), blobIDs: model.claimedBlobIDs, contextID: model.$context.id,
            on: db)
    }
}

struct WorkspaceResourceBlobClaimMiddleware: AsyncModelMiddleware {
    func create(
        model: KeepTalkingWorkspaceResourceRow, on db: any Database, next: any AnyAsyncModelResponder
    ) async throws {
        try await next.create(model, on: db)
        try await claim(model, on: db)
    }

    func update(
        model: KeepTalkingWorkspaceResourceRow, on db: any Database, next: any AnyAsyncModelResponder
    ) async throws {
        try await next.update(model, on: db)
        try await claim(model, on: db)
    }

    private func claim(_ model: KeepTalkingWorkspaceResourceRow, on db: any Database) async throws {
        try await KeepTalkingBlobClaim.reconcile(
            .workspaceResource(try model.requireID()), blobIDs: model.claimedBlobIDs, contextID: model.$context.id,
            on: db)
    }
}
