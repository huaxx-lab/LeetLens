import Foundation
import XCTest
@testable import LeetCodeAssistant

/// 供应商侧都是**前缀**缓存：逐字匹配，块内改一个字，本块及其后全部失效。
/// 所以规则只有一条——每轮都会变的东西必须排在最后。
///
/// 旧顺序把检索片段（最多 4 段 × 1400 字）放在第 3 位，它后面的整段历史每轮重新计费。
final class PromptCacheStabilityTests: XCTestCase {
    private func message(_ role: String, _ content: String) -> ChatRequestMessage {
        ChatRequestMessage(role: role, content: content)
    }

    // MARK: - 分段与不变量

    func testVolatileContentAlwaysSortsAfterStablePrefixAndHistory() {
        var sections = PromptAssembly.Sections()
        sections.stable = [message("system", "人设"), message("system", "身份")]
        sections.history = [message("user", "上一轮"), message("assistant", "上一轮回答")]
        sections.volatileContext = ["本轮检索片段"]

        let roles = sections.messages.map(\.role)
        XCTAssertEqual(roles, ["system", "system", "user", "assistant", PromptAssembly.volatileRole])
        XCTAssertEqual(sections.messages.last?.content, "本轮检索片段")
    }

    /// 核心不变量：不发生压缩时，前一轮的数组去掉易变块后，必须是后一轮的逐字前缀。
    func testTurnOverTurnPrefixHoldsWhenOnlyRetrievalChanges() {
        func turn(history: [ChatRequestMessage], retrieval: String) -> [ChatRequestMessage] {
            var sections = PromptAssembly.Sections()
            sections.stable = [message("system", "人设"), message("system", "长期事实")]
            sections.history = history
            sections.volatileContext = [retrieval]
            return sections.messages
        }
        let first = turn(history: [message("user", "问题一")], retrieval: "片段 A")
        let second = turn(
            history: [message("user", "问题一"), message("assistant", "回答一"), message("user", "问题二")],
            retrieval: "完全不同的片段 B"
        )
        XCTAssertTrue(
            PromptAssembly.isStablePrefix(first, of: second),
            "检索片段每轮都变，但它排在最后，不该影响前缀"
        )
    }

    func testChangingTheStablePrefixIsCorrectlyDetectedAsACacheBreak() {
        var first = PromptAssembly.Sections()
        first.stable = [message("system", "人设")]
        first.history = [message("user", "问题")]

        var second = PromptAssembly.Sections()
        second.stable = [message("system", "人设（改了一个字）")]
        second.history = [message("user", "问题")]

        XCTAssertFalse(PromptAssembly.isStablePrefix(first.messages, of: second.messages))
    }

    // MARK: - 协议落地

    /// Anthropic 的 system 是顶层字段、会被提到队首：易变块绝不能是 system。
    func testAnthropicFoldsVolatileContextIntoTheFollowingUserTurnInsteadOfTheEnvelope() {
        let messages = [
            message("system", "人设"),
            message("user", "上一轮"),
            message("assistant", "上一轮回答"),
            message(PromptAssembly.volatileRole, "本轮检索片段"),
            message("user", "本轮问题")
        ]
        let wire = ChatService.wireMessages(messages, mode: "messages")

        XCTAssertFalse(wire.contains { $0.role == PromptAssembly.volatileRole })
        let envelope = ChatService.systemEnvelope(from: wire) ?? ""
        XCTAssertFalse(envelope.contains("本轮检索片段"), "易变块进了 envelope 就被顶回队首")
        XCTAssertEqual(wire.last?.role, "user")
        XCTAssertTrue(wire.last?.content.contains("本轮检索片段") == true)
        XCTAssertTrue(wire.last?.content.contains("本轮问题") == true)
        // Anthropic 要求 user/assistant 交替，不能出现相邻同角色。
        let conversational = wire.filter { $0.role != "system" }
        XCTAssertFalse(
            zip(conversational, conversational.dropFirst()).contains { $0.role == $1.role },
            "不能产生相邻的同角色消息"
        )
    }

    func testChatProtocolKeepsVolatileContextInPlaceAsASystemTurn() {
        let messages = [
            message("system", "人设"),
            message("user", "本轮问题前的历史"),
            message(PromptAssembly.volatileRole, "本轮检索片段")
        ]
        let wire = ChatService.wireMessages(messages, mode: "chat")
        XCTAssertEqual(wire.map(\.role), ["system", "user", "system"])
        XCTAssertEqual(wire.last?.content, "本轮检索片段", "位置不能被挪到前面")
    }

    func testSystemEnvelopeIgnoresVolatileRole() {
        let envelope = ChatService.systemEnvelope(from: [
            message("system", "人设"),
            message(PromptAssembly.volatileRole, "不该进 envelope")
        ])
        XCTAssertEqual(envelope, "人设")
    }

    func testNoVolatileContentLeavesMessagesUntouched() {
        let messages = [message("system", "人设"), message("user", "问题")]
        for mode in ["chat", "responses", "messages"] {
            let wire = ChatService.wireMessages(messages, mode: mode)
            XCTAssertEqual(wire.map(\.content), messages.map(\.content), "mode=\(mode)")
        }
    }

    /// 兜底：易变块后面没有 user 消息时也不能把它丢掉。
    func testTrailingVolatileContextIsPreservedWhenNoUserTurnFollows() {
        let wire = ChatService.wireMessages([
            message("system", "人设"),
            message("user", "问题"),
            message(PromptAssembly.volatileRole, "尾部上下文")
        ], mode: "messages")
        XCTAssertTrue(wire.contains { $0.content.contains("尾部上下文") })
    }
}
