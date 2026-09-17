import Foundation
import XCTest
@testable import LeetCodeAssistant

final class ContextProjectionTests: XCTestCase {
    private func message(_ id: String, _ role: String, _ content: String) -> ConversationTranscriptMessage {
        ConversationTranscriptMessage(id: id, role: role, content: content, createdAt: .now)
    }

    private func settings(window: Double, reserved: Double, peak: Double, steady: Double) -> LegacySettingsSnapshot {
        var value = LegacySettingsSnapshot()
        value.contextWindowTokens = window
        value.reservedOutputTokens = reserved
        value.compressionThreshold = peak
        value.postCompressionRatio = steady
        return value
    }

    func testBudgetsDeriveFromWindowProportionsInsteadOfMessageCounts() {
        let small = ContextProjection.Budgets.resolve(settings: settings(
            window: 10_000, reserved: 2_000, peak: 0.90, steady: 0.70
        ))
        XCTAssertEqual(small.availableInputTokens, 8_000)
        XCTAssertEqual(small.peakTokens, 7_200)
        XCTAssertEqual(small.steadyTokens, 5_600)
        XCTAssertEqual(small.digestTokens, 840)
        XCTAssertEqual(small.verbatimTokens, 3_360)
        XCTAssertEqual(small.skeletonTokens, 1_400)

        let million = ContextProjection.Budgets.resolve(settings: settings(
            window: 1_048_576, reserved: 32_768, peak: 0.90, steady: 0.75
        ))
        XCTAssertEqual(million.digestTokens, 8_192, "大窗口摘要必须封顶，不能随 1M 膨胀成十几万 token")
        XCTAssertGreaterThan(million.verbatimTokens, small.verbatimTokens)
    }

    func testBelowPeakReturnsSanitizedFullProjection() {
        let source = [
            message("u1", "user", "问题"),
            message("a1", "assistant", "<think>私有</think>答案")
        ]
        let projection = ContextProjection.build(
            messages: source,
            digest: "不该在未压缩时重复注入",
            settings: settings(window: 10_000, reserved: 1_000, peak: 0.90, steady: 0.70)
        )

        XCTAssertEqual(projection.tier, .full)
        XCTAssertEqual(projection.messages.map(\.role), ["user", "assistant"])
        XCTAssertFalse(projection.messages[1].content.contains("私有"))
        XCTAssertFalse(projection.messages.contains { $0.content.contains("历史对话摘要") })
    }

    func testOverPeakUsesDigestSkeletonAndRecentVerbatimWithinSteadyBudget() {
        // 总历史会越过 peak，但最新一整个 turn 能放进 verbatim 配额；
        // 这样才能验证三层共存，而不是验证“当前 turn 独占预算”那条降级路径。
        let long = String(repeating: "算法上下文。", count: 20)
        let source = (0..<12).map { index in
            message("m\(index)", index.isMultiple(of: 2) ? "user" : "assistant", "第\(index)轮。\(long)")
        }
        let projection = ContextProjection.build(
            messages: source,
            digest: "旧结论：使用双指针。",
            settings: settings(window: 1_500, reserved: 300, peak: 0.50, steady: 0.45)
        )

        XCTAssertEqual(projection.tier, .ladder)
        XCTAssertLessThanOrEqual(projection.estimatedTokens, projection.budgets.steadyTokens)
        XCTAssertTrue(projection.messages.contains { $0.content.contains("历史对话摘要") })
        XCTAssertTrue(projection.messages.contains { $0.content.contains("较早对话骨架") })
        XCTAssertEqual(projection.messages.last?.role, "assistant")
        XCTAssertTrue(projection.messages.last?.content.contains("第11轮") == true)
    }

    func testProjectionNeverReturnsAssistantWithoutItsUserTurn() {
        let huge = String(repeating: "完整句子。", count: 120)
        let source = [
            message("u1", "user", "很早的问题。\(huge)"),
            message("a1", "assistant", "很早的答案。\(huge)"),
            message("u2", "user", "最新问题。\(huge)"),
            message("a2", "assistant", "最新答案。\(huge)")
        ]
        let projection = ContextProjection.build(
            messages: source,
            digest: "",
            settings: settings(window: 800, reserved: 200, peak: 0.50, steady: 0.45)
        )
        let conversational = projection.messages.filter { $0.role == "user" || $0.role == "assistant" }
        if let first = conversational.first {
            XCTAssertEqual(first.role, "user", "任何逐字历史必须从 user 开始")
        }
    }

    func testSingleOversizedLatestUserIsClippedOnSemanticBoundaries() {
        let sentence = "这是一个必须完整保留的句子。"
        let source = [message("u", "user", String(repeating: sentence, count: 80))]
        let projection = ContextProjection.build(
            messages: source,
            digest: "",
            settings: settings(window: 700, reserved: 200, peak: 0.50, steady: 0.45)
        )
        let content = projection.messages.last?.content ?? ""
        XCTAssertFalse(content.isEmpty)
        XCTAssertTrue(content.hasSuffix("。"), "不能在句子中间硬截")
        XCTAssertLessThanOrEqual(projection.estimatedTokens, projection.budgets.steadyTokens)
    }

    func testProjectionIsPureAndLedgerRemainsUnchanged() {
        let original = [message("u", "user", "问题"), message("a", "assistant", "答案")]
        let ledger = ConversationLedger.bootstrap(original)
        _ = ContextProjection.build(
            ledger: ledger,
            digest: "摘要",
            settings: settings(window: 600, reserved: 200, peak: 0.50, steady: 0.45)
        )
        XCTAssertEqual(ConversationLedger.project(ledger), original)
        XCTAssertEqual(ledger.count, 2)
    }
}
