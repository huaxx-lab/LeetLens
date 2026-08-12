import Foundation
import Testing
@testable import LeetCodeAssistant

@Suite("学习洞察")
struct LearningInsightsTests {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai") ?? .current
        calendar.firstWeekday = 1
        return calendar
    }

    private func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 9) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour))!
    }

    private func record(
        id: String,
        topic: String = "双指针",
        mastery: Double = 50,
        dueDaysFromToday: Int,
        reviewCount: Int = 3,
        today: Date
    ) -> LearningRecord {
        LearningRecord(
            id: id, kind: "problem", canonicalKey: "leetcode:\(id)", title: id, question: "",
            diagnosis: "", labels: [], prerequisiteLabels: [], knowledgePath: ["算法与解题模式", topic],
            masteryScore: mastery, confidence: 0.8, evidenceCount: 1, evidence: [], sourceRefs: [],
            language: "java",
            dueAt: calendar.date(byAdding: .day, value: dueDaysFromToday, to: today)!,
            reviewCount: reviewCount, activeStudyPackage: nil, latestAttempt: nil,
            activePackageAttemptCount: 0, updatedAt: today
        )
    }

    @Test("优先巩固按逾期与掌握度排序，而不是原始顺序")
    func focusIsActuallyRanked() {
        // 旧实现是 activeLearningRecords.prefix(6)：完全不排序，
        // 于是"刚学会且没到期"的会排在"逾期十天且掌握很差"的前面。
        let today = date(2026, 8, 11)
        let records = [
            record(id: "fresh-strong", mastery: 95, dueDaysFromToday: 6, today: today),
            record(id: "overdue-weak", mastery: 20, dueDaysFromToday: -10, today: today),
            record(id: "due-today", mastery: 55, dueDaysFromToday: 0, today: today)
        ]

        let focus = LearningInsights.focus(records: records, reference: today, calendar: calendar)
        #expect(focus.map(\.id) == ["overdue-weak", "due-today", "fresh-strong"])
    }

    @Test("优先巩固截到 limit")
    func focusRespectsLimit() {
        let today = date(2026, 8, 11)
        let records = (0..<10).map { record(id: "r\($0)", dueDaysFromToday: -$0, today: today) }
        #expect(LearningInsights.focus(records: records, limit: 4, reference: today, calendar: calendar).count == 4)
    }

    @Test("主题统计给出平均掌握度、逾期数与薄弱数")
    func topicStatsAggregate() {
        let today = date(2026, 8, 11)
        let records = [
            record(id: "a", topic: "双指针", mastery: 40, dueDaysFromToday: -2, today: today),
            record(id: "b", topic: "双指针", mastery: 80, dueDaysFromToday: 3, today: today),
            record(id: "c", topic: "动态规划", mastery: 90, dueDaysFromToday: 5, today: today)
        ]

        let topics = LearningInsights.topics(records: records, reference: today, calendar: calendar)
        // 最薄弱的主题排最前。
        #expect(topics.map(\.name) == ["双指针", "动态规划"])

        let pointer = topics[0]
        #expect(pointer.count == 2)
        #expect(pointer.averageMastery == 60)
        #expect(pointer.overdueCount == 1)
        #expect(pointer.weakCount == 1)

        #expect(topics[1].overdueCount == 0)
        #expect(topics[1].weakCount == 0)
    }

    @Test("到期分布把逾期项全部算进今天")
    func forecastFoldsOverdueIntoToday() {
        let today = date(2026, 8, 11)
        let records = [
            record(id: "a", dueDaysFromToday: -30, today: today),
            record(id: "b", dueDaysFromToday: -1, today: today),
            record(id: "c", dueDaysFromToday: 0, today: today),
            record(id: "d", dueDaysFromToday: 2, today: today)
        ]

        let forecast = LearningInsights.dueForecast(records: records, days: 7, reference: today, calendar: calendar)
        #expect(forecast.count == 7)
        #expect(forecast[0].count == 3)
        #expect(forecast[0].includesOverdue)
        #expect(forecast[2].count == 1)
        #expect(!forecast[2].includesOverdue)
    }

    @Test("视野之外的到期不计入，格子按天连续")
    func forecastIgnoresBeyondHorizon() {
        let today = date(2026, 8, 11)
        let records = [record(id: "far", dueDaysFromToday: 20, today: today)]
        let forecast = LearningInsights.dueForecast(records: records, days: 7, reference: today, calendar: calendar)

        #expect(forecast.allSatisfy { $0.count == 0 })
        #expect(calendar.isDate(forecast[0].day, inSameDayAs: today))
        #expect(calendar.isDate(forecast[6].day, inSameDayAs: date(2026, 8, 17)))
    }

    @Test("没有学习项时三个统计都为空而不是崩")
    func handlesEmptyInput() {
        let today = date(2026, 8, 11)
        #expect(LearningInsights.focus(records: [], reference: today, calendar: calendar).isEmpty)
        #expect(LearningInsights.topics(records: [], reference: today, calendar: calendar).isEmpty)
        let forecast = LearningInsights.dueForecast(records: [], days: 7, reference: today, calendar: calendar)
        #expect(forecast.count == 7)
        #expect(forecast.allSatisfy { $0.count == 0 })
    }
}
