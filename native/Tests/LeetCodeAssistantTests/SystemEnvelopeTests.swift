import Foundation
import XCTest
@testable import LeetCodeAssistant

/// Golden equivalence for the three transport shapes.
///
/// A long conversation carries several system turns — persona, cross-conversation RAG
/// memory, continuity, history summary and the compression notice. Chat and Responses
/// keep them inline; Messages must fold all of them into its top-level `system` field.
/// Taking only the first one silently dropped everything except the persona.
final class SystemEnvelopeTests: XCTestCase {
    private let conversation: [ChatRequestMessage] = [
        ChatRequestMessage(role: "system", content: "你是一位资深算法工程师。"),
        ChatRequestMessage(role: "system", content: "【跨会话记忆·RAG 检索结果】\n旧会话提到滑动窗口。"),
        ChatRequestMessage(role: "system", content: "【连续性提示】用户刚才在追问边界条件。"),
        ChatRequestMessage(role: "user", content: "最长无重复子串怎么做？"),
        ChatRequestMessage(role: "system", content: "【历史对话摘要】之前讨论过哈希表。"),
        ChatRequestMessage(role: "assistant", content: "用滑动窗口。"),
        ChatRequestMessage(role: "user", content: "左指针怎么移动？")
    ]

    func testMessagesEnvelopeKeepsEverySystemSectionInOrder() throws {
        let envelope = try XCTUnwrap(ChatService.systemEnvelope(from: conversation))

        XCTAssertTrue(envelope.contains("资深算法工程师"))
        XCTAssertTrue(envelope.contains("跨会话记忆"))
        XCTAssertTrue(envelope.contains("连续性提示"))
        XCTAssertTrue(envelope.contains("历史对话摘要"))

        // Order must match the logical envelope, not discovery order.
        let personaIndex = try XCTUnwrap(envelope.range(of: "资深算法工程师")).lowerBound
        let memoryIndex = try XCTUnwrap(envelope.range(of: "跨会话记忆")).lowerBound
        let continuityIndex = try XCTUnwrap(envelope.range(of: "连续性提示")).lowerBound
        let summaryIndex = try XCTUnwrap(envelope.range(of: "历史对话摘要")).lowerBound
        XCTAssertLessThan(personaIndex, memoryIndex)
        XCTAssertLessThan(memoryIndex, continuityIndex)
        XCTAssertLessThan(continuityIndex, summaryIndex)
    }

    /// The regression itself: every system section must survive the Messages transport.
    func testMessagesBodyDoesNotDropLaterSystemContext() throws {
        let body = ChatService.requestBody(
            mode: "messages",
            model: "claude-x",
            apiBase: "https://api.anthropic.com/v1",
            messages: conversation,
            reasoningLevel: .high
        )

        let system = try XCTUnwrap(body["system"] as? String)
        for marker in ["资深算法工程师", "跨会话记忆", "连续性提示", "历史对话摘要"] {
            XCTAssertTrue(system.contains(marker), "Messages dropped system context: \(marker)")
        }

        // System turns must not also appear in the message array.
        let messages = try XCTUnwrap(body["messages"] as? [[String: String]])
        XCTAssertFalse(messages.contains { $0["role"] == "system" })
        XCTAssertEqual(messages.map { $0["role"] }, ["user", "assistant", "user"])
    }

    /// All three transports must carry the same system text and the same dialogue.
    func testChatResponsesAndMessagesCarryEquivalentContext() throws {
        let chat = ChatService.requestBody(
            mode: "chat",
            model: "gpt-x",
            apiBase: "https://api.openai.com/v1",
            messages: conversation,
            reasoningLevel: .high
        )
        let responses = ChatService.requestBody(
            mode: "responses",
            model: "gpt-x",
            apiBase: "https://api.openai.com/v1",
            messages: conversation,
            reasoningLevel: .high
        )
        let messages = ChatService.requestBody(
            mode: "messages",
            model: "claude-x",
            apiBase: "https://api.anthropic.com/v1",
            messages: conversation,
            reasoningLevel: .high
        )

        func systemText(_ entries: [[String: String]]) -> String {
            entries.filter { $0["role"] == "system" }
                .compactMap { $0["content"] }
                .joined(separator: "\n\n")
        }
        func dialogue(_ entries: [[String: String]]) -> [String] {
            entries.filter { $0["role"] != "system" }.compactMap { $0["content"] }
        }

        let chatEntries = try XCTUnwrap(chat["messages"] as? [[String: String]])
        let responseEntries = try XCTUnwrap(responses["input"] as? [[String: String]])
        let messageEntries = try XCTUnwrap(messages["messages"] as? [[String: String]])
        let messagesSystem = try XCTUnwrap(messages["system"] as? String)

        XCTAssertEqual(systemText(chatEntries), messagesSystem)
        XCTAssertEqual(systemText(responseEntries), messagesSystem)
        XCTAssertEqual(dialogue(chatEntries), dialogue(messageEntries))
        XCTAssertEqual(dialogue(responseEntries), dialogue(messageEntries))
    }

    func testEnvelopeIsAbsentWhenNoSystemTurnExists() {
        let body = ChatService.requestBody(
            mode: "messages",
            model: "claude-x",
            apiBase: "https://api.anthropic.com/v1",
            messages: [ChatRequestMessage(role: "user", content: "你好")],
            reasoningLevel: .high
        )
        XCTAssertNil(body["system"])
        XCTAssertNil(ChatService.systemEnvelope(from: []))
    }

    func testBlankSystemTurnsAreSkipped() throws {
        let envelope = ChatService.systemEnvelope(from: [
            ChatRequestMessage(role: "system", content: "   \n  "),
            ChatRequestMessage(role: "system", content: "有效内容")
        ])
        XCTAssertEqual(envelope, "有效内容")
    }
}
