import Foundation
import XCTest
@testable import LeetCodeAssistant

/// 固定编排：指代消解 → 意图识别 → 路线分流 → 按路线执行。
/// 这里守三条不变量：规则只分类不带资源位、闲聊路线里没有 RAG 这一步、
/// 稳定前缀不随路线变化。
final class ConversationRoutingTests: XCTestCase {
    private func directory(_ titles: [String]) -> [ConversationMemoryDirectoryEntry] {
        titles.enumerated().map {
            ConversationMemoryDirectoryEntry(conversationID: "c\($0.offset)", title: $0.element, gist: "", updatedAt: .now)
        }
    }

    private func classify(
        _ q: String, titles: [String] = [], hasHostContext: Bool = false
    ) -> ConversationIntentClassification {
        ConversationIntentPolicy.classify(query: q, directory: directory(titles), hasHostContext: hasHostContext)
    }

    // MARK: - 规则层只分类

    func testCheapRulesSettleTheObviousTurnsWithoutSpendingAModelCall() {
        for q in ["你好", "hello", "谢谢", "收到"] {
            let c = classify(q)
            XCTAssertEqual(c.intent, .smalltalk, q)
            XCTAssertEqual(c.certainty, .settled, "闲聊不值得花一次模型调用：\(q)")
        }
        XCTAssertEqual(classify("你是什么模型").intent, .meta)
        XCTAssertEqual(classify("这段为什么超时", hasHostContext: true).intent, .codeDebug)
    }

    func testStrongHistoryAndPersonalCuesAreSettledByRules() {
        XCTAssertEqual(classify("帮我复盘一下").intent, .recall)
        XCTAssertEqual(classify("帮我复盘一下").certainty, .settled)
        XCTAssertEqual(classify("我哪块比较弱").intent, .profile)
        let named = classify("字母异位词分组当时是怎么做的", titles: ["字母异位词分组代码修正"])
        XCTAssertEqual(named.intent, .recall)
    }

    /// 关键：规则分不清"快排怎么写"和"先排序再用左右两个指针往中间夹"——
    /// 这一类必须交给模型，而不是挑一个方向赌。两个方向都被真实语料打脸过。
    func testRulesRefuseToGuessAndHandOffToTheModel() {
        for q in ["快排怎么写", "今天天气怎么样", "先排序再用左右两个指针往中间夹"] {
            XCTAssertEqual(classify(q).certainty, .needsModel, q)
        }
        // 指代句同样：连类别都要靠上文。
        let anaphora = classify("那这个呢")
        XCTAssertEqual(anaphora.intent, .followUp)
        XCTAssertEqual(anaphora.certainty, .needsModel)
        XCTAssertTrue(anaphora.mentionsReference)
    }

    /// 模型不可用时的先验是 knowledge——宁可不翻旧会话，也不要把无关记忆塞进回答。
    func testFallbackPriorPrefersNotTouchingHistory() {
        XCTAssertEqual(classify("今天天气怎么样").intent, .knowledge)
        XCTAssertFalse(
            ConversationRoutePlan(route: .knowledge, rerankAvailable: true).retrievesMemory
        )
    }

    // MARK: - 路线编排

    func testSmalltalkRouteHasNoRetrievalStepAtAll() {
        let plan = ConversationRoutePlan(route: .direct, rerankAvailable: true)
        XCTAssertTrue(plan.steps.isEmpty, "闲聊路线里根本不该有 RAG 这一步，而不是有但关掉")
        XCTAssertFalse(plan.retrievesMemory)
        XCTAssertFalse(plan.usesHostContext)
    }

    func testRecallRouteOrdersRetrieveThenRerankThenAdmit() {
        let plan = ConversationRoutePlan(route: .recall, rerankAvailable: true)
        XCTAssertEqual(plan.steps, [.retrieveMemory, .rerankMemory, .admitMemory])
    }

    /// 精排关掉时路线形状要如实反映当前能力，不排一个必然失败的步骤。
    func testRouteDropsRerankStepWhenRerankerIsOff() {
        let plan = ConversationRoutePlan(route: .profile, rerankAvailable: false)
        XCTAssertEqual(plan.steps, [.retrieveMemory, .admitMemory])
        XCTAssertTrue(plan.retrievesMemory)
    }

    func testEveryIntentMapsToExactlyOneRoute() {
        let expected: [ConversationIntent: ConversationRoute] = [
            .smalltalk: .direct, .meta: .direct,
            .codeDebug: .hostContext, .knowledge: .knowledge,
            .recall: .recall, .profile: .profile,
            // 消解之后 followUp 不该存活；真漏过来按 recall 兜底。
            .followUp: .recall
        ]
        for (intent, route) in expected {
            XCTAssertEqual(ConversationRoute.route(for: intent), route, "\(intent)")
        }
    }

    // MARK: - 模型输出校验

    func testModelMustReturnBothFieldsAndMayNotEmitFollowUp() throws {
        func decode(_ json: String) throws -> ConversationTurnResponse {
            try JSONDecoder().decode(ConversationTurnResponse.self, from: Data(json.utf8))
        }
        let ok = try decode(#"{"resolvedQuery":"接雨水双指针的复杂度","intent":"recall"}"#)
        let resolution = try ok.resolution(originalQuery: "这个复杂度呢")
        XCTAssertEqual(resolution.resolvedQuery, "接雨水双指针的复杂度")
        XCTAssertEqual(resolution.intent, .recall)

        // 消解是模型的职责，它不该再把 followUp 抛回来。
        XCTAssertThrowsError(
            try decode(#"{"resolvedQuery":"那这个呢","intent":"followUp"}"#).resolution(originalQuery: "那这个呢")
        )
        XCTAssertThrowsError(
            try decode(#"{"resolvedQuery":"x","intent":"不存在的类别"}"#).resolution(originalQuery: "x")
        )
        // 改写为空时退回原话，而不是拿空串去检索。
        let blank = try decode(#"{"resolvedQuery":"   ","intent":"knowledge"}"#)
        XCTAssertEqual(try blank.resolution(originalQuery: "快排怎么写").resolvedQuery, "快排怎么写")
    }

    func testTurnPlanCacheKeysByConversationAndMessage() async {
        let cache = ConversationTurnPlanCache(capacity: 2)
        let plan = ConversationTurnPlan(
            resolvedQuery: "q", intent: .knowledge,
            plan: ConversationRoutePlan(route: .knowledge, rerankAvailable: true),
            usedModel: true
        )
        let a = ConversationIntentCacheKey(conversationID: "c1", messageID: "m1")
        let b = ConversationIntentCacheKey(conversationID: "c1", messageID: "m2")
        let c = ConversationIntentCacheKey(conversationID: "c2", messageID: "m1")
        await cache.insert(plan, for: a)
        await cache.insert(plan, for: b)
        _ = await cache.value(for: a)
        await cache.insert(plan, for: c)

        let keptA = await cache.value(for: a)
        let evictedB = await cache.value(for: b)
        let keptC = await cache.value(for: c)
        XCTAssertNotNil(keptA)
        XCTAssertNil(evictedB)
        XCTAssertNotNil(keptC)
    }
}
