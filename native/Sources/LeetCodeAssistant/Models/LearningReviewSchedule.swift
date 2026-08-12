import Foundation

/// 「今日复习」的排期。滚动式：每天按配额现算，逾期的排前面，熟到不需要练的自然沉底，
/// 新沉淀的学习项到点自己滚进来——不是把 65 条待复习一次性摊在页面上。
///
/// 纯函数放在这里是为了能单测：配额、优先级、周复习日这些规则不该埋在视图里。
enum LearningReviewSchedule {
    struct Plan: Equatable, Sendable {
        /// 今天要复习的（含逾期），已按优先级排序并截到配额。
        var reviews: [LearningRecord] = []
        /// 今天要学的新知识（从未复习过的），独立配额。
        var fresh: [LearningRecord] = []
        /// 配额之外还欠着的复习条数。
        var deferred = 0
        var overdueCount = 0
        var dueCount = 0
        var reviewQuota = 0
        var newQuota = 0
        var isWeeklyReviewDay = false

        static let empty = Plan()

        var queue: [LearningRecord] { reviews + fresh }
        var isEmpty: Bool { queue.isEmpty }
    }

    /// 逾期天数封顶 30：一道逾期两年的题不该永远压着所有人，
    /// 掌握度低的同样逾期项要能排到它前面。
    static let overdueCap = 30.0

    static func priority(
        for record: LearningRecord,
        reference: Date = .now,
        calendar: Calendar = .current
    ) -> Double {
        let today = calendar.startOfDay(for: reference)
        let due = calendar.startOfDay(for: record.dueAt)
        let overdueDays = Double(calendar.dateComponents([.day], from: due, to: today).day ?? 0)
        let overdue = min(max(overdueDays, 0), overdueCap)
        // 逾期是主因（每天 2 分），掌握度是次因（0…50 分），
        // 于是"很熟但刚到期"排在"很生且逾期一周"后面。
        //
        // 掌握度这一项用遗忘曲线折算过的值：同样是 80 分，上个月练的那道
        // 现在其实只剩一半记得住，它应该排在昨天刚练过的 80 分前面。
        let mastery = record.effectiveMastery(at: reference)
        var score = overdue * 2 + (100 - min(max(mastery, 0), 100)) * 0.5
        // 已经掉到目标保持率以下的，再加一份"快忘干净了"的权重（0…20 分）。
        if let retention = record.retention(at: reference) {
            score += max(0, ForgettingCurve.requestRetention - retention) * 20
        }
        return score
    }

    static func plan(
        records: [LearningRecord],
        settings: LearningSettingsSnapshot,
        reference: Date = .now,
        calendar: Calendar = .current
    ) -> Plan {
        var plan = Plan()
        let today = calendar.startOfDay(for: reference)
        let endOfToday = calendar.date(byAdding: .day, value: 1, to: today) ?? today

        plan.isWeeklyReviewDay = (calendar.component(.weekday, from: reference) - 1) == settings.weeklyReviewDay
        plan.reviewQuota = max(0, plan.isWeeklyReviewDay ? settings.weeklyReviewTarget : settings.weekdayReviewTarget)
        plan.newQuota = max(0, settings.dailyNewTarget)

        // 从没复习过的算"新知识"，走单独配额，不占复习名额。
        let fresh = records.filter { $0.reviewCount <= 0 }
        let due = records.filter { $0.reviewCount > 0 && $0.dueAt < endOfToday }

        plan.dueCount = due.count
        plan.overdueCount = due.filter { calendar.startOfDay(for: $0.dueAt) < today }.count

        let ranked = due.sorted { left, right in
            let leftScore = priority(for: left, reference: reference, calendar: calendar)
            let rightScore = priority(for: right, reference: reference, calendar: calendar)
            if leftScore != rightScore { return leftScore > rightScore }
            if left.dueAt != right.dueAt { return left.dueAt < right.dueAt }
            return left.id < right.id
        }
        plan.reviews = Array(ranked.prefix(plan.reviewQuota))
        plan.deferred = max(0, plan.dueCount - plan.reviews.count)

        // 新知识挑最近沉淀的：刚从对话/做题里出来的记忆最热，趁热学。
        plan.fresh = Array(
            fresh.sorted { left, right in
                if left.updatedAt != right.updatedAt { return left.updatedAt > right.updatedAt }
                return left.id < right.id
            }
            .prefix(plan.newQuota)
        )

        return plan
    }

    /// 队列行上的说明：为什么这条今天要练。
    static func reason(
        for record: LearningRecord,
        reference: Date = .now,
        calendar: Calendar = .current
    ) -> String {
        guard record.reviewCount > 0 else { return "新知识" }
        let today = calendar.startOfDay(for: reference)
        let due = calendar.startOfDay(for: record.dueAt)
        let days = calendar.dateComponents([.day], from: due, to: today).day ?? 0
        // 带上"还记得多少"：光说逾期几天，用户不知道这几天里忘掉了多少。
        let retention = record.retention(at: reference).map { "记忆 \(Int(($0 * 100).rounded()))%" }
        let base = days > 0 ? "逾期 \(days) 天" : "今天到期"
        guard let retention else { return base }
        return "\(base) · \(retention)"
    }
}
