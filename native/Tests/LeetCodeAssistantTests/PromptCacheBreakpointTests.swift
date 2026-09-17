import Foundation
import XCTest
@testable import LeetCodeAssistant

/// Anthropic 显式缓存断点。缓存覆盖到打标记的那一块为止，所以断点必须落在
/// "每轮都逐字相同"的最后一块；标记之后的内容照常按未缓存计费。
final class PromptCacheBreakpointTests: XCTestCase {
    private func sections(
        stable: [String],
        history: [ChatRequestMessage],
        volatile: [String]
    ) -> [ChatRequestMessage] {
        var value = PromptAssembly.Sections()
        value.stable = stable.map { ChatRequestMessage(role: "system", content: $0) }
        value.history = history
        value.volatileContext = volatile
        return value.messages
    }

    private func body(_ messages: [ChatRequestMessage]) -> [String: Any] {
        ChatService.requestBody(
            mode: "messages",
            model: "claude-opus-5",
            apiBase: "https://api.anthropic.com/v1",
            messages: messages,
            reasoningLevel: .high
        )
    }

    private func breakpointIndices(_ entries: [[String: Any]]) -> [Int] {
        entries.enumerated().compactMap { index, entry in
            guard let blocks = entry["content"] as? [[String: Any]],
                  blocks.contains(where: { $0["cache_control"] != nil })
            else { return nil }
            return index
        }
    }

    func testSystemCarriesExactlyOneBreakpointOnItsLastBlock() throws {
        let body = body(sections(
            stable: ["人设", "长期事实", "会话目录"],
            history: [ChatRequestMessage(role: "user", content: "问题")],
            volatile: ["【检索片段】旧会话"]
        ))
        let blocks = try XCTUnwrap(body["system"] as? [[String: Any]])

        XCTAssertEqual(blocks.compactMap { $0["text"] as? String }, ["人设", "长期事实", "会话目录"])
        XCTAssertEqual(blocks.filter { $0["cache_control"] != nil }.count, 1)
        XCTAssertNotNil(blocks.last?["cache_control"])
        XCTAssertEqual(blocks.last?["cache_control"] as? [String: String], ["type": "ephemeral"])
    }

    func testMessageBreakpointSitsBeforeVolatileContext() throws {
        let body = body(sections(
            stable: ["人设"],
            history: [
                ChatRequestMessage(role: "user", content: "第一问"),
                ChatRequestMessage(role: "assistant", content: "第一答"),
                ChatRequestMessage(role: "user", content: "第二问")
            ],
            volatile: ["【检索片段】每轮都不同", "【当前代码】每轮都不同"]
        ))
        let entries = try XCTUnwrap(body["messages"] as? [[String: Any]])
        let marked = breakpointIndices(entries)

        XCTAssertEqual(marked.count, 1, "消息数组只应有一个断点")
        let index = try XCTUnwrap(marked.first)
        let markedText = try XCTUnwrap(
            (entries[index]["content"] as? [[String: Any]])?.first?["text"] as? String
        )
        XCTAssertEqual(markedText, "第二问", "断点落在本轮用户问题上")

        // 断点之后只能是易变内容，且绝不能被算进缓存前缀。
        let after = entries.dropFirst(index + 1)
        XCTAssertEqual(after.count, 1)
        let tail = try XCTUnwrap(after.first?["content"] as? String)
        XCTAssertTrue(tail.contains("每轮都不同"))
        XCTAssertFalse(markedText.contains("每轮都不同"), "易变内容混进断点会让缓存永远不命中")
    }

    /// 真正的回归门：下一轮把这轮的问答并入历史后，被缓存的前缀必须逐字不变。
    func testCachedPrefixIsByteIdenticalOnTheFollowingTurn() throws {
        let stable = ["人设", "会话目录"]
        let turnOne = body(sections(
            stable: stable,
            history: [ChatRequestMessage(role: "user", content: "第一问")],
            volatile: ["【检索片段】第一轮"]
        ))
        let turnTwo = body(sections(
            stable: stable,
            history: [
                ChatRequestMessage(role: "user", content: "第一问"),
                ChatRequestMessage(role: "assistant", content: "第一答"),
                ChatRequestMessage(role: "user", content: "第二问")
            ],
            volatile: ["【检索片段】第二轮完全不同"]
        ))

        func cachedPrefix(_ body: [String: Any]) throws -> [String] {
            let system = try XCTUnwrap(body["system"] as? [[String: Any]])
                .compactMap { $0["text"] as? String }
            let entries = try XCTUnwrap(body["messages"] as? [[String: Any]])
            let cutoff = try XCTUnwrap(breakpointIndices(entries).first)
            let dialogue = entries.prefix(cutoff + 1).compactMap { entry -> String? in
                if let text = entry["content"] as? String { return text }
                return (entry["content"] as? [[String: Any]])?.first?["text"] as? String
            }
            return system + dialogue
        }

        let first = try cachedPrefix(turnOne)
        let second = try cachedPrefix(turnTwo)
        XCTAssertEqual(first, ["人设", "会话目录", "第一问"])
        XCTAssertEqual(Array(second.prefix(first.count)), first, "第二轮必须能整段命中第一轮写入的缓存")
    }

    func testTotalBreakpointsStayWithinTheFourAllowed() throws {
        let body = body(sections(
            stable: ["人设", "身份", "长期事实", "会话目录", "历史摘要"],
            history: (0..<12).map {
                ChatRequestMessage(role: $0.isMultiple(of: 2) ? "user" : "assistant", content: "第\($0)轮")
            },
            volatile: ["【检索片段】", "【当前代码】", "【衔接说明】"]
        ))
        let system = try XCTUnwrap(body["system"] as? [[String: Any]])
        let entries = try XCTUnwrap(body["messages"] as? [[String: Any]])
        let total = system.filter { $0["cache_control"] != nil }.count + breakpointIndices(entries).count

        XCTAssertLessThanOrEqual(total, 4, "官方上限 4 个断点，超了整个请求 400")
        XCTAssertEqual(total, 2)
    }

    func testConversationWithoutHistoryOnlyMarksSystem() throws {
        let body = body(sections(
            stable: ["人设"],
            history: [],
            volatile: ["【当前代码】"]
        ))
        let system = try XCTUnwrap(body["system"] as? [[String: Any]])
        let entries = try XCTUnwrap(body["messages"] as? [[String: Any]])

        XCTAssertEqual(system.filter { $0["cache_control"] != nil }.count, 1)
        XCTAssertTrue(breakpointIndices(entries).isEmpty, "只有易变内容时没有可缓存的消息前缀")
        XCTAssertEqual(entries.count, 1)
    }

    /// 线上 400 的那条：`role:"context"` 是 PromptAssembly 的内部标记，供应商全都不认。
    /// requestBody 一直转换得好好的，但 ReAct 循环自己从原始 messages 建了一份线格式，
    /// 又在 makeRequest 里把转换结果覆盖掉，于是每一轮都把 context 原样发出去。
    func testInternalContextRoleNeverReachesTheWire() throws {
        let messages = sections(
            stable: ["人设"],
            history: [
                ChatRequestMessage(role: "user", content: "问题"),
                ChatRequestMessage(role: "assistant", content: "回答")
            ],
            volatile: ["【检索片段】旧会话", "【当前代码】class Solution {}"]
        )
        for mode in ["chat", "responses", "messages"] {
            let wire = ChatService.wireFormat(messages, mode: mode)
            XCTAssertFalse(
                wire.contains { $0["role"] as? String == PromptAssembly.volatileRole },
                "\(mode) 把内部 context 角色发出去了"
            )
            // 易变内容本身不能丢：它只是换了承载方式，不是被删掉。
            let serialized = String(
                decoding: try JSONSerialization.data(withJSONObject: wire),
                as: UTF8.self
            )
            XCTAssertTrue(serialized.contains("检索片段"), mode)
            XCTAssertTrue(serialized.contains("当前代码"), mode)
        }
    }

    /// ReAct 循环在 `wireFormat` 的结果上追加 tool 消息，再用它覆盖 requestBody 的 messages。
    /// 两者形状必须逐字一致，否则第一轮就会把转换好的内容换成没转换的。
    func testReActWireFormatMatchesRequestBodyExactly() throws {
        let messages = sections(
            stable: ["人设"],
            history: [ChatRequestMessage(role: "user", content: "问题")],
            volatile: ["【检索片段】"]
        )
        for (mode, key) in [("chat", "messages"), ("responses", "input"), ("messages", "messages")] {
            let body = ChatService.requestBody(
                mode: mode,
                model: "m",
                apiBase: mode == "messages" ? "https://api.anthropic.com/v1" : "https://api.openai.com/v1",
                messages: messages,
                reasoningLevel: .high
            )
            let fromBody = try JSONSerialization.data(
                withJSONObject: try XCTUnwrap(body[key]), options: [.sortedKeys]
            )
            let fromWire = try JSONSerialization.data(
                withJSONObject: ChatService.wireFormat(messages, mode: mode), options: [.sortedKeys]
            )
            XCTAssertEqual(fromBody, fromWire, "\(mode) 的两条线格式已经漂移")
        }
    }

    /// 非 Anthropic 协议自己做自动前缀缓存，不接受 cache_control，误发会直接报错。
    func testOtherTransportsNeverEmitCacheControl() throws {
        let messages = sections(
            stable: ["人设"],
            history: [ChatRequestMessage(role: "user", content: "问题")],
            volatile: ["【检索片段】"]
        )
        for mode in ["chat", "responses"] {
            let body = ChatService.requestBody(
                mode: mode,
                model: "gpt-x",
                apiBase: "https://api.openai.com/v1",
                messages: messages,
                reasoningLevel: .high
            )
            let serialized = String(
                decoding: try JSONSerialization.data(withJSONObject: body),
                as: UTF8.self
            )
            XCTAssertFalse(serialized.contains("cache_control"), mode)
        }
    }
}
