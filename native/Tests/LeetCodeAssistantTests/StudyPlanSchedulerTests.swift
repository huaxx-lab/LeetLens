import Foundation
import Testing
@testable import LeetCodeAssistant

@Suite("学习计划排期")
struct StudyPlanSchedulerTests {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai") ?? .current
        calendar.firstWeekday = 1
        return calendar
    }

    private func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 9, _ minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
    }

    private func item(_ id: String, minutes: Int = 30, priority: StudyTaskPriority = .normal) -> StudyPlanScheduler.Item {
        StudyPlanScheduler.Item(
            learningRecordID: id,
            title: "任务 \(id)",
            reason: "复习",
            durationMinutes: minutes,
            priority: priority
        )
    }

    private func task(
        id: String,
        recordID: String?,
        at date: Date,
        minutes: Int = 30,
        completed: Bool = false
    ) -> StudyPlanTask {
        StudyPlanTask(
            id: id,
            title: id,
            notes: "",
            scheduledAt: date,
            durationMinutes: minutes,
            priority: .normal,
            isCompleted: completed,
            learningRecordID: recordID,
            createdAt: date,
            completedAt: nil
        )
    }

    private var settings: StudyPlanScheduler.Settings {
        var settings = StudyPlanScheduler.Settings()
        settings.weekdayTaskLimit = 3
        settings.weeklyReviewTaskLimit = 6
        settings.weeklyReviewDay = 0
        settings.dailyBudgetMinutes = 90
        return settings
    }

    @Test("傍晚生成也要排在今天——这正是『今天怎么没有了』的成因")
    func fillsTodayEvenWhenGeneratedLate() {
        // 17:40 生成。旧实现把模型给的今天 09:00 判成"已过去"整条丢掉，今天于是空了。
        let now = date(2026, 8, 11, 17, 40)
        let outcome = StudyPlanScheduler.schedule(
            items: [item("a"), item("b")],
            existingTasks: [],
            settings: settings,
            reference: now,
            calendar: calendar
        )

        #expect(outcome.placements.count == 2)
        let first = outcome.placements[0].draft.scheduledAt
        #expect(calendar.isDate(first, inSameDayAs: now))
        // 17:40 + 10 分钟缓冲，向上取整到 15 分钟粒度 = 18:00。
        #expect(calendar.component(.hour, from: first) == 18)
        #expect(calendar.component(.minute, from: first) == 0)
        // 第二项接在第一项之后。
        #expect(outcome.placements[1].draft.scheduledAt == first.addingTimeInterval(30 * 60))
    }

    @Test("清早生成时从当天 dayStartHour 起排，而不是凌晨")
    func startsAtDayStartWhenGeneratedEarly() {
        let now = date(2026, 8, 11, 6, 5)
        let outcome = StudyPlanScheduler.schedule(
            items: [item("a")],
            existingTasks: [],
            settings: settings,
            reference: now,
            calendar: calendar
        )

        #expect(calendar.component(.hour, from: outcome.placements[0].draft.scheduledAt) == 9)
    }

    @Test("按每日条数配额铺开，不把所有任务堆在同一天")
    func spreadsAcrossDaysByQuota() {
        let now = date(2026, 8, 11, 9, 0)
        let items = (0..<7).map { item("r\($0)") }
        let outcome = StudyPlanScheduler.schedule(
            items: items,
            existingTasks: [],
            settings: settings,
            reference: now,
            calendar: calendar
        )

        let perDay = Dictionary(grouping: outcome.placements) {
            calendar.startOfDay(for: $0.draft.scheduledAt)
        }
        #expect(outcome.placements.count == 7)
        // 平常日配额 3，所以 7 项落到 3 天。
        #expect(perDay.count == 3)
        #expect(perDay.values.allSatisfy { $0.count <= 3 })
    }

    @Test("每天总时长不超过预算")
    func honoursDailyMinuteBudget() {
        let now = date(2026, 8, 11, 9, 0)
        // 每条 60 分钟、预算 90：一天只放得下 1 条。
        let outcome = StudyPlanScheduler.schedule(
            items: (0..<3).map { item("r\($0)", minutes: 60) },
            existingTasks: [],
            settings: settings,
            reference: now,
            calendar: calendar
        )

        let perDay = Dictionary(grouping: outcome.placements) {
            calendar.startOfDay(for: $0.draft.scheduledAt)
        }
        #expect(perDay.values.allSatisfy { day in day.reduce(0) { $0 + $1.draft.durationMinutes } <= 90 })
        #expect(perDay.count == 3)
    }

    @Test("避开已有任务占用的时段，不和手动安排撞车")
    func avoidsExistingTaskWindows() {
        let now = date(2026, 8, 11, 9, 0)
        let busy = task(id: "manual", recordID: nil, at: date(2026, 8, 11, 9, 0), minutes: 45)
        let outcome = StudyPlanScheduler.schedule(
            items: [item("a")],
            existingTasks: [busy],
            settings: settings,
            reference: now,
            calendar: calendar
        )

        let start = outcome.placements[0].draft.scheduledAt
        #expect(start >= date(2026, 8, 11, 9, 45))
    }

    @Test("未来已排过的学习项不重复安排")
    func skipsRecordsAlreadyScheduled() {
        let now = date(2026, 8, 11, 9, 0)
        let existing = task(id: "t1", recordID: "a", at: date(2026, 8, 13, 10, 0))
        let outcome = StudyPlanScheduler.schedule(
            items: [item("a"), item("b")],
            existingTasks: [existing],
            settings: settings,
            reference: now,
            calendar: calendar
        )

        #expect(outcome.alreadyScheduled.map(\.learningRecordID) == ["a"])
        #expect(outcome.placements.map(\.draft.learningRecordID) == ["b"])
    }

    @Test("逾期任务是改期而不是新建，历史记录不会被删")
    func reschedulesOverdueInsteadOfRecreating() {
        let now = date(2026, 8, 11, 9, 0)
        let overdue = task(id: "t-old", recordID: "a", at: date(2026, 8, 5, 10, 0))
        let outcome = StudyPlanScheduler.schedule(
            items: [item("a")],
            existingTasks: [overdue],
            settings: settings,
            reference: now,
            calendar: calendar
        )

        #expect(outcome.placements.count == 1)
        #expect(outcome.placements[0].reschedulingTaskID == "t-old")
        #expect(outcome.placements[0].draft.scheduledAt >= now)
    }

    @Test("已完成的任务既不占容量也不参与改期")
    func ignoresCompletedTasks() {
        let now = date(2026, 8, 11, 9, 0)
        let done = task(id: "t-done", recordID: "a", at: date(2026, 8, 11, 9, 0), minutes: 90, completed: true)
        let outcome = StudyPlanScheduler.schedule(
            items: [item("a")],
            existingTasks: [done],
            settings: settings,
            reference: now,
            calendar: calendar
        )

        #expect(outcome.placements.count == 1)
        #expect(outcome.placements[0].reschedulingTaskID == nil)
        #expect(calendar.isDate(outcome.placements[0].draft.scheduledAt, inSameDayAs: now))
    }

    @Test("已完成的逾期任务不会被当成改期目标——完成记录绝不被动")
    func neverReschedulesCompletedWork() {
        let now = date(2026, 8, 11, 9, 0)
        let doneOverdue = task(id: "t-done", recordID: "a", at: date(2026, 8, 3, 10, 0), completed: true)
        let outcome = StudyPlanScheduler.schedule(
            items: [item("a")],
            existingTasks: [doneOverdue],
            settings: settings,
            reference: now,
            calendar: calendar
        )

        #expect(outcome.placements.count == 1)
        // 新建一条，而不是把那条已完成记录挪走／改写。
        #expect(outcome.placements[0].reschedulingTaskID == nil)
    }

    @Test("改期只挑未完成的那条，已完成的同题记录不受影响")
    func reschedulesOnlyThePendingOne() {
        let now = date(2026, 8, 11, 9, 0)
        let done = task(id: "t-done", recordID: "a", at: date(2026, 8, 3, 10, 0), completed: true)
        let pending = task(id: "t-pending", recordID: "a", at: date(2026, 8, 6, 10, 0))
        let outcome = StudyPlanScheduler.schedule(
            items: [item("a")],
            existingTasks: [done, pending],
            settings: settings,
            reference: now,
            calendar: calendar
        )

        #expect(outcome.placements[0].reschedulingTaskID == "t-pending")
    }

    @Test("只有已排或顺延也是有效排期结果")
    func nonPlacementOutcomesAreNotEmpty() {
        let now = date(2026, 8, 11, 9, 0)
        let existing = task(id: "t1", recordID: "a", at: date(2026, 8, 13, 10, 0))
        let alreadyScheduled = StudyPlanScheduler.schedule(
            items: [item("a")],
            existingTasks: [existing],
            settings: settings,
            reference: now,
            calendar: calendar
        )
        #expect(!alreadyScheduled.isEmpty)
        #expect(alreadyScheduled.placements.isEmpty)
        #expect(alreadyScheduled.alreadyScheduled.count == 1)

        var noCapacity = settings
        noCapacity.horizonDays = 1
        noCapacity.weekdayTaskLimit = 0
        noCapacity.weeklyReviewTaskLimit = 0
        let deferred = StudyPlanScheduler.schedule(
            items: [item("b")],
            existingTasks: [],
            settings: noCapacity,
            reference: now,
            calendar: calendar
        )
        #expect(!deferred.isEmpty)
        #expect(deferred.placements.isEmpty)
        #expect(deferred.deferred.count == 1)
    }

    @Test("超出视野容量的顺延，而不是硬塞或静默丢弃")
    func defersWhatDoesNotFit() {
        let now = date(2026, 8, 11, 9, 0)
        var tight = settings
        tight.horizonDays = 1
        let outcome = StudyPlanScheduler.schedule(
            items: (0..<5).map { item("r\($0)") },
            existingTasks: [],
            settings: tight,
            reference: now,
            calendar: calendar
        )

        #expect(outcome.placements.count == 3)
        #expect(outcome.deferred.map(\.learningRecordID) == ["r3", "r4"])
    }

    @Test("每周复习日换用更大的配额")
    func weeklyReviewDayGetsLargerQuota() {
        // 2026-08-16 是周日，weeklyReviewDay = 0。
        let sunday = date(2026, 8, 16, 9, 0)
        #expect(settings.taskLimit(for: sunday, calendar: calendar) == 6)
        #expect(settings.taskLimit(for: date(2026, 8, 11, 9, 0), calendar: calendar) == 3)
    }

    @Test("配额取自「学习与复习」设置，与今日复习同源")
    func settingsComeFromLearningSnapshot() {
        let snapshot = LearningSettingsSnapshot(
            dailyNewTarget: 3,
            weekdayReviewTarget: 4,
            weeklyReviewDay: 0,
            weeklyReviewTarget: 12,
            preferredLanguage: "java"
        )
        let derived = StudyPlanScheduler.Settings(snapshot: snapshot)

        #expect(derived.weekdayTaskLimit == 7)
        #expect(derived.weeklyReviewTaskLimit == 15)
        #expect(derived.weeklyReviewDay == 0)
    }

    @Test("起始时刻向上取整到粒度，不排出 17:43 这种时间")
    func roundsStartToGranularity() {
        let rounded = StudyPlanScheduler.roundUp(date(2026, 8, 11, 17, 43), minutes: 15, calendar: calendar)
        #expect(calendar.component(.hour, from: rounded) == 17)
        #expect(calendar.component(.minute, from: rounded) == 45)
    }

    @Test("当天已经太晚就顺延到明天早上，而不是排到半夜")
    func rollsOverToTomorrowWhenDayIsOver() {
        let now = date(2026, 8, 11, 23, 30)
        let outcome = StudyPlanScheduler.schedule(
            items: [item("a")],
            existingTasks: [],
            settings: settings,
            reference: now,
            calendar: calendar
        )

        let start = outcome.placements[0].draft.scheduledAt
        #expect(calendar.isDate(start, inSameDayAs: date(2026, 8, 12)))
        #expect(calendar.component(.hour, from: start) == 9)
    }
}
