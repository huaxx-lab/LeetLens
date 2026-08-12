import Foundation
import XCTest
@testable import LeetCodeAssistant

/// Counts loads/saves and can simulate an unreachable remote.
private actor CountingVectorStore: ConversationVectorStore {
    private var storage: [String: [Double]]
    private(set) var loadCalls = 0
    private(set) var savedKeys: Set<String> = []
    private let isReachable: Bool

    init(seed: [String: [Double]] = [:], isReachable: Bool = true) {
        storage = seed
        self.isReachable = isReachable
    }

    func load(keys: Set<String>) async -> [String: [Double]] {
        loadCalls += 1
        guard isReachable else { return [:] }
        return storage.filter { keys.contains($0.key) }
    }

    func save(_ vectors: [String: [Double]]) async {
        guard isReachable else { return }
        for (key, vector) in vectors {
            storage[key] = vector
            savedKeys.insert(key)
        }
    }

    func snapshot() -> [String: [Double]] { storage }
}

final class VectorCacheTests: XCTestCase {
    private func conversation(
        id: String,
        messages: [String],
        updatedAt: Date = Date(timeIntervalSince1970: 1_000)
    ) -> ConversationSummary {
        ConversationSummary(
            id: id,
            title: "会话 \(id)",
            summary: "",
            updatedAt: updatedAt,
            messageCount: messages.count,
            messages: messages.enumerated().map { index, content in
                ConversationTranscriptMessage(
                    id: "\(id)-m\(index)",
                    role: index.isMultiple(of: 2) ? "user" : "assistant",
                    content: content,
                    createdAt: Date(timeIntervalSince1970: 1_000)
                )
            }
        )
    }

    private func skipUnlessSemantic(_ index: ConversationMemoryIndex) async throws {
        guard await index.usesSemanticEmbeddings else {
            throw XCTSkip("This macOS installation has no Simplified Chinese sentence embedding.")
        }
    }

    // MARK: - Incrementality

    /// The headline guarantee: a rebuild over unchanged content performs no embeddings.
    func testUnchangedSynchronizePerformsZeroEmbeddings() async throws {
        let store = CountingVectorStore()
        let index = ConversationMemoryIndex(vectorStore: store)
        try await skipUnlessSemantic(index)
        let chats = [
            conversation(id: "a", messages: ["最长无重复子串怎么解", "用滑动窗口维护左指针"]),
            conversation(id: "b", messages: ["二叉树层序遍历", "用队列逐层展开"])
        ]

        await index.synchronize(conversations: chats)
        let firstPass = await index.lastSyncEmbeddingCount
        XCTAssertGreaterThan(firstPass, 0, "Cold index must embed something")

        await index.synchronize(conversations: chats)
        let secondPass = await index.lastSyncEmbeddingCount
        XCTAssertEqual(secondPass, 0, "Unchanged content must not be re-embedded")
    }

    /// A fresh process with a warm store must not recompute anything — this is what
    /// turns a ~14s startup index build into a cache read.
    func testColdIndexReusesPersistedVectorsAcrossRestart() async throws {
        let store = CountingVectorStore()
        let chats = [conversation(id: "a", messages: ["动态规划状态转移方程怎么推导", "先定义状态再写转移"])]

        let firstIndex = ConversationMemoryIndex(vectorStore: store)
        try await skipUnlessSemantic(firstIndex)
        await firstIndex.synchronize(conversations: chats)
        let embeddedFirst = await firstIndex.lastSyncEmbeddingCount
        XCTAssertGreaterThan(embeddedFirst, 0)

        // Simulate relaunch: brand new index, same persisted store.
        let restarted = ConversationMemoryIndex(vectorStore: store)
        await restarted.synchronize(conversations: chats)
        let embeddedAfterRestart = await restarted.lastSyncEmbeddingCount
        XCTAssertEqual(embeddedAfterRestart, 0, "Restart re-embedded cached content")
        let documentCount = await restarted.documentCount
        XCTAssertGreaterThan(documentCount, 0)
    }

    /// Editing one conversation must not re-embed the untouched one.
    func testEditingOneConversationOnlyEmbedsChangedChunks() async throws {
        let store = CountingVectorStore()
        let index = ConversationMemoryIndex(vectorStore: store)
        try await skipUnlessSemantic(index)
        let stable = conversation(id: "stable", messages: ["图论最短路用 Dijkstra", "堆优化后是 ElogV"])
        let edited = conversation(id: "edited", messages: ["快排怎么选基准"])

        await index.synchronize(conversations: [stable, edited])
        let baseline = await index.lastSyncEmbeddingCount
        XCTAssertGreaterThan(baseline, 0)

        let editedAgain = conversation(
            id: "edited",
            messages: ["快排怎么选基准", "三数取中可以避免最坏情况"],
            updatedAt: Date(timeIntervalSince1970: 2_000)
        )
        await index.synchronize(conversations: [stable, editedAgain])
        let incremental = await index.lastSyncEmbeddingCount

        XCTAssertGreaterThan(incremental, 0, "Changed content must be embedded")
        XCTAssertLessThan(incremental, baseline, "Untouched conversation was re-embedded")
    }

    /// Deleting a conversation drops its documents without touching the others.
    func testDeletingConversationRemovesItsDocumentsOnly() async throws {
        let store = CountingVectorStore()
        let index = ConversationMemoryIndex(vectorStore: store)
        try await skipUnlessSemantic(index)
        let keep = conversation(id: "keep", messages: ["并查集路径压缩"])
        let drop = conversation(id: "drop", messages: ["前缀和与差分数组"])

        await index.synchronize(conversations: [keep, drop])
        let reconciliation = await index.synchronize(conversations: [keep])

        XCTAssertEqual(reconciliation.removed, ["drop"])
        let indexed = await index.indexedConversationIDs
        XCTAssertEqual(indexed, ["keep"])
        let embeddedOnDelete = await index.lastSyncEmbeddingCount
        XCTAssertEqual(embeddedOnDelete, 0, "A pure deletion must not embed anything")
    }

    /// Deleting a conversation must also reclaim its vectors, not just its documents.
    @MainActor
    func testDeletingConversationReclaimsItsVectorsFromDisk() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "VectorGC-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = LegacyDataStore(dataDirectory: directory)
        await store.hydrate()
        let keepID = try store.createConversation(
            title: "保留",
            firstMessage: ConversationTranscriptMessage(
                id: "m-keep", role: "user",
                content: "并查集的路径压缩怎么写", createdAt: .now
            )
        )
        let dropID = try store.createConversation(
            title: "删除",
            firstMessage: ConversationTranscriptMessage(
                id: "m-drop", role: "user",
                content: "线段树的懒标记怎么下传", createdAt: .now
            )
        )
        await store.waitForMemoryIndex()

        let cache = LocalVectorStore(dataDirectory: directory)
        let before = await cache.count()
        guard before > 0 else { throw XCTSkip("No sentence embedding available on this machine") }

        try store.deleteConversation(dropID)
        await store.waitForMemoryIndex()

        let after = await LocalVectorStore(dataDirectory: directory).count()
        XCTAssertLessThan(after, before, "Deleted conversation's vectors were never reclaimed")
        XCTAssertGreaterThan(after, 0, "Surviving conversation lost its vectors")

        // The kept conversation must still be retrievable.
        let indexed = await store.conversationMemoryIndex.indexedConversationIDs
        XCTAssertEqual(indexed, [keepID])
    }

    // MARK: - Content addressing

    func testIdenticalTextSharesOneVectorKeyRegardlessOfConversation() {
        let first = ConversationVectorKey.make(text: "滑动窗口", embeddingRevision: 3)
        let second = ConversationVectorKey.make(text: "  滑动窗口\n", embeddingRevision: 3)
        let differentRevision = ConversationVectorKey.make(text: "滑动窗口", embeddingRevision: 4)
        let differentText = ConversationVectorKey.make(text: "双指针", embeddingRevision: 3)

        XCTAssertEqual(first, second, "Whitespace-only differences must not split the cache")
        XCTAssertNotEqual(first, differentRevision, "Model revision must invalidate old vectors")
        XCTAssertNotEqual(first, differentText)
    }

    // MARK: - Local store

    func testLocalStoreRoundTripsAndReclaimsUnreferencedVectors() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "VectorStoreTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = LocalVectorStore(dataDirectory: directory)
        await store.save(["a": [1.5, -2.25], "b": [0.5]])

        let reopened = LocalVectorStore(dataDirectory: directory)
        let loaded = await reopened.load(keys: ["a", "b"])
        XCTAssertEqual(loaded["a"], [1.5, -2.25])
        XCTAssertEqual(loaded["b"], [0.5])

        await reopened.retain(keys: ["a"])
        let afterReclaim = await reopened.load(keys: ["a", "b"])
        XCTAssertEqual(afterReclaim.keys.sorted(), ["a"])
        let total = await reopened.count()
        XCTAssertEqual(total, 1)
    }

    /// An unreachable database must be invisible: local results still flow.
    func testLayeredStoreFallsBackWhenDatabaseIsUnreachable() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "LayeredStoreTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let local = LocalVectorStore(dataDirectory: directory)
        let remote = CountingVectorStore(isReachable: false)
        let layered = LayeredVectorStore(local: local, durable: remote)

        await layered.save(["k": [3.0, 4.0]])
        let loaded = await layered.load(keys: ["k"])
        XCTAssertEqual(loaded["k"], [3.0, 4.0], "Local layer must serve results without the remote")
    }

    /// A remote hit is promoted into the local store so the next launch is offline-fast.
    func testLayeredStorePromotesDatabaseHitsIntoLocal() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "LayeredPromoteTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let local = LocalVectorStore(dataDirectory: directory)
        let durable = CountingVectorStore(seed: ["remote-key": [7.0, 8.0]])
        let layered = LayeredVectorStore(local: local, durable: durable)

        let first = await layered.load(keys: ["remote-key"])
        XCTAssertEqual(first["remote-key"], [7.0, 8.0])

        let localOnly = await local.load(keys: ["remote-key"])
        XCTAssertEqual(localOnly["remote-key"], [7.0, 8.0], "Remote hit was not promoted locally")

    }

    // MARK: - pgvector (opt-in)

    /// Round-trips a 640-dimensional vector through the real pgvector table.
    /// Skipped unless `LEETCODE_PG_HOST` is set.
    func testLivePostgresVectorRoundTrip() async throws {
        guard let configuration = PostgresVectorConfiguration.resolve() else {
            throw XCTSkip("Set LEETCODE_PG_HOST/PASSWORD to exercise the vector database")
        }
        let store = PostgresVectorStore(configuration: configuration)
        // Keys must look like real content addresses; the store rejects anything else.
        let key = ConversationVectorKey.make(text: "pgvector-selftest-\(UUID().uuidString)", embeddingRevision: 1)
        let vector = (0..<PostgresVectorStore.vectorDimension).map { Double($0) / 1_000 }

        await store.save([key: vector])
        let loaded = await store.load(keys: [key])
        let round = try XCTUnwrap(loaded[key], "pgvector round trip returned nothing")
        XCTAssertEqual(round.count, PostgresVectorStore.vectorDimension)
        for (index, value) in round.enumerated() {
            XCTAssertEqual(value, vector[index], accuracy: 1e-6)
        }
    }

    func testPostgresRejectsUnsafeKeysAndWrongDimensions() {
        XCTAssertTrue(PostgresVectorStore.isSafeKey(String(repeating: "a1", count: 32)))
        XCTAssertFalse(PostgresVectorStore.isSafeKey("'; DROP TABLE x; --"))
        XCTAssertFalse(PostgresVectorStore.isSafeKey("ABCDEF"), "Uppercase is not a SHA-256 hex digest we emit")
        XCTAssertFalse(PostgresVectorStore.isSafeKey(""))
    }

    func testPostgresVectorTextFormatRoundTrips() throws {
        let vector: [Double] = [0, -1.5, 2.25, 0.000125]
        let text = PostgresVectorStore.formatVector(vector)
        XCTAssertTrue(text.hasPrefix("[") && text.hasSuffix("]"))
        let parsed = try XCTUnwrap(PostgresVectorStore.parseVector(text))
        XCTAssertEqual(parsed.count, vector.count)
        for (index, value) in parsed.enumerated() {
            XCTAssertEqual(value, vector[index], accuracy: 1e-9)
        }
        XCTAssertNil(PostgresVectorStore.parseVector("not a vector"))
    }
}
