import FluentKit
import Foundation
import Testing

@testable import KeepTalkingSDK

struct SemanticMemoryScopeTests {
    @Test("context and tagged thread scopes share canonical discovery")
    func discoversContextAndTaggedThreadScopes() async throws {
        let store = KeepTalkingInMemoryStore()
        let contextA = KeepTalkingContext(id: UUID())
        let contextB = KeepTalkingContext(id: UUID())
        try await contextA.save(on: store.database)
        try await contextB.save(on: store.database)
        let contextAID = try #require(contextA.id)

        let directThread = try await makeThread(
            context: contextA,
            content: "Direct context memory",
            on: store.database
        )
        let taggedThread = try await makeThread(
            context: contextB,
            content: "Related tagged memory",
            on: store.database
        )
        let unresolvedThread = KeepTalkingThread(
            context: contextB,
            startMessage: nil,
            endMessage: nil,
            state: .stored
        )
        try await unresolvedThread.save(on: store.database)

        try await KeepTalkingClient.addTag(
            "Project Aurora",
            namespace: "project",
            to: .context(contextAID),
            on: store.database
        )
        for thread in [directThread, taggedThread, unresolvedThread] {
            try await KeepTalkingClient.addTag(
                "project aurora",
                namespace: "project",
                to: .thread(try #require(thread.id)),
                on: store.database
            )
        }

        let scopes = try await KeepTalkingClient.retrievableSemanticMemoryScopes(
            for: contextAID,
            on: store.database
        )

        let directID = try #require(directThread.id)
        let taggedID = try #require(taggedThread.id)
        let unresolvedID = try #require(unresolvedThread.id)
        #expect(scopes.first { $0.target == .context(contextAID) }?.threadIDs == [directID])
        #expect(scopes.contains { $0.target == .thread(directID) })
        #expect(scopes.contains { $0.target == .thread(taggedID) })
        #expect(!scopes.contains { $0.target == .thread(unresolvedID) })
        #expect(
            scopes.first { $0.target == .thread(taggedID) }?.matchingTags.first?.title
                == "project:project aurora"
        )
    }

    @Test("one shared context tag exposes all resolved threads in that context")
    func expandsContextsSharingAnyTag() async throws {
        let store = KeepTalkingInMemoryStore()
        let context = KeepTalkingContext(id: UUID())
        let sharedContext = KeepTalkingContext(id: UUID())
        let unrelatedContext = KeepTalkingContext(id: UUID())
        for context in [context, sharedContext, unrelatedContext] {
            try await context.save(on: store.database)
        }

        _ = try await makeThread(
            context: context,
            content: "Current context memory",
            on: store.database
        )
        var sharedThreads: [KeepTalkingThread] = []
        for content in ["First shared memory", "Second shared memory"] {
            sharedThreads.append(
                try await makeThread(
                    context: sharedContext,
                    content: content,
                    on: store.database
                )
            )
        }
        let unrelatedThread = try await makeThread(
            context: unrelatedContext,
            content: "Unrelated memory",
            on: store.database
        )
        let contextID = try #require(context.id)
        let sharedContextID = try #require(sharedContext.id)
        let unrelatedContextID = try #require(unrelatedContext.id)
        let unrelatedThreadID = try #require(unrelatedThread.id)

        for (value, namespace, target) in [
            ("Aurora", "project", KeepTalkingMappingTarget.context(contextID)),
            ("Mobile", "topic", .context(contextID)),
            ("aurora", "project", .context(sharedContextID)),
            ("Backend", "topic", .context(sharedContextID)),
            ("Elsewhere", "project", .context(unrelatedContextID)),
        ] {
            try await KeepTalkingClient.addTag(
                value,
                namespace: namespace,
                to: target,
                on: store.database
            )
        }

        let scopes = try await KeepTalkingClient.retrievableSemanticMemoryScopes(
            for: contextID,
            on: store.database
        )

        let sharedScope = try #require(
            scopes.first { $0.target == .context(sharedContextID) }
        )
        let sharedThreadIDs = try Set(sharedThreads.map { try #require($0.id) })
        #expect(Set(sharedScope.threadIDs) == sharedThreadIDs)
        #expect(sharedScope.matchingTags.map(\.title) == ["project:aurora"])
        #expect(!scopes.contains { $0.target == .context(unrelatedContextID) })
        #expect(!scopes.contains { $0.threadIDs.contains(unrelatedThreadID) })
    }

    @Test("semantic index enhances lexical retrieval without defining access")
    func semanticIndexEnhancesLexicalRetrieval() async throws {
        let store = KeepTalkingInMemoryStore()
        let context = KeepTalkingContext(id: UUID())
        let otherContext = KeepTalkingContext(id: UUID())
        try await context.save(on: store.database)
        try await otherContext.save(on: store.database)

        let lexicalThread = try await makeThread(
            context: context,
            content: "Orchard planning notes",
            on: store.database
        )
        let enhancedThread = try await makeThread(
            context: context,
            content: "Orchard irrigation design",
            on: store.database
        )
        let unauthorizedThread = try await makeThread(
            context: otherContext,
            content: "Orchard private notes",
            on: store.database
        )
        let contextID = try #require(context.id)
        let lexicalID = try #require(lexicalThread.id)
        let enhancedID = try #require(enhancedThread.id)
        let unauthorizedID = try #require(unauthorizedThread.id)
        let scope = KeepTalkingSemanticMemoryScope(
            target: .context(contextID),
            contextID: contextID,
            threadIDs: [lexicalID, enhancedID],
            matchingTags: []
        )
        let semanticStore = SemanticMemoryTestStore(results: [
            KeepTalkingSemanticSearchResult(
                threadID: enhancedID,
                text: "stale indexed text",
                score: 1
            ),
            KeepTalkingSemanticSearchResult(
                threadID: unauthorizedID,
                text: "private indexed text",
                score: 1
            ),
        ])

        let enhancedResults = try await KeepTalkingClient.retrieveSemanticMemory(
            query: "orchard",
            topK: 10,
            scopes: [scope],
            semanticSearch: { query, topK in
                try await semanticStore.search(
                    query: query,
                    topK: topK,
                    threshold: nil
                )
            },
            on: store.database
        )
        let lexicalResults = try await KeepTalkingClient.retrieveSemanticMemory(
            query: "orchard",
            topK: 10,
            scopes: [scope],
            semanticSearch: nil,
            on: store.database
        )

        #expect(enhancedResults.first?.threadID == enhancedID)
        #expect(Set(lexicalResults.map(\.threadID)) == Set(scope.threadIDs))
        #expect(!enhancedResults.contains { $0.threadID == unauthorizedID })
        #expect(enhancedResults.first?.text.contains("Orchard irrigation design") == true)
    }

    private func makeThread(
        context: KeepTalkingContext,
        content: String,
        on database: any Database
    ) async throws -> KeepTalkingThread {
        let message = KeepTalkingContextMessage(
            context: context,
            sender: .autonomous(name: "assistant"),
            content: content
        )
        try await message.save(on: database)
        let thread = KeepTalkingThread(
            context: context,
            startMessage: message,
            endMessage: message,
            state: .stored
        )
        try await thread.save(on: database)
        return thread
    }
}

private actor SemanticMemoryTestStore: KeepTalkingSemanticStore {
    let results: [KeepTalkingSemanticSearchResult]

    init(results: [KeepTalkingSemanticSearchResult]) {
        self.results = results
    }

    func indexThread(id: UUID, text: String) async throws {}
    func updateThread(id: UUID, text: String) async throws {}
    func removeThread(id: UUID) async throws {}

    func search(
        query: String,
        topK: Int,
        threshold: Float?
    ) async throws -> [KeepTalkingSemanticSearchResult] {
        Array(results.prefix(topK))
    }

    func reset() async throws {}
    func documentCount() async throws -> Int { 0 }
    func allDocuments() async throws -> [(id: UUID, text: String)] { [] }
}
