import Foundation
import XCTest
@testable import LeetCodeAssistant

/// 工具结果的三态契约。
///
/// 以前外部调用一律 `try?`，网络错误被吞成空数组，模型收到「暂时读不到题解」，
/// 就当成"这题没人写题解"，然后放弃或者自己编一篇。
/// **把失败伪装成空结果，比返回空更危险**：空结果可以下结论，失败不能。
final class AgentToolContractTests: XCTestCase {
    private func decode(_ json: String) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
    }

    private func run(
        _ name: String,
        arguments: String = "{}",
        solutionSearch: @escaping @Sendable (String) async -> Result<[LearningAgentTools.SolutionHit], AgentToolFailure> = { _ in .success([]) },
        solutionRead: @escaping @Sendable (String) async -> Result<String?, AgentToolFailure> = { _ in .success(nil) },
        videoSearch: @escaping @Sendable (String) async -> Result<[LearningAgentTools.VideoHit], AgentToolFailure> = { _ in .success([]) },
        limits: AgentToolBudgetLimits = .resolve(availableInputTokens: 120_000)
    ) async throws -> [String: Any] {
        let output = await LearningAgentTools.run(
            name: name,
            arguments: arguments,
            snapshot: AgentDataSnapshot(),
            memorySearch: { _ in [] },
            solutionSearch: solutionSearch,
            solutionRead: solutionRead,
            videoSearch: videoSearch,
            limits: limits
        )
        return try decode(output.json)
    }

    // MARK: - 失败与空必须可区分

    func testNetworkFailureIsReportedAsFailedAndNeverLooksLikeAnEmptyResult() async throws {
        let payload = try await run(
            "search_bilibili_videos",
            arguments: #"{"query":"接雨水"}"#,
            videoSearch: { _ in .failure(AgentToolFailure(kind: .network, attempts: 3)) }
        )
        XCTAssertEqual(payload["status"] as? String, "failed")
        let summary = payload["summary"] as? String ?? ""
        XCTAssertFalse(summary.contains("没有找到"), "失败不能说成没有")
        XCTAssertTrue(summary.contains("不要编造"))
        XCTAssertTrue(summary.contains("重试 3 次"))
    }

    func testServerErrorTellsTheModelItIsNotAnAbsenceOfData() async throws {
        let payload = try await run(
            "search_bilibili_videos",
            arguments: #"{"query":"滑动窗口"}"#,
            videoSearch: { _ in .failure(AgentToolFailure(kind: .serverError(500))) }
        )
        XCTAssertEqual(payload["status"] as? String, "failed")
        XCTAssertTrue((payload["summary"] as? String ?? "").contains("不等于没有数据"))
    }

    func testGenuineEmptyResultIsMarkedEmptySoTheModelCanConclude() async throws {
        let payload = try await run(
            "search_bilibili_videos",
            arguments: #"{"query":"根本不存在的题"}"#,
            videoSearch: { _ in .success([]) }
        )
        XCTAssertEqual(payload["status"] as? String, "empty")
        XCTAssertFalse((payload["summary"] as? String ?? "").isEmpty)
    }

    func testMissingRequiredArgumentExplainsTheCorrectShape() async throws {
        let payload = try await run("read_leetcode_solution", arguments: "{}")
        XCTAssertEqual(payload["status"] as? String, "failed")
        XCTAssertTrue((payload["summary"] as? String ?? "").contains("trapping-rain-water"))
    }

    func testUnknownToolIsAFailureWithGuidanceNotABareErrorField() async throws {
        let payload = try await run("delete_everything")
        XCTAssertEqual(payload["status"] as? String, "failed")
        XCTAssertFalse((payload["summary"] as? String ?? "").isEmpty)
    }

    /// 任何一条路径都不能给模型一个裸 `{}`：它会自己脑补。
    func testEveryToolAlwaysProducesANonEmptySummary() async throws {
        for tool in [
            "search_learning_records", "get_problem_history", "get_today_plan",
            "get_weak_points", "search_past_conversations", "get_leetcode_progress",
            "search_leetcode_solutions", "read_leetcode_solution", "search_bilibili_videos",
            "definitely_not_a_tool"
        ] {
            let payload = try await run(tool, arguments: #"{"query":"x","slug":"x","problem":"x"}"#)
            XCTAssertFalse(
                (payload["summary"] as? String ?? "").isEmpty,
                "\(tool) 返回了空 summary"
            )
            XCTAssertNotNil(payload["status"], "\(tool) 没有声明三态")
        }
    }

    // MARK: - 按窗口推导的长度预算

    func testArticleTruncationFollowsTheModelWindowInsteadOfAHardCodedLimit() async throws {
        let long = String(repeating: "题", count: 20_000)
        let wide = try await run(
            "read_leetcode_solution",
            arguments: #"{"slug":"trapping-rain-water"}"#,
            solutionRead: { _ in .success(long) },
            limits: .resolve(availableInputTokens: 120_000)
        )
        let narrow = try await run(
            "read_leetcode_solution",
            arguments: #"{"slug":"trapping-rain-water"}"#,
            solutionRead: { _ in .success(long) },
            limits: .resolve(availableInputTokens: 24_000)
        )
        let wideBody = (wide["markdown"] as? String ?? "").count
        let narrowBody = (narrow["markdown"] as? String ?? "").count
        XCTAssertGreaterThan(wideBody, narrowBody, "小窗口必须截得更短")
        XCTAssertTrue((narrow["summary"] as? String ?? "").contains("片段"), "截断后要说清这不是全文")
    }

    func testBudgetScalesWithWindowAndStaysWithinBounds() {
        let large = AgentToolBudgetLimits.resolve(availableInputTokens: 120_000)
        let small = AgentToolBudgetLimits.resolve(availableInputTokens: 6_144)
        XCTAssertGreaterThan(large.perCallTokens, small.perCallTokens)
        XCTAssertLessThanOrEqual(large.totalTokens, 24_000)
        XCTAssertGreaterThanOrEqual(small.perCallTokens, 400, "再小也要留下能用的下限")
        XCTAssertLessThanOrEqual(small.totalTokens, 6_144 / 4)
    }

    // MARK: - 计数闸

    func testPerToolFailureBudgetStopsRetryingTheSameBrokenTool() {
        var budget = AgentToolBudget()
        XCTAssertFalse(budget.isExhausted("search_leetcode_solutions"))
        for _ in 0..<AgentToolBudget.failuresPerTool {
            budget.recordFailure("search_leetcode_solutions")
        }
        XCTAssertTrue(budget.isExhausted("search_leetcode_solutions"))
        XCTAssertFalse(budget.isExhausted("get_today_plan"), "别的工具不受连累")
    }

    func testRunWideFailureBudgetStopsOfferingTools() {
        var budget = AgentToolBudget()
        for index in 0..<AgentToolBudget.failuresPerRun {
            budget.recordFailure("tool-\(index)")
        }
        XCTAssertTrue(budget.shouldStopOfferingTools)
    }

    func testExhaustedToolPayloadIsItselfAValidFailedResult() throws {
        let payload = try decode(ChatService.exhaustedToolPayload("search_leetcode_solutions"))
        XCTAssertEqual(payload["status"] as? String, "failed")
        XCTAssertTrue(ChatService.isFailedToolResult(ChatService.exhaustedToolPayload("x")))
        XCTAssertFalse(ChatService.isFailedToolResult(#"{"status":"ok","summary":"有结果"}"#))
        XCTAssertTrue(ChatService.isFailedToolResult("not json"), "解析不了必须当失败，不能当成功")
    }

    // MARK: - 运行时守卫

    /// 删 tool 消息会破坏 `tool_call_id` 配对，供应商直接 400；只能替换内容。
    func testDegradationFoldsOldestResultsWithoutBreakingToolCallPairing() {
        var messages: [[String: Any]] = [
            ["role": "system", "content": "prompt"],
            ["role": "assistant", "content": "", "tool_calls": [["id": "c1"]]],
            ["role": "tool", "tool_call_id": "c1", "content": String(repeating: "旧", count: 4_000)],
            ["role": "assistant", "content": "", "tool_calls": [["id": "c2"]]],
            ["role": "tool", "tool_call_id": "c2", "content": String(repeating: "新", count: 4_000)]
        ]
        let before = messages.count
        let didDegrade = ChatService.degradeOldestToolResults(&messages, budgetTokens: 2_000)

        XCTAssertTrue(didDegrade)
        XCTAssertEqual(messages.count, before, "消息一条都不能少")
        XCTAssertEqual(messages[2]["tool_call_id"] as? String, "c1")
        XCTAssertEqual(messages[4]["tool_call_id"] as? String, "c2")
        XCTAssertTrue((messages[2]["content"] as? String ?? "").contains("已被折叠"), "先折叠最老的")
        XCTAssertFalse((messages[4]["content"] as? String ?? "").contains("已被折叠"), "最近的证据要留着")
    }

    func testResponsesProtocolOutputsAreDegradedThroughTheirOwnField() {
        var messages: [[String: Any]] = [
            ["type": "function_call_output", "call_id": "c1", "output": String(repeating: "旧", count: 4_000)],
            ["type": "function_call_output", "call_id": "c2", "output": String(repeating: "新", count: 4_000)]
        ]
        _ = ChatService.degradeOldestToolResults(&messages, budgetTokens: 2_000)
        XCTAssertEqual(messages[0]["call_id"] as? String, "c1")
        XCTAssertTrue((messages[0]["output"] as? String ?? "").contains("已被折叠"))
    }

    func testDegradationIsANoOpWhenAlreadyWithinBudget() {
        var messages: [[String: Any]] = [
            ["role": "tool", "tool_call_id": "c1", "content": "很短"]
        ]
        let snapshot = messages
        XCTAssertFalse(ChatService.degradeOldestToolResults(&messages, budgetTokens: 10_000))
        XCTAssertEqual(messages[0]["content"] as? String, snapshot[0]["content"] as? String)
    }
}
