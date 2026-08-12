import Foundation
import Testing
@testable import LeetCodeAssistant

@Suite("今日复习排期")
struct LearningReviewScheduleTests {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai") ?? .current
        calendar.firstWeekday = 1
        return calendar
    }

    private func date(_ year: Int, _ month: Int, _ day: Int) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: 9))!
    }

    private func record(
        id: String,
        mastery: Double = 50,
        dueDaysFromToday: Int,
        reviewCount: Int = 3,
        updatedDaysAgo: Int = 0,
        today: Date
    ) -> LearningRecord {
        let due = calendar.date(byAdding: .day, value: dueDaysFromToday, to: today)!
        let updated = calendar.date(byAdding: .day, value: -updatedDaysAgo, to: today)!
        return LearningRecord(
            id: id, kind: "problem", canonicalKey: "leetcode:\(id)", title: id, question: "",
            diagnosis: "", labels: [], prerequisiteLabels: [], knowledgePath: [],
            masteryScore: mastery, confidence: 0.8, evidenceCount: 0, evidence: [], sourceRefs: [],
            language: "java", dueAt: due, reviewCount: reviewCount, activeStudyPackage: nil,
            latestAttempt: nil, activePackageAttemptCount: 0, updatedAt: updated
        )
    }

    private var settings: LearningSettingsSnapshot {
        LearningSettingsSnapshot(
            dailyNewTarget: 3,
            weekdayReviewTarget: 4,
            weeklyReviewDay: 0,
            weeklyReviewTarget: 12,
            preferredLanguage: "java"
        )
    }

    @Test("只取当天配额，剩下的记成待处理而不是全摊出来")
    func honoursDailyQuota() {
        // 2026-08-11 是周二，不是周复习日 → 复习配额 4。
        let today = date(2026, 8, 11)
        let due = (0..<20).map { record(id: "due\($0)", dueDaysFromToday: -1 - $0, today: today) }
        let plan = LearningReviewSchedule.plan(records: due, settings: settings, reference: today, calendar: calendar)

        #expect(plan.reviewQuota == 4)
        #expect(plan.reviews.count == 4)
        #expect(plan.dueCount == 20)
        #expect(plan.deferred == 16)
        #expect(!plan.isWeeklyReviewDay)
    }

    @Test("逾期越久越靠前")
    func overdueFirst() {
        let today = date(2026, 8, 11)
        let records = [
            record(id: "fresh-due", dueDaysFromToday: 0, today: today),
            record(id: "overdue-10", dueDaysFromToday: -10, today: today),
            record(id: "overdue-3", dueDaysFromToday: -3, today: today)
        ]
        let plan = LearningReviewSchedule.plan(records: records, settings: settings, reference: today, calendar: calendar)

        #expect(plan.reviews.map(\.id) == ["overdue-10", "overdue-3", "fresh-due"])
        #expect(plan.overdueCount == 2)
    }

    @Test("同样逾期时，掌握得差的先练")
    func weakerFirstWhenEquallyOverdue() {
        let today = date(2026, 8, 11)
        let records = [
            record(id: "strong", mastery: 92, dueDaysFromToday: -5, today: today),
            record(id: "weak", mastery: 20, dueDaysFromToday: -5, today: today)
        ]
        let plan = LearningReviewSchedule.plan(records: records, settings: settings, reference: today, calendar: calendar)

        #expect(plan.reviews.map(\.id) == ["weak", "strong"])
    }

    @Test("熟练且还没到期的不进今日队列")
    func masteredAndNotDueStaysOut() {
        let today = date(2026, 8, 11)
        let records = [
            record(id: "later", mastery: 95, dueDaysFromToday: 6, today: today),
            record(id: "today", mastery: 40, dueDaysFromToday: 0, today: today)
        ]
        let plan = LearningReviewSchedule.plan(records: records, settings: settings, reference: today, calendar: calendar)

        #expect(plan.reviews.map(\.id) == ["today"])
        #expect(plan.dueCount == 1)
    }

    @Test("周复习日换成更大的配额")
    func weeklyReviewDayUsesWeeklyQuota() {
        // 2026-08-16 是周日，weeklyReviewDay = 0。
        let sunday = date(2026, 8, 16)
        #expect(calendar.component(.weekday, from: sunday) == 1)
        let due = (0..<20).map { record(id: "due\($0)", dueDaysFromToday: -1 - $0, today: sunday) }
        let plan = LearningReviewSchedule.plan(records: due, settings: settings, reference: sunday, calendar: calendar)

        #expect(plan.isWeeklyReviewDay)
        #expect(plan.reviewQuota == 12)
        #expect(plan.reviews.count == 12)
        #expect(plan.deferred == 8)
    }

    @Test("新知识走独立配额，不占复习名额")
    func newItemsHaveTheirOwnQuota() {
        let today = date(2026, 8, 11)
        let due = (0..<10).map { record(id: "due\($0)", dueDaysFromToday: -2, today: today) }
        let fresh = (0..<8).map {
            record(id: "new\($0)", dueDaysFromToday: 1, reviewCount: 0, updatedDaysAgo: $0, today: today)
        }
        let plan = LearningReviewSchedule.plan(records: due + fresh, settings: settings, reference: today, calendar: calendar)

        #expect(plan.reviews.count == 4)
        #expect(plan.fresh.count == 3)
        #expect(plan.queue.count == 7)
        // 最近沉淀的新知识先学。
        #expect(plan.fresh.map(\.id) == ["new0", "new1", "new2"])
        // 新知识没到期也算今天要学，但不计入 dueCount。
        #expect(plan.dueCount == 10)
    }

    @Test("配额为 0 时今天就不排任务")
    func zeroQuotaSchedulesNothing() {
        let today = date(2026, 8, 11)
        var quiet = settings
        quiet.weekdayReviewTarget = 0
        quiet.dailyNewTarget = 0
        let records = [
            record(id: "due", dueDaysFromToday: -3, today: today),
            record(id: "new", dueDaysFromToday: 1, reviewCount: 0, today: today)
        ]
        let plan = LearningReviewSchedule.plan(records: records, settings: quiet, reference: today, calendar: calendar)

        #expect(plan.isEmpty)
        #expect(plan.deferred == 1)
    }

    @Test("队列行说明与状态一致")
    func reasonMatchesState() {
        let today = date(2026, 8, 11)
        let overdue = record(id: "a", dueDaysFromToday: -4, today: today)
        let dueToday = record(id: "b", dueDaysFromToday: 0, today: today)
        let brandNew = record(id: "c", dueDaysFromToday: 2, reviewCount: 0, today: today)

        #expect(LearningReviewSchedule.reason(for: overdue, reference: today, calendar: calendar) == "逾期 4 天")
        #expect(LearningReviewSchedule.reason(for: dueToday, reference: today, calendar: calendar) == "今天到期")
        #expect(LearningReviewSchedule.reason(for: brandNew, reference: today, calendar: calendar) == "新知识")
    }
}
