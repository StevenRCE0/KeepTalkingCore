import FluentKit
import Foundation
import Testing

@testable import KeepTalkingSDK

/// Shadow model over `kt_actions` that writes the payload/descriptor columns
/// as raw JSON text, so a row can be seeded with a payload shape the current
/// `KeepTalkingAction.Payload` no longer decodes (a retired case or primitive
/// kind).
private final class RawActionSeedRow: Model, @unchecked Sendable {
    static let schema = KeepTalkingAction.schema

    @ID(key: .id)
    var id: UUID?

    @Field(key: "payload")
    var payload: String

    @Field(key: "descriptor")
    var descriptor: String

    @Field(key: "remote_authorisable")
    var remoteAuthorisable: Bool

    @Field(key: "blocking_authorisation")
    var blockingAuthorisation: Bool

    @Timestamp(key: "created_at", on: .create)
    var createdAt: Date?

    init() {}
}

struct UndecodableActionSweepTests {
    @Test("sweep deletes rows whose payload no longer decodes, keeps the rest")
    func sweepRemovesUndecodableRows() async throws {
        let store = try await KeepTalkingInMemoryStore.make()

        let validAction = KeepTalkingAction(
            payload: .semanticRetrieval(.init(contextIDs: [])),
            remoteAuthorisable: true,
            blockingAuthorisation: false
        )
        validAction.descriptor = KeepTalkingActionDescriptor(
            subject: nil,
            action: KeepTalkingActionWithDescription(description: "valid"),
            object: nil
        )
        try await validAction.save(on: store.database)
        let validID = try #require(validAction.id)

        // The retired create-action primitive shape, exactly as an old build
        // would have persisted it.
        let legacyRow = RawActionSeedRow()
        let legacyID = UUID()
        legacyRow.id = legacyID
        legacyRow.payload = """
            {"primitive":{"_0":{"id":"\(UUID().uuidString)","name":"create-action","indexDescription":"legacy","action":"create-action","blockingAuthorisation":true}}}
            """
        legacyRow.descriptor = #"{"action":{"description":"legacy"}}"#
        legacyRow.remoteAuthorisable = true
        legacyRow.blockingAuthorisation = true
        try await legacyRow.save(on: store.database)

        try await KeepTalkingUndecodableActionSweep.run(on: store.database)

        let survivors = try await KeepTalkingAction.query(on: store.database).all()
        #expect(survivors.count == 1)
        #expect(survivors.first?.id == validID)
        let rawSurvivorIDs = try await RawActionSeedRow.query(on: store.database)
            .all()
            .compactMap(\.id)
        #expect(!rawSurvivorIDs.contains(legacyID))
    }

    @Test("sweep leaves a fully decodable table untouched")
    func sweepIsNoOpOnHealthyRows() async throws {
        let store = try await KeepTalkingInMemoryStore.make()

        for payload: KeepTalkingAction.Payload in [
            .semanticRetrieval(.init(contextIDs: [])),
            .actionCreation(.init(contextIDs: [])),
        ] {
            let action = KeepTalkingAction(
                payload: payload,
                remoteAuthorisable: true,
                blockingAuthorisation: false
            )
            action.descriptor = KeepTalkingActionDescriptor(
                subject: nil,
                action: KeepTalkingActionWithDescription(description: "ok"),
                object: nil
            )
            try await action.save(on: store.database)
        }

        try await KeepTalkingUndecodableActionSweep.run(on: store.database)

        let survivors = try await KeepTalkingAction.query(on: store.database).all()
        #expect(survivors.count == 2)
    }
}
