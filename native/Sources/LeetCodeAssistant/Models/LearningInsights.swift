import Foundation

/// 学习洞察的计算。放在模型层是为了能单测——原来这些逻辑散在视图里，
/// 其中「优先巩固」实际是 `activeLearningRecords.prefix(6)`：**没有任何排序**，
/// 拿到的只是数据源里恰好排在前面的六条，和"优先"没关系。
enum LearningInsights {
    struct TopicStat: Identifiable, Equatable, Sendable {
        var id: String { name }
        var name: String
        /// 该主题的平均掌握度（0…100）。
        var averageMastery: Double
        var count: Int
        var overdueCount: Int
        /// 掌握度低于 `weakThreshold` 的条数。
        var weakCount: Int
    }

    struct DueBucket: Identifiable, Equatable, Sendable {
        var id: Date { day }
        var day: Date
        var count: Int
        /// 今天这一格里包含所有逾期项——它们都得今天面对。
        var includesOverdue: Bool
    }

    static let weakThreshold = 60.0

    /// 优先巩固：直接复用「今日复习」的优先级（逾期为主因、掌握度为次因），
    /// 两个页面对"该先练什么"的判断必须是同一个，否则用户会看到两套互相矛盾的排序。
    static func focus(
        records: [LearningRecord],
        limit: Int = 6,
        reference: Date = .now,
        calendar: Calendar = .current
    ) -> [LearningRecord] {
        records
            .sorted { left, right in
                let leftScore = LearningReviewSchedule.priority(for: left, reference: reference, calendar: calendar)
                let rightScore = LearningReviewSchedule.priority(for: right, reference: reference, calendar: calendar)
                if leftScore != rightScore { return leftScore > rightScore }
                return left.id < right.id
            }
            .prefix(limit)
            .map { $0 }
    }

    /// 知识分布：按主题聚合，最薄弱的排前面。逾期数和薄弱数一起给出，
    /// 只看平均分会把"5 项全 60"和"1 项 20 + 4 项 70"混为一谈。
    static func topics(
        records: [LearningRecord],
        reference: Date = .now,
        calendar: Calendar = .current
    ) -> [TopicStat] {
        let today = calendar.startOfDay(for: reference)
        return Dictionary(grouping: records, by: \.primaryKnowledge)
            .map { name, group in
                // 用遗忘曲线折算过的掌握度：一个月没碰的主题不该还挂着当初的分数。
                TopicStat(
                    name: name,
                    averageMastery: group.map { $0.effectiveMastery(at: reference) }.reduce(0, +)
                        / Double(max(1, group.count)),
                    count: group.count,
                    overdueCount: group.count { calendar.startOfDay(for: $0.dueAt) < today },
                    weakCount: group.count { $0.effectiveMastery(at: reference) < weakThreshold }
                )
            }
            .sorted { left, right in
                if left.averageMastery != right.averageMastery { return left.averageMastery < right.averageMastery }
                if left.count != right.count { return left.count > right.count }
                return left.name < right.name
            }
    }

    /// 未来若干天的到期分布。第一格是今天，且**把所有逾期项算进今天**——
    /// 逾期不是过去的事，是今天的欠账。
    static func dueForecast(
        records: [LearningRecord],
        days: Int = 7,
        reference: Date = .now,
        calendar: Calendar = .current
    ) -> [DueBucket] {
        let today = calendar.startOfDay(for: reference)
        let span = max(1, days)
        var counts: [Date: Int] = [:]
        var overdueDays: Set<Date> = []

        for record in records {
            let due = calendar.startOfDay(for: record.dueAt)
            let bucket: Date
            if due <= today {
                bucket = today
                if due < today { overdueDays.insert(today) }
            } else {
                guard
                    let offset = calendar.dateComponents([.day], from: today, to: due).day,
                    offset < span
                else { continue }
                bucket = due
            }
            counts[bucket, default: 0] += 1
        }

        return (0..<span).compactMap { offset in
            guard let day = calendar.date(byAdding: .day, value: offset, to: today) else { return nil }
            return DueBucket(day: day, count: counts[day] ?? 0, includesOverdue: overdueDays.contains(day))
        }
    }
}
