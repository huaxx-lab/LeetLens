import Foundation
import XCTest
@testable import LeetCodeAssistant

final class ConversationRunCheckpointTests: XCTestCase {
    private func checkpoint(
        thread: String = "c1",
        run: String = "r1",
        content: String = "partial",
        phase: ConversationRunCheckpoint.Phase = .streaming,
        updatedAt: Date = Date(timeIntervalSince1970: 10)
    ) -> ConversationRunCheckpoint {
        ConversationRunCheckpoint(
            threadID: thread,
            runID: run,
            userMessageID: "u1",
            assistantMessageID: "a1",
            ledgerSequenceAtStart: 3,
            phase: phase,
            partialContent: content,
            partialReasoning: "reason",
            toolCalls: ["search_learning_records"],
            agentRuns: [AgentToolRun(id: "call1", name: "search_learning_records", arguments: #"{"query":"栈"}"#, resultJSON: "")],
            volatileContextPrompts: ["冻结的题面与代码"],
            providerID: "p1",
            model: "m1",
            startedAt: Date(timeIntervalSince1970: 1),
            updatedAt: updatedAt
        )
    }

    func testImmediateCheckpointSurvivesFreshStoreInstance() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "run-checkpoint-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let writer = ConversationRunCheckpointStore()
        let value = checkpoint()
        await writer.checkpoint(value, dataDirectory: directory, immediately: true)

        let reader = ConversationRunCheckpointStore()
        let restored = await reader.checkpoint(threadID: "c1", dataDirectory: directory)
        XCTAssertEqual(restored, value)
        let attributes = try FileManager.default.attributesOfItem(
            atPath: directory.appending(path: "conversation-checkpoints.json").path
        )
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }

    func testSameThreadKeepsOnlyLatestCheckpoint() async {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "run-checkpoint-latest-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ConversationRunCheckpointStore()
        await store.checkpoint(checkpoint(run: "r1", content: "old"), dataDirectory: directory, immediately: true)
        await store.checkpoint(
            checkpoint(run: "r2", content: "new", phase: .toolCompleted, updatedAt: Date(timeIntervalSince1970: 20)),
            dataDirectory: directory,
            immediately: true
        )

        let loaded = await store.checkpoint(threadID: "c1", dataDirectory: directory)
        XCTAssertEqual(loaded?.runID, "r2")
        XCTAssertEqual(loaded?.partialContent, "new")
        XCTAssertEqual(loaded?.phase, .toolCompleted)
    }

    func testRemovePersistsCompletionAndOtherThreadsRemain() async {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "run-checkpoint-remove-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ConversationRunCheckpointStore()
        await store.checkpoint(checkpoint(thread: "c1"), dataDirectory: directory, immediately: true)
        await store.checkpoint(checkpoint(thread: "c2", run: "r2"), dataDirectory: directory, immediately: true)
        await store.remove(threadID: "c1", dataDirectory: directory)

        let reopened = ConversationRunCheckpointStore()
        let removed = await reopened.checkpoint(threadID: "c1", dataDirectory: directory)
        let kept = await reopened.checkpoint(threadID: "c2", dataDirectory: directory)
        XCTAssertNil(removed)
        XCTAssertEqual(kept?.runID, "r2")
    }

    func testDebouncedCheckpointFlushesExplicitlyOnLifecycleBoundary() async {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "run-checkpoint-flush-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ConversationRunCheckpointStore()
        await store.checkpoint(checkpoint(), dataDirectory: directory)
        await store.flush(dataDirectory: directory)

        let reopened = ConversationRunCheckpointStore()
        let restored = await reopened.checkpoint(threadID: "c1", dataDirectory: directory)
        XCTAssertNotNil(restored)
    }

    func testOlderSnapshotCannotOverwriteNewerOrResurrectClosedRun() async {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "run-checkpoint-order-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ConversationRunCheckpointStore()
        let newer = checkpoint(content: "new", updatedAt: Date(timeIntervalSince1970: 20))
        let older = checkpoint(content: "old", updatedAt: Date(timeIntervalSince1970: 10))
        await store.checkpoint(newer, dataDirectory: directory, immediately: true)
        await store.checkpoint(older, dataDirectory: directory, immediately: true)
        let retained = await store.checkpoint(threadID: "c1", dataDirectory: directory)
        XCTAssertEqual(retained?.partialContent, "new")

        await store.remove(threadID: "c1", runID: "r1", dataDirectory: directory)
        await store.checkpoint(newer, dataDirectory: directory, immediately: true)
        let resurrected = await store.checkpoint(threadID: "c1", dataDirectory: directory)
        XCTAssertNil(resurrected, "完成后晚到的 batch 不得复活 checkpoint")
    }

    func testCommitDetectionUsesLedgerSequenceBoundary() {
        let value = checkpoint()
        var ledger = ConversationLedger.bootstrap([
            ConversationTranscriptMessage(id: "u1", role: "user", content: "q", createdAt: .now),
            ConversationTranscriptMessage(id: "a1", role: "assistant", content: "old partial", createdAt: .now),
            ConversationTranscriptMessage(id: "x", role: "user", content: "x", createdAt: .now)
        ])
        XCTAssertFalse(value.wasCommitted(in: ledger), "水位线之前同 ID 的旧 partial 不算本轮完成")
        ledger = ConversationLedger.appending(
            ConversationTranscriptMessage(id: "a1", role: "assistant", content: "new final", createdAt: .now),
            to: ledger,
            eventID: "final"
        )
        XCTAssertTrue(value.wasCommitted(in: ledger))
    }

    func testSnapshotRoundTripKeepsAssistantIdentityAndToolState() {
        let value = checkpoint(phase: .interrupted)
        let snapshot = ConversationGenerationSnapshot(checkpoint: value)
        XCTAssertEqual(snapshot.conversationID, "c1")
        XCTAssertEqual(snapshot.messageID, "a1")
        XCTAssertEqual(snapshot.content, "partial")
        XCTAssertEqual(snapshot.reasoning, "reason")
        XCTAssertEqual(snapshot.agentRuns.first?.id, "call1")
        XCTAssertEqual(snapshot.phase, .failed)

        let roundTrip = snapshot.checkpoint(
            runID: value.runID,
            userMessageID: value.userMessageID,
            ledgerSequenceAtStart: value.ledgerSequenceAtStart,
            volatileContextPrompts: value.volatileContextPrompts,
            phase: .interrupted,
            now: value.updatedAt
        )
        XCTAssertEqual(roundTrip, value)
    }
}
