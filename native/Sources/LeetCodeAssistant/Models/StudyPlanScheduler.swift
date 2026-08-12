import Foundation

/// AI 学习计划的**排期**规则。
///
/// **为什么时间由客户端算，而不是让模型直接给 `scheduledAt`**：
/// 模型习惯从「今天 09:00」开始往下铺，可用户往往是下午或晚上才点"AI 安排"。
/// 旧实现又把 `now - 1h` 之前的建议整条丢掉——于是今天一条不剩，计划总是从明天开始
/// （用户看到的就是"今天怎么没有了"）。同一个原因也让"每天不要堆太多"完全落空：
/// 提示词里写了，但没有任何东西执行它，模型经常把 9 条全塞进同一天。
///
/// 现在分工明确：模型只回答"学什么、多久、为什么、多急"，
/// "什么时候"是这里的确定性规则——可单测，且今天只要还有剩余时间就一定排得上。
enum StudyPlanScheduler {
    struct Settings: Sendable, Equatable {
        /// 计划覆盖的天数，含今天。
        var horizonDays = 7
        var dayStartHour = 9
        var dayEndHour = 22
        /// 每天的总时长上限。
        var dailyBudgetMinutes = 90
        /// 平常日的条数上限，取自「学习与复习」里的复习 + 新知识配额。
        var weekdayTaskLimit = 7
        /// 每周复习日（0 = 周日），当天换用更大的配额。
        var weeklyReviewDay = 0
        var weeklyReviewTaskLimit = 15
        /// 起始时刻向上取整的粒度，免得排出 17:43 这种时间。
        var slotGranularityMinutes = 15
        /// 现在点生成，至少留出这么多分钟再开始第一项。
        var leadInMinutes = 10

        /// 让计划页和「今日复习」共用同一份用户配额，两处不再各说各话。
        init(snapshot: LearningSettingsSnapshot) {
            weekdayTaskLimit = max(1, snapshot.weekdayReviewTarget + snapshot.dailyNewTarget)
            weeklyReviewDay = snapshot.weeklyReviewDay
            weeklyReviewTaskLimit = max(1, snapshot.weeklyReviewTarget + snapshot.dailyNewTarget)
        }

        init() {}

        func taskLimit(for date: Date, calendar: Calendar) -> Int {
            let weekday = calendar.component(.weekday, from: date) - 1
            return weekday == weeklyReviewDay ? weeklyReviewTaskLimit : weekdayTaskLimit
        }
    }

    /// 模型给出的一条待排项。它不带时间。
    struct Item: Sendable, Equatable, Identifiable {
        var id: String { learningRecordID }
        var learningRecordID: String
        var title: String
        var reason: String
        var durationMinutes: Int
        var priority: StudyTaskPriority
    }

    struct Placement: Sendable, Equatable, Hashable, Identifiable {
        var id: UUID { draft.id }
        var draft: StudyPlanDraft
        /// 非空表示这次是把一条**逾期的旧任务**挪到新时间，
        /// 应用时走 update 而不是 create——历史记录不会被删掉，也不会多出一条重复任务。
        var reschedulingTaskID: String?
    }

    struct Outcome: Sendable, Equatable {
        var placements: [Placement] = []
        /// 这一轮容量放不下、留到下次的。
        var deferred: [Item] = []
        /// 该学习项在未来已经有安排了，这次跳过（避免重复排同一个知识点）。
        var alreadyScheduled: [Item] = []

        var isEmpty: Bool {
            placements.isEmpty && deferred.isEmpty && alreadyScheduled.isEmpty
        }
    }

    /// 一天之内已被占用的时段。用来避免和手动任务、上一轮 AI 任务撞车。
    private struct DayLoad {
        var minutes = 0
        var count = 0
        var busy: [(start: Date, end: Date)] = []
    }

    static func schedule(
        items: [Item],
        existingTasks: [StudyPlanTask],
        settings: Settings = Settings(),
        reference: Date = .now,
        calendar: Calendar = .current
    ) -> Outcome {
        var outcome = Outcome()
        let today = calendar.startOfDay(for: reference)
        let pending = existingTasks.filter { !$0.isCompleted }

        // 已经排在未来的学习项不再重复安排。
        let futureRecordIDs = Set(pending.compactMap { $0.scheduledAt >= reference ? $0.learningRecordID : nil })
        // 逾期未完成的：同一学习项这次改期而不是新建，最早的那条优先被挪。
        var overdueTaskByRecord: [String: StudyPlanTask] = [:]
        for task in pending where task.scheduledAt < reference {
            guard let recordID = task.learningRecordID else { continue }
            if let existing = overdueTaskByRecord[recordID], existing.scheduledAt <= task.scheduledAt { continue }
            overdueTaskByRecord[recordID] = task
        }

        // 未完成任务已经占掉的时段与配额。逾期任务不占用未来的容量——它们正要被挪走。
        var load: [Date: DayLoad] = [:]
        for task in pending where task.scheduledAt >= reference {
            let day = calendar.startOfDay(for: task.scheduledAt)
            var entry = load[day] ?? DayLoad()
            entry.minutes += task.durationMinutes
            entry.count += 1
            entry.busy.append((task.scheduledAt, task.scheduledAt.addingTimeInterval(Double(task.durationMinutes) * 60)))
            load[day] = entry
        }

        let days = (0..<max(1, settings.horizonDays)).compactMap {
            calendar.date(byAdding: .day, value: $0, to: today)
        }

        for item in items {
            if futureRecordIDs.contains(item.learningRecordID) {
                outcome.alreadyScheduled.append(item)
                continue
            }
            let duration = min(180, max(5, item.durationMinutes))
            guard let slot = firstFreeSlot(
                duration: duration,
                days: days,
                load: &load,
                settings: settings,
                reference: reference,
                calendar: calendar
            ) else {
                outcome.deferred.append(item)
                continue
            }
            outcome.placements.append(
                Placement(
                    draft: StudyPlanDraft(
                        title: item.title,
                        notes: item.reason,
                        scheduledAt: slot,
                        durationMinutes: duration,
                        priority: item.priority,
                        learningRecordID: item.learningRecordID
                    ),
                    reschedulingTaskID: overdueTaskByRecord[item.learningRecordID]?.id
                )
            )
        }
        return outcome
    }

    /// 从今天起逐日找第一个放得下的空档；找到就把这一天的占用登记上。
    private static func firstFreeSlot(
        duration: Int,
        days: [Date],
        load: inout [Date: DayLoad],
        settings: Settings,
        reference: Date,
        calendar: Calendar
    ) -> Date? {
        for day in days {
            var entry = load[day] ?? DayLoad()
            guard entry.count < settings.taskLimit(for: day, calendar: calendar),
                  entry.minutes + duration <= settings.dailyBudgetMinutes
            else { continue }

            guard
                let dayEnd = calendar.date(bySettingHour: settings.dayEndHour, minute: 0, second: 0, of: day),
                let earliest = earliestStart(on: day, settings: settings, reference: reference, calendar: calendar)
            else { continue }

            var candidate = earliest
            let ordered = entry.busy.sorted { $0.start < $1.start }
            for window in ordered {
                let end = candidate.addingTimeInterval(Double(duration) * 60)
                // 与已占用时段重叠就挪到它之后再试。
                if end > window.start && candidate < window.end {
                    candidate = window.end
                }
            }
            guard candidate.addingTimeInterval(Double(duration) * 60) <= dayEnd else { continue }

            entry.minutes += duration
            entry.count += 1
            entry.busy.append((candidate, candidate.addingTimeInterval(Double(duration) * 60)))
            load[day] = entry
            return candidate
        }
        return nil
    }

    /// 今天从"现在 + 缓冲"起算并向上取整；其余天数从 dayStartHour 起算。
    /// 这一条就是"今天必须排得上"的关键：不再因为模型写了 09:00 而被整天丢弃。
    static func earliestStart(
        on day: Date,
        settings: Settings,
        reference: Date,
        calendar: Calendar
    ) -> Date? {
        guard let dayStart = calendar.date(bySettingHour: settings.dayStartHour, minute: 0, second: 0, of: day) else {
            return nil
        }
        guard calendar.isDate(day, inSameDayAs: reference) else { return dayStart }
        let lead = reference.addingTimeInterval(Double(settings.leadInMinutes) * 60)
        return max(dayStart, roundUp(lead, minutes: settings.slotGranularityMinutes, calendar: calendar))
    }

    static func roundUp(_ date: Date, minutes: Int, calendar: Calendar) -> Date {
        let step = max(1, minutes)
        let components = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        guard let minute = components.minute, let floor = calendar.date(from: components) else { return date }
        let remainder = minute % step
        if remainder == 0 && floor == date { return date }
        return calendar.date(byAdding: .minute, value: step - remainder, to: floor) ?? date
    }
}
