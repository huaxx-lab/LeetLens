import Foundation
import Testing
@testable import LeetCodeAssistant

@Suite("对话工具（ReAct）")
struct LearningAgentToolsTests {
    private actor SearchProbe {
        private var searched = false

        func markSearched() {
            searched = true
        }

        func wasSearched() -> Bool {
            searched
        }
    }

    // MARK: - 工具定义

    @Test("每个工具都有唯一名字和合法的 JSON Schema")
    func definitionsAreWellFormed() throws {
        let names = LearningAgentTools.definitions.map(\.name)
        #expect(Set(names).count == names.count)
        #expect(!names.isEmpty)

        for definition in LearningAgentTools.definitions {
            let parsed = try JSONSerialization.jsonObject(with: Data(definition.parametersJSON.utf8))
            let schema = try #require(parsed as? [String: Any])
            #expect(schema["type"] as? String == "object")
            #expect(schema["properties"] is [String: Any])
            // 描述要够长，模型是靠它决定该不该调用的。
            #expect(definition.description.count > 30)
        }
    }

    /// Responses 的函数是扁平的（type/name/parameters 同级），Chat 的要再套一层 `function`。
    /// 形状搞错的后果是模型完全收不到工具，而请求本身不会报错——很难发现。
    @Test("两种协议的工具形状各自正确")
    func wireShapesDifferPerProtocol() throws {
        let chat = try #require(LearningAgentTools.wireDefinitions.first)
        #expect(chat["type"] as? String == "function")
        let nested = try #require(chat["function"] as? [String: Any])
        #expect(nested["name"] is String)
        #expect(nested["parameters"] is [String: Any])

        let body = ChatService.requestBody(
            mode: "responses",
            model: "deepseek-v4-flash",
            apiBase: "https://api.deepseek.com",
            messages: [ChatRequestMessage(role: "user", content: "嗨")],
            reasoningLevel: .off
        )
        // 内置工具（联网搜索）仍在，我们的函数是加上去而不是顶替掉。
        let builtIn = body["tools"] as? [[String: Any]] ?? []
        #expect(builtIn.contains { $0["type"] as? String == "web_search" })
    }

    @Test("主动简报按天稳定，并复用今日安排和薄弱点卡片")
    func dailyBriefIsStableAndActionable() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(secondsFromGMT: 0))
        let date = try #require(calendar.date(from: DateComponents(year: 2026, month: 8, day: 18)))
        var snapshot = AgentDataSnapshot()
        snapshot.overdueCount = 2
        snapshot.planSummaryLine = "今天要复习 2 项、新学 1 项"
        snapshot.records = [
            .init(
                id: "record-prefix", title: "前缀和初始化", question: "", knowledgePath: "数组 › 前缀和",
                diagnosis: "忘记给 prefix[0] 留哨兵", labels: ["前缀和"], effectiveMastery: 42,
                evidenceCount: 1, isDue: true, dueCaption: "逾期 2 天", leetCodeSlug: nil,
                evidenceSummaries: [], haystack: "前缀和初始化"
            )
        ]
        snapshot.todayReviews = snapshot.records

        let first = LearningAgentTools.dailyBrief(snapshot: snapshot, now: date, calendar: calendar)
        let second = LearningAgentTools.dailyBrief(snapshot: snapshot, now: date, calendar: calendar)

        #expect(first.dayKey == "2026-08-18")
        #expect(first.messageID == second.messageID)
        #expect(first.runs.map(\.name) == ["get_today_plan", "get_weak_points"])
        #expect(first.content.contains("前缀和初始化"))
        #expect(first.content.contains("2") && first.content.contains("逾期"))
        for run in first.runs {
            let payload = try #require(
                JSONSerialization.jsonObject(with: Data(run.resultJSON.utf8)) as? [String: Any]
            )
            #expect(payload["layout"] is String)
        }
    }

    // MARK: - 流式增量归并

    @Test("Chat 的分片参数按 index 归并成一次完整调用")
    func chatDeltasAssemble() {
        var drafts: [Int: ChatService.AgentToolCallDraft] = [:]
        let fragments: [[String: Any]] = [
            ["choices": [["delta": ["tool_calls": [
                ["index": 0, "id": "call_a", "function": ["name": "search_learning_records", "arguments": "{\"que"]]
            ]]]]],
            ["choices": [["delta": ["tool_calls": [
                ["index": 0, "function": ["arguments": "ry\":\"前缀和\"}"]]
            ]]]]]
        ]
        for fragment in fragments {
            ChatService.mergeToolCallDeltas(from: fragment, into: &drafts)
        }

        let draft = drafts[0]
        #expect(draft?.id == "call_a")
        #expect(draft?.name == "search_learning_records")
        #expect(draft?.arguments == "{\"query\":\"前缀和\"}")
    }

    @Test("Responses 的 output_item 与 arguments.delta 归并成一次完整调用")
    func responsesEventsAssemble() {
        var drafts: [Int: ChatService.AgentToolCallDraft] = [:]
        let events: [[String: Any]] = [
            [
                "type": "response.output_item.added",
                "output_index": 0,
                "item": ["type": "function_call", "call_id": "fc_1", "name": "get_today_plan"]
            ],
            ["type": "response.function_call_arguments.delta", "output_index": 0, "delta": "{}"]
        ]
        for event in events {
            ChatService.mergeResponsesToolCalls(from: event, into: &drafts)
        }

        #expect(drafts[0]?.id == "fc_1")
        #expect(drafts[0]?.name == "get_today_plan")
        #expect(drafts[0]?.arguments == "{}")
    }

    /// `item_id` 和 `call_id` 不是一个东西：回灌结果时必须用 `call_id`，
    /// 用错了服务端会说找不到对应的调用。
    @Test("done 事件里的完整参数覆盖分片结果")
    func responsesDoneOverridesFragments() {
        var drafts: [Int: ChatService.AgentToolCallDraft] = [:]
        ChatService.mergeResponsesToolCalls(
            from: ["type": "response.function_call_arguments.delta", "output_index": 0, "delta": "{\"slug\":\"a"],
            into: &drafts
        )
        ChatService.mergeResponsesToolCalls(
            from: [
                "type": "response.output_item.done",
                "output_index": 0,
                "item": [
                    "type": "function_call",
                    "call_id": "fc_9",
                    "name": "read_leetcode_solution",
                    "arguments": "{\"slug\":\"abc\"}"
                ]
            ],
            into: &drafts
        )

        #expect(drafts[0]?.arguments == "{\"slug\":\"abc\"}")
        #expect(drafts[0]?.id == "fc_9")
    }

    @Test("认不出来的事件不产生调用")
    func ignoresUnrelatedEvents() {
        var drafts: [Int: ChatService.AgentToolCallDraft] = [:]
        ChatService.mergeResponsesToolCalls(
            from: ["type": "response.output_text.delta", "delta": "你好"],
            into: &drafts
        )
        ChatService.mergeToolCallDeltas(
            from: ["choices": [["delta": ["content": "你好"]]]],
            into: &drafts
        )
        #expect(drafts.isEmpty)
    }

    // MARK: - 执行

    @Test("未知工具名返回错误而不是崩掉")
    func unknownToolIsReported() async throws {
        let output = await LearningAgentTools.run(
            name: "definitely_not_a_tool",
            arguments: "{}",
            snapshot: AgentDataSnapshot(),
            memorySearch: { _ in [] },
            solutionSearch: { _ in [] },
            solutionRead: { _ in nil },
            videoSearch: { _ in [] }
        )
        let payload = try decode(output)
        #expect(payload["error"] is String)
    }

    @Test("题目解析不到时不去发网络请求")
    func solutionSearchNeedsAKnownProblem() async throws {
        let probe = SearchProbe()
        let output = await LearningAgentTools.run(
            name: "search_leetcode_solutions",
            arguments: "{\"problem\":\"根本不存在的题\"}",
            snapshot: AgentDataSnapshot(),
            memorySearch: { _ in [] },
            solutionSearch: { _ in
                await probe.markSearched()
                return []
            },
            solutionRead: { _ in nil },
            videoSearch: { _ in [] }
        )
        #expect(await !probe.wasSearched())
        let payload = try decode(output)
        #expect((payload["items"] as? [Any])?.isEmpty == true)
    }

    /// 官方题解永远排最前——它是最该先看的那一篇，浏览量再高的社区题解也不该压过它。
    @Test("官方题解排最前，其余按浏览量")
    func officialSolutionRanksFirst() async throws {
        var snapshot = AgentDataSnapshot()
        snapshot.questionIndex = [.init(slug: "two-sum", title: "两数之和")]
        let hits = [
            LearningAgentTools.SolutionHit(
                slug: "hot", title: "一行流", author: "某人",
                summary: "", views: 99_999, isOfficial: false
            ),
            LearningAgentTools.SolutionHit(
                slug: "official", title: "官方题解", author: "LeetCode-Solution",
                summary: "", views: 10, isOfficial: true
            )
        ]
        let output = await LearningAgentTools.run(
            name: "search_leetcode_solutions",
            arguments: "{\"problem\":\"两数之和\"}",
            snapshot: snapshot,
            memorySearch: { _ in [] },
            solutionSearch: { _ in hits },
            solutionRead: { _ in nil },
            videoSearch: { _ in [] }
        )

        let payload = try decode(output)
        let items = try #require(payload["items"] as? [[String: Any]])
        #expect(items.first?["slug"] as? String == "official")
        // 跳转链接要能直接点开力扣原文。
        let jumps = try #require(items.first?["jumps"] as? [[String: Any]])
        #expect(jumps.contains { ($0["id"] as? String)?.contains("two-sum/solutions/official") == true })
    }

    @Test("题解正文过长时截断并说明")
    func longArticleIsTruncated() async throws {
        let output = await LearningAgentTools.run(
            name: "read_leetcode_solution",
            arguments: "{\"slug\":\"x\"}",
            snapshot: AgentDataSnapshot(),
            memorySearch: { _ in [] },
            solutionSearch: { _ in [] },
            solutionRead: { _ in String(repeating: "字", count: 9_000) },
            videoSearch: { _ in [] }
        )
        let payload = try decode(output)
        let markdown = try #require(payload["markdown"] as? String)
        #expect(markdown.count == 6_000)
        #expect((payload["summary"] as? String)?.contains("只读了前") == true)
    }

    @Test("B 站视频结果带封面和安全的外部跳转")
    func bilibiliVideoPayloadIsRich() async throws {
        let output = await LearningAgentTools.run(
            name: "search_bilibili_videos",
            arguments: "{\"query\":\"前缀和\"}",
            snapshot: AgentDataSnapshot(),
            memorySearch: { _ in [] },
            solutionSearch: { _ in [] },
            solutionRead: { _ in nil },
            videoSearch: { _ in
                [LearningAgentTools.VideoHit(
                    bvid: "BV1abc",
                    title: "前缀和从入门到实战",
                    description: "用例题讲清楚前缀和。",
                    author: "算法老师",
                    coverURL: "https://i0.hdslb.com/bfs/archive/cover.jpg",
                    duration: "12:30",
                    playCount: 12345,
                    publishedAt: "2026-08-18"
                )]
            }
        )
        let payload = try decode(output)
        #expect(payload["layout"] as? String == "video")
        let item = try #require((payload["items"] as? [[String: Any]])?.first)
        #expect(item["thumbnail"] as? String == "https://i0.hdslb.com/bfs/archive/cover.jpg")
        let jumps = try #require(item["jumps"] as? [[String: Any]])
        #expect(jumps.first?["id"] as? String == "https://www.bilibili.com/video/BV1abc")
    }

    @Test("中文题名能解析成 slug")
    func resolvesChineseTitleToSlug() {
        var snapshot = AgentDataSnapshot()
        snapshot.questionIndex = [
            .init(slug: "subarray-sum-equals-k", title: "和为 K 的子数组"),
            .init(slug: "two-sum", title: "两数之和")
        ]
        #expect(snapshot.resolveSlug("和为 K 的子数组") == "subarray-sum-equals-k")
        #expect(snapshot.resolveSlug("two-sum") == "two-sum")
        #expect(snapshot.resolveSlug("两数") == "two-sum")
        #expect(snapshot.resolveSlug("完全没听过的题") == nil)
    }

    private func decode(_ output: LearningAgentTools.Output) throws -> [String: Any] {
        let parsed = try JSONSerialization.jsonObject(with: Data(output.json.utf8))
        return try #require(parsed as? [String: Any])
    }
}
