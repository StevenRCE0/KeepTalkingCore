import Foundation
import Testing

@testable import KeepTalkingSDK

struct ModelStoreTests {
    @Test("model store reset recreates an empty schema")
    func resetRecreatesEmptySchema() async throws {
        let databaseURL = URL(
            fileURLWithPath: NSTemporaryDirectory(),
            isDirectory: true
        )
        .appendingPathComponent(UUID().uuidString, isDirectory: false)
        .appendingPathExtension("sqlite")

        defer {
            let fm = FileManager.default
            try? fm.removeItem(at: databaseURL)
            try? fm.removeItem(
                at: URL(fileURLWithPath: databaseURL.path + "-shm")
            )
            try? fm.removeItem(
                at: URL(fileURLWithPath: databaseURL.path + "-wal")
            )
        }

        let store = try KeepTalkingModelStore(databaseURL: databaseURL)
        let node = KeepTalkingNode(id: UUID())

        try await node.save(on: store.database)
        #expect(
            try await KeepTalkingNode.query(on: store.database).count() == 1
        )

        try await store.reset()

        #expect(
            try await KeepTalkingNode.query(on: store.database).count() == 0
        )

        let replacementNode = KeepTalkingNode(id: UUID())
        try await replacementNode.save(on: store.database)
        #expect(
            try await KeepTalkingNode.query(on: store.database).count() == 1
        )
    }
}
