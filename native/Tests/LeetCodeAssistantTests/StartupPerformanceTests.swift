import Foundation
import XCTest
@testable import LeetCodeAssistant

/// Startup cost guards.
///
/// The audited regression was that creating the root view synchronously decoded every
/// JSON domain and rebuilt the whole conversation RAG index — including NLEmbedding
/// vectors behind a `queue.sync` — before the first window could appear.
///
/// `LEETCODE_BENCH_DATA_DIR` points these at a real data snapshot for before/after
/// comparison. Without it the suite still runs against a generated corpus so the guard
/// keeps working in CI.
final class StartupPerformanceTests: XCTestCase {
    private static let benchmarkEnvironmentKey = "LEETCODE_BENCH_DATA_DIR"

    // MARK: - Corpus

    /// Builds a conversations.json comparable to a heavy real-world profile.
    private func makeConversationCorpus(conversations: Int, messagesEach: Int) -> [String: Any] {
        var root: [String: Any] = [:]
        for index in 0..<conversations {
            var messages: [[String: Any]] = []
            for messageIndex in 0..<messagesEach {
                let role = messageIndex.isMultiple(of: 2) ? "user" : "assistant"
                messages.append([
                    "id": "m_\(index)_\(messageIndex)",
                    "role": role,
                    "content": String(
                        repeating: "动态规划的状态转移方程需要覆盖边界条件，否则会漏解。",
                        count: 12
                    ),
                    "createdAt": 1_700_000_000_000 + messageIndex
                ])
            }
            root["c_\(index)"] = [
                "title": "会话 \(index)",
                "summary": "关于图论与动态规划的讨论",
                "updatedAt": 1_700_000_000_000 + index,
                "messages": messages
            ]
        }
        return root
    }

    private func makeCorpusDirectory(conversations: Int, messagesEach: Int) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "StartupPerf-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let corpus = makeConversationCorpus(conversations: conversations, messagesEach: messagesEach)
        try JSONSerialization.data(withJSONObject: corpus)
            .write(to: directory.appending(path: "conversations.json"), options: .atomic)
        return directory
    }

    private func benchmarkDirectory() -> URL? {
        guard let path = ProcessInfo.processInfo.environment[Self.benchmarkEnvironmentKey],
              !path.isEmpty
        else { return nil }
        return URL(filePath: path, directoryHint: .isDirectory)
    }

    private func elapsed(_ body: () throws -> Void) rethrows -> TimeInterval {
        let start = DispatchTime.now().uptimeNanoseconds
        try body()
        return Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000_000
    }

    // MARK: - Guards

    /// The first-window contract: constructing the store must not perform the data load.
    /// This is the assertion that actually fails on the pre-fix code path.
    @MainActor
    func testStoreInitDoesNotBlockOnDataOrEmbeddings() throws {
        let directory = try makeCorpusDirectory(conversations: 8, messagesEach: 40)
        defer { try? FileManager.default.removeItem(at: directory) }

        var store: LegacyDataStore?
        let duration = elapsed { store = LegacyDataStore(dataDirectory: directory) }
        let created = try XCTUnwrap(store)

        XCTAssertLessThan(
            duration,
            0.05,
            "Store construction must stay off the JSON + embedding path so the first window can render"
        )
        XCTAssertFalse(
            created.isDataReady,
            "A freshly constructed store must report cold data rather than a completed synchronous load"
        )
    }

    /// Hydration still has to produce the same content the synchronous path produced.
    @MainActor
    func testHydrationProducesFullyLoadedSnapshot() async throws {
        let directory = try makeCorpusDirectory(conversations: 5, messagesEach: 6)
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = LegacyDataStore(dataDirectory: directory)
        XCTAssertTrue(store.conversations.isEmpty)

        await store.hydrate()

        XCTAssertTrue(store.isDataReady)
        XCTAssertEqual(store.conversations.count, 5)
        XCTAssertEqual(store.conversations.first?.messageCount, 6)
    }

    /// The RAG index must not be a first-window dependency, and must converge afterwards.
    @MainActor
    func testMemoryIndexBecomesReadyAfterFirstWindow() async throws {
        let directory = try makeCorpusDirectory(conversations: 4, messagesEach: 8)
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = LegacyDataStore(dataDirectory: directory)
        XCTAssertEqual(store.memoryIndexState, .cold)

        await store.hydrate()
        await store.waitForMemoryIndex()

        let indexedIDs = await store.conversationMemoryIndex.indexedConversationIDs
        XCTAssertEqual(store.memoryIndexState, .ready)
        XCTAssertEqual(indexedIDs.count, 4)
    }

    // MARK: - Reporting

    /// Prints a before/after comparable number against a real data snapshot.
    /// Skipped unless `LEETCODE_BENCH_DATA_DIR` is set.
    @MainActor
    func testRealSnapshotStartupBudget() async throws {
        guard let source = benchmarkDirectory() else {
            throw XCTSkip("Set \(Self.benchmarkEnvironmentKey) to measure a real data snapshot")
        }
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "StartupPerfReal-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.copyItem(at: source, to: directory)
        defer { try? FileManager.default.removeItem(at: directory) }

        var store: LegacyDataStore?
        let constructionSeconds = elapsed { store = LegacyDataStore(dataDirectory: directory) }
        let created = try XCTUnwrap(store)

        let hydrationStart = DispatchTime.now().uptimeNanoseconds
        await created.hydrate()
        let hydrationSeconds = Double(DispatchTime.now().uptimeNanoseconds - hydrationStart) / 1_000_000_000

        let indexStart = DispatchTime.now().uptimeNanoseconds
        await created.waitForMemoryIndex()
        let indexSeconds = Double(DispatchTime.now().uptimeNanoseconds - indexStart) / 1_000_000_000

        let ragDocuments = await created.conversationMemoryIndex.documentCount
        let coldEmbeddings = await created.conversationMemoryIndex.lastSyncEmbeddingCount
        print(
            """
            [startup-benchmark cold] construction=\(String(format: "%.4f", constructionSeconds))s \
            hydration=\(String(format: "%.4f", hydrationSeconds))s \
            ragTail=\(String(format: "%.4f", indexSeconds))s \
            conversations=\(created.conversations.count) \
            ragDocuments=\(ragDocuments) embeddings=\(coldEmbeddings)
            """
        )

        // Second launch over the same directory: the persisted vector cache must make
        // the index a read rather than a rebuild.
        let warmStart = DispatchTime.now().uptimeNanoseconds
        let warmStore = LegacyDataStore(dataDirectory: directory)
        await warmStore.hydrate()
        await warmStore.waitForMemoryIndex()
        let warmSeconds = Double(DispatchTime.now().uptimeNanoseconds - warmStart) / 1_000_000_000
        let warmEmbeddings = await warmStore.conversationMemoryIndex.lastSyncEmbeddingCount
        let warmDocuments = await warmStore.conversationMemoryIndex.documentCount
        print(
            """
            [startup-benchmark warm] hydrate+ragReady=\(String(format: "%.4f", warmSeconds))s \
            ragDocuments=\(warmDocuments) embeddings=\(warmEmbeddings)
            """
        )

        XCTAssertLessThan(
            constructionSeconds,
            0.05,
            "First-window construction must stay flat regardless of snapshot size"
        )
        XCTAssertEqual(warmEmbeddings, 0, "An unchanged relaunch must not recompute embeddings")
        XCTAssertEqual(warmDocuments, ragDocuments, "Warm index must reproduce the full corpus")
    }
}
