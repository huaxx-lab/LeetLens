import Foundation
import XCTest
@testable import LeetCodeAssistant

final class ConversationLedgerTests: XCTestCase {
    private func message(_ id: String, _ role: String, _ content: String) -> ConversationTranscriptMessage {
        ConversationTranscriptMessage(id: id, role: role, content: content, createdAt: .now)
    }

    func testAppendOnlyReducerAppendsNewIDsAndReplacesSameIDInPlace() {
        let original = [message("u1", "user", "问题"), message("a1", "assistant", "旧答案")]
        var ledger = ConversationLedger.bootstrap(original)
        ledger = ConversationLedger.appending(
            message("a1", "assistant", "新答案"),
            to: ledger,
            eventID: "revision",
            recordedAt: Date(timeIntervalSince1970: 2)
        )
        ledger = ConversationLedger.appending(
            message("u2", "user", "追问"),
            to: ledger,
            eventID: "new",
            recordedAt: Date(timeIntervalSince1970: 3)
        )

        XCTAssertEqual(ledger.count, 4, "修订只能追加事件，不能改掉旧事件")
        XCTAssertEqual(ledger[1].message?.content, "旧答案")
        XCTAssertEqual(ConversationLedger.project(ledger).map(\.id), ["u1", "a1", "u2"])
        XCTAssertEqual(ConversationLedger.project(ledger)[1].content, "新答案")
    }

    func testTombstoneRemovesProjectionWithoutDeletingHistory() {
        var ledger = ConversationLedger.bootstrap([
            message("u1", "user", "问题"),
            message("a1", "assistant", "答案")
        ])
        ledger = ConversationLedger.removing(messageID: "a1", from: ledger, eventID: "remove")

        XCTAssertEqual(ledger.count, 3)
        XCTAssertEqual(ledger[1].message?.content, "答案", "历史事实仍在 ledger")
        XCTAssertEqual(ConversationLedger.project(ledger).map(\.id), ["u1"])
    }

    func testChangedMessagesUsesSequenceAndReturnsLatestRevisionOnce() {
        var ledger = ConversationLedger.bootstrap([message("u1", "user", "问题")])
        ledger = ConversationLedger.appending(message("a1", "assistant", "草稿"), to: ledger, eventID: "e2")
        ledger = ConversationLedger.appending(message("a1", "assistant", "最终"), to: ledger, eventID: "e3")
        ledger = ConversationLedger.removing(messageID: "gone", from: ledger, eventID: "e4")

        let changed = ConversationLedger.changedMessages(after: 1, in: ledger)
        XCTAssertEqual(changed.map(\.id), ["a1"])
        XCTAssertEqual(changed.first?.content, "最终")
        XCTAssertEqual(ConversationLedger.latestSequence(ledger), 4)
    }

    @MainActor
    func testExternalLegacyClientAppendIsImportedWithoutOverwritingKnownIDs() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "ledger-external-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let seed = LegacyDataStore(dataDirectory: directory)
        let id = try seed.createConversation(
            title: "共享",
            firstMessage: message("u1", "user", "native 原话")
        )

        let url = directory.appending(path: "conversations.json")
        var root = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        var raw = try XCTUnwrap(root[id] as? [String: Any])
        raw["messages"] = [
            ["id": "u1", "role": "user", "content": "旧客户端试图覆盖", "createdAt": 1_800_000_000_000],
            ["id": "a1", "role": "assistant", "content": "旧客户端新增", "createdAt": 1_800_000_001_000]
        ]
        root[id] = raw
        try JSONSerialization.data(withJSONObject: root).write(to: url)

        let reopened = LegacyDataStore(dataDirectory: directory)
        await reopened.hydrate()
        XCTAssertEqual(reopened.conversations.first?.messages.map(\.content), ["native 原话", "旧客户端新增"])
    }

    @MainActor
    func testArchiveCompareAndSetRejectsOutOfOrderCompletion() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "archive-cas-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = LegacyDataStore(dataDirectory: directory)
        let id = try store.createConversation(title: "摘要", firstMessage: message("u1", "user", "问题"))
        let first = ConversationArchiveSummary(title: "新标题", summary: "第一版", context: "上下文一")
        let applied = try store.applyArchive(
            first,
            to: id,
            coveredLedgerSequence: 1,
            expectedPreviousSequence: 0,
            messageCount: 1,
            renames: true
        )
        XCTAssertTrue(applied)

        let stale = try store.applyArchive(
            .init(title: "旧标题", summary: "过期", context: "过期上下文"),
            to: id,
            coveredLedgerSequence: 1,
            expectedPreviousSequence: 0,
            messageCount: 1,
            renames: true
        )
        XCTAssertFalse(stale)
        XCTAssertEqual(store.conversations.first?.aiSummary, "第一版")
        XCTAssertEqual(store.conversations.first?.archivedLedgerSequence, 1)
    }

    @MainActor
    func testLegacyConversationMigratesAtomicallyOnFirstMutation() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "ledger-migration-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let legacy: [String: Any] = [
            "legacy": [
                "schemaVersion": 3,
                "title": "旧会话",
                "updatedAt": 1_800_000_000_000,
                "messages": [
                    ["id": "u1", "role": "user", "content": "旧问题", "createdAt": 1_800_000_000_000],
                    ["id": "a1", "role": "assistant", "content": "旧答案", "createdAt": 1_800_000_001_000]
                ]
            ]
        ]
        try JSONSerialization.data(withJSONObject: legacy)
            .write(to: directory.appending(path: "conversations.json"))

        let store = LegacyDataStore(dataDirectory: directory)
        await store.hydrate()
        XCTAssertEqual(store.conversations.first?.messages.map(\.content), ["旧问题", "旧答案"])
        XCTAssertEqual(store.conversations.first?.ledgerEvents.count, 2, "只读加载在内存中 bootstrap")

        try store.upsertMessage(message("a1", "assistant", "修订答案"), in: "legacy")
        let root = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: directory.appending(path: "conversations.json")))
                as? [String: Any]
        )
        let raw = try XCTUnwrap(root["legacy"] as? [String: Any])
        XCTAssertEqual((raw["schemaVersion"] as? NSNumber)?.intValue, 4)
        XCTAssertEqual((raw["ledgerEvents"] as? [[String: Any]])?.count, 3)
        XCTAssertEqual((raw["messages"] as? [[String: Any]])?.count, 2, "legacy messages 只是当前物化缓存")

        let reopened = LegacyDataStore(dataDirectory: directory)
        await reopened.hydrate()
        XCTAssertEqual(reopened.conversations.first?.messages.map(\.content), ["旧问题", "修订答案"])
        XCTAssertEqual(reopened.conversations.first?.ledgerEvents.count, 3)
    }
}
