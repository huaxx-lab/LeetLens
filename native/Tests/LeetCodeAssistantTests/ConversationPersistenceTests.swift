import Foundation
import XCTest
@testable import LeetCodeAssistant

/// 线上现象：第二轮问答输出完整条消失，磁盘 ledger 只剩第一轮。
/// 这里把"发送 → 生成 → 再发送 → 再生成"完整跑一遍，逐轮校验落盘与投影。
final class ConversationPersistenceTests: XCTestCase {
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "persistence-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func message(_ id: String, _ role: String, _ content: String) -> ConversationTranscriptMessage {
        ConversationTranscriptMessage(id: id, role: role, content: content, createdAt: .now)
    }

    private func onDisk(_ directory: URL, _ conversationID: String) throws -> (ledger: Int, messages: [String]) {
        let data = try Data(contentsOf: directory.appending(path: "conversations.json"))
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let c = try XCTUnwrap(root[conversationID] as? [String: Any])
        let events = (c["ledgerEvents"] as? [[String: Any]])?.count ?? 0
        let msgs = (c["messages"] as? [[String: Any]])?.compactMap { $0["id"] as? String } ?? []
        return (events, msgs)
    }

    @MainActor
    func testTwoFullTurnsAllSurviveOnDiskAndInMemory() async throws {
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = LegacyDataStore(dataDirectory: dir)

        // 第一轮
        let cid = try store.createConversation(title: "你好", firstMessage: message("u1", "user", "你好"))
        try store.upsertMessage(message("a1", "assistant", "第一轮回答"), in: cid)
        var disk = try onDisk(dir, cid)
        XCTAssertEqual(disk.ledger, 2, "第一轮：ledger 应有 2 条事件")
        XCTAssertEqual(disk.messages, ["u1", "a1"])

        // 第一轮结束后会异步归档，这里模拟它写入摘要与水位线
        _ = try store.applyArchive(
            .init(title: "打招呼", summary: "s", context: "c"),
            to: cid, coveredLedgerSequence: 2, expectedPreviousSequence: 0,
            messageCount: 2, renames: true
        )

        // 第二轮
        try store.appendMessage(message("u2", "user", "你好"), to: cid)
        disk = try onDisk(dir, cid)
        XCTAssertEqual(disk.ledger, 3, "第二条用户消息没落盘")
        XCTAssertEqual(disk.messages, ["u1", "a1", "u2"])

        try store.upsertMessage(message("a2", "assistant", "第二轮回答"), in: cid)
        disk = try onDisk(dir, cid)
        XCTAssertEqual(disk.ledger, 4, "第二轮回答没落盘")
        XCTAssertEqual(disk.messages, ["u1", "a1", "u2", "a2"])

        // 内存投影必须和磁盘一致
        let memory = try XCTUnwrap(store.conversations.first { $0.id == cid })
        XCTAssertEqual(memory.messages.map(\.id), ["u1", "a1", "u2", "a2"], "内存投影丢了消息")

        // 重开一份 store：从磁盘重新投影也必须一致
        let reopened = LegacyDataStore(dataDirectory: dir)
        await reopened.hydrate()
        let restored = try XCTUnwrap(reopened.conversations.first { $0.id == cid })
        XCTAssertEqual(restored.messages.map(\.id), ["u1", "a1", "u2", "a2"], "重开后丢了消息")
        XCTAssertEqual(restored.messages.map(\.content), ["你好", "第一轮回答", "你好", "第二轮回答"])
    }
}
