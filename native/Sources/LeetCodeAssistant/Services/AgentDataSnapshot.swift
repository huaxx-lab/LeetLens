import Foundation

/// 工具执行时看到的那份数据。
///
/// 在主线程从 `LegacyDataStore` 拍一次，之后整个 ReAct 循环共用——
/// 一是 `LegacyDataStore` 是 `@MainActor` 的，工具循环跑在后台任务里够不着；
/// 二是一轮对话里模型看到的世界应当前后一致，中途被后台同步改掉会出现
/// "第一次查有 3 条、第二次查变 5 条"这种自相矛盾的回答。
struct AgentDataSnapshot: Sendable {
    struct Record: Sendable {
        let id: String
        let title: String
        let question: String
        let knowledgePath: String
        let diagnosis: String
        let labels: [String]
        let effectiveMastery: Double
        let evidenceCount: Int
        let isDue: Bool
        let dueCaption: String
        let leetCodeSlug: String?
        let evidenceSummaries: [String]

        /// 检索用的扁平文本。学习项数量在百级，直接子串打分比上向量便宜得多，
        /// 也不需要等 RAG 索引就绪。
        let haystack: String
    }

    struct Attempt: Sendable {
        let verdict: String
        let language: String
        let accepted: Bool
        let issue: String
        let change: String
        let outcome: String
    }

    struct Problem: Sendable {
        let slug: String
        let title: String
        let summaryLine: String
        let analysisSummary: String
        let weaknesses: [String]
        let improvements: [String]
        let attempts: [Attempt]
        let jumps: [Jump]
    }

    /// 卡片上的一条跳转。`kind` 决定落到哪个页面，`id` 是那个页面要选中的东西。
    struct Jump: Sendable {
        let kind: String
        let id: String
        let label: String

        init(kind: String, id: String = "", label: String) {
            self.kind = kind
            self.id = id
            self.label = label
        }

        var dictionary: [String: Any] { ["kind": kind, "id": id, "label": label] }
    }

    struct Metric: Sendable {
        let label: String
        let value: Int

        var dictionary: [String: Any] { ["label": label, "value": value] }
    }

    struct PlanProgress: Sendable {
        let name: String
        let solved: Int
        let total: Int
        let percent: Int
    }

    struct Task: Sendable {
        let title: String
        let notes: String
        let timeCaption: String
        let priorityLabel: String
        let priorityTone: String
        let isCompleted: Bool
    }

    struct SlugTitle: Sendable {
        let slug: String
        let title: String
    }

    struct MemoryMatch: Sendable {
        let conversationID: String
        let title: String
        let dateCaption: String
        let excerpt: String
    }

    var records: [Record] = []
    var todayReviews: [Record] = []
    var todayTasks: [Task] = []
    var overdueCount = 0
    var weakCount = 0
    var planSummaryLine = ""
    var progressSummaryLine = ""
    /// 题单里的 (slug, 标题)，只用来把模型给的中文题名解析成 slug。
    var questionIndex: [SlugTitle] = []
    var progressMetrics: [Metric] = []
    var planProgress: [PlanProgress] = []
    private var problemsBySlug: [String: Problem] = [:]

    // MARK: - 检索

    /// 子串打分：标题命中权重最高，其次知识路径与标签，最后正文。
    /// 查询里的空白切成词，逐词累加——"前缀和 初始化"要能同时压中两处。
    func rankedRecords(matching query: String) -> [Record] {
        let terms = query
            .lowercased()
            .split(whereSeparator: { $0.isWhitespace || $0 == "," || $0 == "，" })
            .map(String.init)
            .filter { !$0.isEmpty }
        guard !terms.isEmpty else {
            return records.sorted { $0.effectiveMastery < $1.effectiveMastery }
        }
        let scored = records.compactMap { record -> (Record, Int)? in
            var score = 0
            for term in terms {
                if record.title.lowercased().contains(term) { score += 8 }
                if record.knowledgePath.lowercased().contains(term) { score += 5 }
                if record.labels.contains(where: { $0.lowercased().contains(term) }) { score += 4 }
                if record.haystack.contains(term) { score += 1 }
            }
            return score > 0 ? (record, score) : nil
        }
        return scored
            .sorted { lhs, rhs in
                // 同分时把掌握度低的排前面：问"我这块怎么样"时，
                // 先看到还没学明白的那条才有用。
                lhs.1 == rhs.1 ? lhs.0.effectiveMastery < rhs.0.effectiveMastery : lhs.1 > rhs.1
            }
            .map(\.0)
    }

    func weakest(limit: Int) -> [Record] {
        Array(records.sorted { $0.effectiveMastery < $1.effectiveMastery }.prefix(limit))
    }

    /// 把「和为 K 的子数组」「subarray-sum-equals-k」这类输入解析成 titleSlug。
    /// 模型给的多半是中文题名，力扣接口只认 slug。
    func resolveSlug(_ query: String) -> String? {
        let needle = query.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return nil }
        if problemsBySlug[needle] != nil { return needle }
        if let exact = questionIndex.first(where: { $0.slug == needle || $0.title.lowercased() == needle }) {
            return exact.slug
        }
        if let partial = questionIndex.first(where: { $0.title.lowercased().contains(needle) }) {
            return partial.slug
        }
        return problem(matching: query)?.slug
    }

    func problem(matching query: String) -> Problem? {
        let needle = query.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return nil }
        if let exact = problemsBySlug[needle] { return exact }
        return problemsBySlug.values.first { $0.title.lowercased().contains(needle) }
            ?? problemsBySlug.values.first { $0.slug.contains(needle) }
    }

    // MARK: - 构造

    @MainActor
    static func capture(from dataStore: LegacyDataStore) -> AgentDataSnapshot {
        var snapshot = AgentDataSnapshot()
        let now = Date.now
        let records = dataStore.activeLearningRecords
        snapshot.records = records.map { Self.record(from: $0, now: now) }
        snapshot.overdueCount = dataStore.dueCount
        snapshot.weakCount = dataStore.weakCount

        let plan = LearningReviewSchedule.plan(records: records, settings: dataStore.learningSettings)
        snapshot.todayReviews = plan.queue.map { Self.record(from: $0, now: now) }
        snapshot.planSummaryLine = Self.planSummary(plan: plan, tasks: dataStore.studyPlanTasks, now: now)

        let calendar = Calendar.current
        snapshot.todayTasks = dataStore.studyPlanTasks
            .filter { calendar.isDate($0.scheduledAt, inSameDayAs: now) }
            .sorted { $0.scheduledAt < $1.scheduledAt }
            .map(Self.task(from:))

        snapshot.problemsBySlug = Self.problems(from: dataStore)
        snapshot.questionIndex = dataStore.leetCodeQuestions.map {
            SlugTitle(slug: $0.titleSlug, title: $0.title)
        }
        snapshot.progressMetrics = Self.metrics(from: dataStore)
        snapshot.progressSummaryLine = Self.progressSummary(from: dataStore)
        snapshot.planProgress = dataStore.leetCodePlans.prefix(6).map { plan in
            PlanProgress(
                name: plan.name,
                solved: plan.solvedCount,
                total: plan.questionCount,
                percent: plan.questionCount > 0
                    ? Int((Double(plan.solvedCount) / Double(plan.questionCount) * 100).rounded())
                    : 0
            )
        }
        return snapshot
    }

    private static func record(from record: LearningRecord, now: Date) -> Record {
        let mastery = record.effectiveMastery(at: now)
        let days = Int((now.timeIntervalSince(record.dueAt) / 86_400).rounded(.down))
        let dueCaption: String
        if record.dueAt > now {
            dueCaption = "未到期"
        } else if days <= 0 {
            dueCaption = "今天到期"
        } else {
            dueCaption = "逾期 \(days) 天"
        }
        let haystack = ([record.title, record.question, record.diagnosis]
            + record.labels
            + record.knowledgePath)
            .joined(separator: " ")
            .lowercased()
        return Record(
            id: record.id,
            title: record.title,
            question: record.question,
            knowledgePath: record.knowledgePath.joined(separator: " › "),
            diagnosis: record.diagnosis,
            labels: record.labels,
            effectiveMastery: mastery,
            evidenceCount: record.evidenceCount,
            isDue: record.isDue,
            dueCaption: dueCaption,
            leetCodeSlug: record.leetCodeSlug,
            evidenceSummaries: record.evidence.prefix(3).map(\.summary),
            haystack: haystack
        )
    }

    private static func task(from task: StudyPlanTask) -> Task {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "HH:mm"
        let tone = task.priority == .urgent ? "warn" : "plain"
        return Task(
            title: task.title,
            notes: task.notes,
            timeCaption: "\(formatter.string(from: task.scheduledAt)) · \(task.durationMinutes) 分钟",
            priorityLabel: task.priority.title,
            priorityTone: tone,
            isCompleted: task.isCompleted
        )
    }

    private static func planSummary(plan: LearningReviewSchedule.Plan, tasks: [StudyPlanTask], now: Date) -> String {
        let calendar = Calendar.current
        let todayTasks = tasks.filter { calendar.isDate($0.scheduledAt, inSameDayAs: now) }
        var parts: [String] = []
        if plan.reviews.isEmpty, plan.fresh.isEmpty {
            parts.append("今天没有排到复习")
        } else {
            parts.append("今天要复习 \(plan.reviews.count) 项、新学 \(plan.fresh.count) 项")
        }
        if plan.deferred > 0 { parts.append("配额外还欠 \(plan.deferred) 条") }
        if !todayTasks.isEmpty { parts.append("学习计划里有 \(todayTasks.count) 个任务") }
        return parts.joined(separator: "；")
    }

    @MainActor
    private static func problems(from dataStore: LegacyDataStore) -> [String: Problem] {
        var result: [String: Problem] = [:]
        let submissionsBySlug = Dictionary(grouping: dataStore.leetCodeSubmissions, by: \.titleSlug)
        let slugs = Set(submissionsBySlug.keys).union(dataStore.leetCodeAnalyses.keys)

        for slug in slugs {
            let submissions = (submissionsBySlug[slug] ?? []).sorted { $0.submittedAt < $1.submittedAt }
            let analysis = dataStore.leetCodeAnalyses[slug]
            let insights = analysis?.attemptInsights ?? []
            let insightByID = Dictionary(insights.map { ($0.submissionID, $0) }, uniquingKeysWith: { first, _ in first })
            let title = submissions.first?.title
                ?? dataStore.leetCodeQuestions.first { $0.titleSlug == slug }?.title
                ?? slug

            var attempts = submissions.map { submission in
                let insight = insightByID[submission.id]
                return Attempt(
                    verdict: submission.status.isEmpty ? (submission.accepted ? "Accepted" : "未通过") : submission.status,
                    language: submission.language,
                    accepted: submission.accepted,
                    issue: insight?.issue ?? "",
                    change: insight?.change ?? "",
                    outcome: insight?.outcome ?? Self.outcomeLine(submission)
                )
            }
            // 只有分析、没有原始提交时（提交列表被裁剪过），也要能把轨迹讲出来。
            if attempts.isEmpty {
                attempts = insights.map {
                    Attempt(
                        verdict: "", language: "", accepted: false,
                        issue: $0.issue, change: $0.change, outcome: $0.outcome
                    )
                }
            }

            let acceptedCount = submissions.filter(\.accepted).count
            var summaryParts = ["「\(title)」提交 \(submissions.count) 次"]
            if !submissions.isEmpty { summaryParts.append(acceptedCount > 0 ? "已通过" : "还没通过") }
            var jumps = [Jump(kind: "leetcode", id: slug, label: "打开这道题")]
            if let recordID = dataStore.learningRecords.first(where: { $0.leetCodeSlug == slug })?.id {
                jumps.append(Jump(kind: "learning", id: recordID, label: "看学习项"))
            }

            result[slug] = Problem(
                slug: slug,
                title: title,
                summaryLine: summaryParts.joined(separator: "，"),
                analysisSummary: analysis?.summary ?? "",
                weaknesses: analysis?.weaknesses ?? [],
                improvements: analysis?.improvements ?? [],
                attempts: attempts,
                jumps: jumps
            )
        }
        return result
    }

    private static func outcomeLine(_ submission: LeetCodeSubmission) -> String {
        var parts = [submission.status.isEmpty ? (submission.accepted ? "Accepted" : "未通过") : submission.status]
        if !submission.runtime.isEmpty { parts.append(submission.runtime) }
        if !submission.memory.isEmpty { parts.append(submission.memory) }
        return parts.joined(separator: "，")
    }

    @MainActor
    private static func metrics(from dataStore: LegacyDataStore) -> [Metric] {
        let questions = dataStore.leetCodeQuestions
        return [
            Metric(label: "题目", value: questions.count),
            Metric(label: "已通过", value: questions.filter { $0.status == "SOLVED" }.count),
            Metric(label: "尝试过", value: questions.filter { $0.status == "TRIED" }.count),
            Metric(label: "提交", value: dataStore.leetCodeSubmissions.count)
        ]
    }

    @MainActor
    private static func progressSummary(from dataStore: LegacyDataStore) -> String {
        let questions = dataStore.leetCodeQuestions
        let solved = questions.filter { $0.status == "SOLVED" }.count
        guard !questions.isEmpty else { return "还没有同步到力扣数据" }
        let recent = dataStore.leetCodeSubmissions
            .sorted { $0.submittedAt > $1.submittedAt }
            .first
        var line = "题单共 \(questions.count) 题，已通过 \(solved) 题"
        if let recent {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "zh_CN")
            formatter.dateFormat = "M 月 d 日"
            line += "；最近一次提交是 \(formatter.string(from: recent.submittedAt)) 的「\(recent.title)」"
        }
        return line
    }
}
