import Foundation

/// 对话侧的 **ReAct 工具集**：把本地学习档案暴露成模型能主动调用的函数。
///
/// 和 `ProviderBuiltInTools` 是两回事——那边是供应商后端自己跑的联网搜索，
/// 我们只声明、不执行；这边的每一个工具都由客户端读本地数据现算，模型拿到
/// 结果后再决定要不要接着查。所以它走 Chat Completions 的 `tools`，
/// 而不是 Responses 那条只有少数型号支持的链路。
///
/// **只读**。写学习档案的路径一律不放进来：`learning.json` / `study-plan.json`
/// 与 Electron 版共用同一份文件且没有文件锁，让模型无确认地写进去，
/// 出问题时既难发现也难回滚。
enum LearningAgentTools {
    // MARK: - 结果

    /// 一次工具调用的产物。同一份 JSON 同时喂给模型和界面——
    /// 卡片上显示的就是模型看到的东西，不存在"界面好看但模型看到的是另一套"。
    struct Output: Sendable {
        /// 结果 JSON。同时是喂给模型的 tool 消息体和界面渲染卡片的数据源。
        let json: String

        init(payload: [String: Any]) {
            guard let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]) else {
                json = "{}"
                return
            }
            json = String(decoding: data, as: UTF8.self)
        }
    }

    /// 卡片布局提示。六个工具共用一套 item 结构，靠这个字段挑渲染方式，
    /// 比六套各写一遍好维护，也保证新增工具时界面不用跟着改。
    enum Layout: String, Sendable {
        /// 逐条列表：标题 + 副标题 + 正文 + 徽章 + 跳转
        case list
        /// 时间线：带序号，用于多次提交这种有先后的东西
        case timeline
        /// 指标条：只有数字
        case metrics
        /// 计划清单：带完成状态的勾选行
        case checklist
    }

    // MARK: - 定义

    struct Definition: Sendable {
        let name: String
        let title: String
        let description: String
        /// JSON Schema 的序列化形式。存字符串而不是 `[String: Any]`：
        /// 字典不是 Sendable，而定义是全局常量，要能安全跨线程读。
        let parametersJSON: String

        var wireFormat: [String: Any] {
            let parameters = (try? JSONSerialization.jsonObject(with: Data(parametersJSON.utf8)))
                as? [String: Any] ?? ["type": "object", "properties": [:]]
            return [
                "type": "function",
                "function": [
                    "name": name,
                    "description": description,
                    "parameters": parameters
                ]
            ]
        }
    }

    private static func schema(_ properties: [String: Any], required: [String] = []) -> String {
        let object: [String: Any] = ["type": "object", "properties": properties, "required": required]
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else {
            return #"{"type":"object","properties":{}}"#
        }
        return String(decoding: data, as: UTF8.self)
    }

    static let definitions: [Definition] = [
        Definition(
            name: "search_learning_records",
            title: "学习题库",
            description: """
            在用户本地的学习题库里检索学习项，返回掌握度、当前诊断（用户在这个知识点上具体犯过什么错）、\
            标签、复习到期时间与最近的学习证据。回答任何与用户过往学习情况相关的问题前都应该先调用它，\
            例如"我以前在这块犯过什么错""这个知识点我掌握得怎么样"。query 用中文知识点或题目名。
            """,
            parametersJSON: schema(
                [
                    "query": ["type": "string", "description": "知识点、题目名或标签，中文即可"],
                    "limit": ["type": "integer", "description": "最多返回几条，默认 5，上限 10"]
                ],
                required: ["query"]
            )
        ),
        Definition(
            name: "get_problem_history",
            title: "刷题历史",
            description: """
            查用户在某道 LeetCode 题上的真实提交轨迹：提交了几次、每次的判定结果与运行数据，\
            以及已经算好的 AI 轨迹分析（每次错在哪、改了什么、最后怎么过的）。\
            当用户问某道具体题目时调用。query 传题目名或 slug。
            """,
            parametersJSON: schema(
                ["query": ["type": "string", "description": "题目标题或 titleSlug"]],
                required: ["query"]
            )
        ),
        Definition(
            name: "get_today_plan",
            title: "今日安排",
            description: """
            返回今天的复习队列（已按 FSRS 到期时间与配额排好序）、今天的学习计划任务，以及逾期/待巩固的条数。\
            用户问"今天该做什么""有什么要复习的""我的安排"时调用。
            """,
            parametersJSON: schema([:])
        ),
        Definition(
            name: "get_weak_points",
            title: "薄弱点",
            description: """
            返回当前最该补的知识点：按遗忘曲线折算后的掌握度从低到高，附带诊断与到期情况。\
            用户问"我哪里最弱""该练什么"时调用。
            """,
            parametersJSON: schema(
                ["limit": ["type": "integer", "description": "最多返回几条，默认 5，上限 10"]]
            )
        ),
        Definition(
            name: "search_past_conversations",
            title: "历史对话",
            description: """
            在用户过往的对话记录里做语义检索，返回相关片段。\
            当用户提到"我之前问过""上次说的"，或需要确认此前讨论过的结论时调用。
            """,
            parametersJSON: schema(
                ["query": ["type": "string"]],
                required: ["query"]
            )
        ),
        Definition(
            name: "get_leetcode_progress",
            title: "刷题进度",
            description: """
            返回题单进度、已通过/尝试过的题数、最近提交与难度分布。\
            用户问整体进度、刷了多少题时调用。
            """,
            parametersJSON: schema([:])
        )
    ]

    static var wireDefinitions: [[String: Any]] { definitions.map(\.wireFormat) }

    static func definition(named name: String) -> Definition? {
        definitions.first { $0.name == name }
    }

    // MARK: - 执行

    /// 工具跑在数据快照上，不碰 `LegacyDataStore`。
    /// 快照在主线程构造一次，之后整个 ReAct 循环都用它——
    /// 中途数据变了也不要紧，一轮对话里模型看到的世界应当是一致的。
    static func run(
        name: String,
        arguments: String,
        snapshot: AgentDataSnapshot,
        memorySearch: @Sendable (String) async -> [AgentDataSnapshot.MemoryMatch]
    ) async -> Output {
        let parsed = parseArguments(arguments)
        switch name {
        case "search_learning_records":
            return searchLearningRecords(query: parsed.string("query"), limit: parsed.limit, snapshot: snapshot)
        case "get_problem_history":
            return problemHistory(query: parsed.string("query"), snapshot: snapshot)
        case "get_today_plan":
            return todayPlan(snapshot: snapshot)
        case "get_weak_points":
            return weakPoints(limit: parsed.limit, snapshot: snapshot)
        case "search_past_conversations":
            let matches = await memorySearch(parsed.string("query"))
            return pastConversations(query: parsed.string("query"), matches: matches)
        case "get_leetcode_progress":
            return leetCodeProgress(snapshot: snapshot)
        default:
            return Output(payload: [
                "tool": name,
                "title": "未知工具",
                "layout": Layout.list.rawValue,
                "error": "没有名为 \(name) 的工具"
            ])
        }
    }

    private struct Arguments {
        let raw: [String: Any]
        func string(_ key: String) -> String {
            (raw[key] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        }
        var limit: Int {
            let value = (raw["limit"] as? Int) ?? Int(raw["limit"] as? String ?? "") ?? 5
            return min(max(value, 1), 10)
        }
    }

    private static func parseArguments(_ arguments: String) -> Arguments {
        guard let data = arguments.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return Arguments(raw: [:]) }
        return Arguments(raw: object)
    }

    // MARK: - 各工具

    private static func searchLearningRecords(
        query: String,
        limit: Int,
        snapshot: AgentDataSnapshot
    ) -> Output {
        let hits = snapshot.rankedRecords(matching: query).prefix(limit)
        let items = hits.map { record -> [String: Any] in
            var badges: [[String: Any]] = [badge("掌握度 \(Int(record.effectiveMastery))%", tone: masteryTone(record.effectiveMastery))]
            if record.isDue { badges.append(badge(record.dueCaption, tone: "warn")) }
            if record.evidenceCount > 0 { badges.append(badge("证据 \(record.evidenceCount)", tone: "plain")) }
            return [
                "title": record.title,
                "subtitle": record.knowledgePath,
                "detail": record.diagnosis.isEmpty ? "还没有诊断，等更多学习证据" : record.diagnosis,
                "badges": badges,
                "jumps": recordJumps(record)
            ]
        }
        return Output(payload: [
            "tool": "search_learning_records",
            "title": "学习题库",
            "layout": Layout.list.rawValue,
            "query": query,
            "summary": items.isEmpty
                ? "题库里没有和「\(query)」相关的学习项"
                : "找到 \(items.count) 条与「\(query)」相关的学习项",
            "items": Array(items)
        ])
    }

    private static func problemHistory(query: String, snapshot: AgentDataSnapshot) -> Output {
        guard let problem = snapshot.problem(matching: query) else {
            return Output(payload: [
                "tool": "get_problem_history",
                "title": "刷题历史",
                "layout": Layout.list.rawValue,
                "query": query,
                "summary": "没有找到「\(query)」的提交记录",
                "items": []
            ])
        }

        var items: [[String: Any]] = []
        for (index, attempt) in problem.attempts.enumerated() {
            var badges: [[String: Any]] = []
            if !attempt.verdict.isEmpty {
                badges.append(badge(attempt.verdict, tone: attempt.accepted ? "good" : "warn"))
            }
            if !attempt.language.isEmpty { badges.append(badge(attempt.language, tone: "plain")) }
            items.append([
                "index": index + 1,
                "title": attempt.issue.isEmpty ? attempt.verdict : attempt.issue,
                "subtitle": attempt.change,
                "detail": attempt.outcome,
                "badges": badges,
                "jumps": []
            ])
        }

        var payload: [String: Any] = [
            "tool": "get_problem_history",
            "title": "刷题历史",
            "layout": Layout.timeline.rawValue,
            "query": query,
            "summary": problem.summaryLine,
            "items": items,
            "jumps": problem.jumps.map(\.dictionary)
        ]
        if !problem.analysisSummary.isEmpty { payload["note"] = problem.analysisSummary }
        if !problem.weaknesses.isEmpty { payload["weaknesses"] = problem.weaknesses }
        if !problem.improvements.isEmpty { payload["improvements"] = problem.improvements }
        return Output(payload: payload)
    }

    private static func todayPlan(snapshot: AgentDataSnapshot) -> Output {
        var items: [[String: Any]] = []
        for record in snapshot.todayReviews {
            items.append([
                "title": record.title,
                "subtitle": record.knowledgePath,
                "detail": record.diagnosis,
                "done": false,
                "badges": [
                    badge(record.isDue ? record.dueCaption : "待复习", tone: record.isDue ? "warn" : "plain"),
                    badge("掌握度 \(Int(record.effectiveMastery))%", tone: masteryTone(record.effectiveMastery))
                ],
                "jumps": recordJumps(record)
            ])
        }
        for task in snapshot.todayTasks {
            items.append([
                "title": task.title,
                "subtitle": task.timeCaption,
                "detail": task.notes,
                "done": task.isCompleted,
                "badges": [badge(task.priorityLabel, tone: task.priorityTone)],
                "jumps": [["kind": "plan", "id": "", "label": "打开学习计划"]]
            ])
        }
        return Output(payload: [
            "tool": "get_today_plan",
            "title": "今日安排",
            "layout": Layout.checklist.rawValue,
            "summary": snapshot.planSummaryLine,
            "metrics": [
                ["label": "今日复习", "value": snapshot.todayReviews.count],
                ["label": "计划任务", "value": snapshot.todayTasks.count],
                ["label": "已逾期", "value": snapshot.overdueCount],
                ["label": "待巩固", "value": snapshot.weakCount]
            ],
            "items": items,
            "jumps": [
                ["kind": "review", "id": "", "label": "去今日复习"],
                ["kind": "plan", "id": "", "label": "看学习计划"]
            ]
        ])
    }

    private static func weakPoints(limit: Int, snapshot: AgentDataSnapshot) -> Output {
        let items = snapshot.weakest(limit: limit).map { record -> [String: Any] in
            [
                "title": record.title,
                "subtitle": record.knowledgePath,
                "detail": record.diagnosis,
                "badges": [
                    badge("掌握度 \(Int(record.effectiveMastery))%", tone: masteryTone(record.effectiveMastery)),
                    badge(record.isDue ? record.dueCaption : "未到期", tone: record.isDue ? "warn" : "plain")
                ],
                "jumps": recordJumps(record)
            ]
        }
        return Output(payload: [
            "tool": "get_weak_points",
            "title": "薄弱点",
            "layout": Layout.list.rawValue,
            "summary": items.isEmpty ? "题库里还没有足够的学习项" : "掌握度最低的 \(items.count) 项",
            "items": items
        ])
    }

    private static func pastConversations(
        query: String,
        matches: [AgentDataSnapshot.MemoryMatch]
    ) -> Output {
        let items = matches.map { match -> [String: Any] in
            [
                "title": match.title,
                "subtitle": match.dateCaption,
                "detail": match.excerpt,
                "badges": [],
                "jumps": [["kind": "conversation", "id": match.conversationID, "label": "打开这段对话"]]
            ]
        }
        return Output(payload: [
            "tool": "search_past_conversations",
            "title": "历史对话",
            "layout": Layout.list.rawValue,
            "query": query,
            "summary": items.isEmpty ? "没有检索到相关的历史对话" : "检索到 \(items.count) 段相关对话",
            "items": items
        ])
    }

    private static func leetCodeProgress(snapshot: AgentDataSnapshot) -> Output {
        Output(payload: [
            "tool": "get_leetcode_progress",
            "title": "刷题进度",
            "layout": Layout.metrics.rawValue,
            "summary": snapshot.progressSummaryLine,
            "metrics": snapshot.progressMetrics.map(\.dictionary),
            "items": snapshot.planProgress.map { plan -> [String: Any] in
                [
                    "title": plan.name,
                    "subtitle": "\(plan.solved)/\(plan.total)",
                    "detail": "",
                    "badges": [["text": "\(plan.percent)%", "tone": "plain"]],
                    "jumps": [["kind": "leetcode", "id": "", "label": "打开题单"]]
                ]
            },
            "jumps": [["kind": "leetcode", "id": "", "label": "打开刷题页"]]
        ])
    }

    // MARK: - 小工具

    private static func badge(_ text: String, tone: String) -> [String: Any] {
        ["text": text, "tone": tone]
    }

    private static func masteryTone(_ value: Double) -> String {
        if value >= 70 { return "good" }
        if value >= 45 { return "plain" }
        return "warn"
    }

    private static func recordJumps(_ record: AgentDataSnapshot.Record) -> [[String: Any]] {
        var jumps: [[String: Any]] = [
            ["kind": "learning", "id": record.id, "label": "在题库中打开"],
            ["kind": "graph", "id": record.id, "label": "在脑图中定位"]
        ]
        if let slug = record.leetCodeSlug {
            jumps.append(["kind": "leetcode", "id": slug, "label": "去刷这道题"])
        }
        return jumps
    }
}
