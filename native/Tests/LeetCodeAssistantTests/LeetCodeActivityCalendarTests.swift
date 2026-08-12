import Foundation
import Testing
@testable import LeetCodeAssistant

@Suite("力扣热力图布局")
struct LeetCodeActivityCalendarTests {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai") ?? .current
        calendar.firstWeekday = 1
        calendar.locale = Locale(identifier: "zh_CN")
        return calendar
    }

    private func date(_ year: Int, _ month: Int, _ day: Int) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: 12))!
    }

    @Test("每一列都是一个自然周，行号即星期")
    func columnsAlignToWeekdays() {
        // 2026-08-11 是周二。
        let layout = LeetCodeActivityCalendar.layout(activity: [], reference: date(2026, 8, 11), calendar: calendar)

        #expect(layout.columns.count == LeetCodeActivityCalendar.weekCount)
        for column in layout.columns {
            #expect(column.count == LeetCodeActivityCalendar.rowCount)
            for (row, day) in column.enumerated() {
                guard let day else { continue }
                // weekday 是 1...7（周日为 1），与 firstWeekday=1 时的行号一一对应。
                #expect(calendar.component(.weekday, from: day.date) == row + 1)
            }
        }
    }

    @Test("未来日期留空，最后一格是今天")
    func futureDaysStayEmpty() {
        let today = date(2026, 8, 11)
        let layout = LeetCodeActivityCalendar.layout(activity: [], reference: today, calendar: calendar)
        let lastColumn = layout.columns[layout.columns.count - 1]

        // 周二 → 行 0...2 有值（周日、周一、周二），其后全为 nil。
        #expect(lastColumn[2].map { calendar.isDate($0.date, inSameDayAs: today) } == true)
        #expect(lastColumn[3] == nil)
        #expect(lastColumn[6] == nil)
        let filled = layout.columns.flatMap { $0 }.compactMap { $0 }
        #expect(filled.allSatisfy { $0.date <= calendar.startOfDay(for: today) })
    }

    @Test("提交数落到对应格子并汇总")
    func submissionsLandOnTheirDay() {
        let today = date(2026, 8, 11)
        let activity = [
            LeetCodeActivityDay(date: calendar.startOfDay(for: today), submissionCount: 4, acceptedCount: 3),
            LeetCodeActivityDay(
                date: calendar.startOfDay(for: calendar.date(byAdding: .day, value: -1, to: today)!),
                submissionCount: 2,
                acceptedCount: 1
            )
        ]
        let layout = LeetCodeActivityCalendar.layout(activity: activity, reference: today, calendar: calendar)

        #expect(layout.totalSubmissions == 6)
        #expect(layout.totalAccepted == 4)
        #expect(layout.activeDays == 2)
        #expect(layout.busiestDay?.submissionCount == 4)
        #expect(layout.currentStreak == 2)
        #expect(layout.longestStreak == 2)
        #expect(layout.recentWeek.count == 7)
        #expect(layout.recentWeek.last?.submissionCount == 4)
    }

    @Test("今天还没提交时，连击从昨天起算")
    func streakToleratesToday() {
        let today = date(2026, 8, 11)
        let activity = (1...3).map { offset in
            LeetCodeActivityDay(
                date: calendar.startOfDay(for: calendar.date(byAdding: .day, value: -offset, to: today)!),
                submissionCount: 1,
                acceptedCount: 1
            )
        }
        let layout = LeetCodeActivityCalendar.layout(activity: activity, reference: today, calendar: calendar)

        #expect(layout.currentStreak == 3)
    }

    @Test("单日暴走不会把其余日子压成同一档")
    func thresholdsUseQuantilesNotMax() {
        let counts = Array(repeating: 1, count: 20) + [2, 3, 4, 30]
        let thresholds = LeetCodeActivityCalendar.thresholds(from: counts)

        #expect(thresholds.level1 == 1)
        #expect(thresholds.level2 > thresholds.level1)
        #expect(thresholds.level3 > thresholds.level2)
        #expect(thresholds.level4 > thresholds.level3)
        // 用 max 四等分的话 30 次里 1~7 都是 0 档；分位数必须让 1 次也着色。
        #expect(LeetCodeActivityCalendar.level(1, thresholds: thresholds) == 1)
        #expect(LeetCodeActivityCalendar.level(30, thresholds: thresholds) == 4)
        #expect(LeetCodeActivityCalendar.level(0, thresholds: thresholds) == 0)
    }

    @Test("没有任何提交时阈值退化但不崩")
    func thresholdsHandleEmptyInput() {
        let thresholds = LeetCodeActivityCalendar.thresholds(from: [])
        #expect(thresholds == .empty)
        #expect(LeetCodeActivityCalendar.level(0, thresholds: thresholds) == 0)
    }

    @Test("月份标签按列递增且不挤在一起")
    func monthLabelsStaySpaced() {
        let layout = LeetCodeActivityCalendar.layout(activity: [], reference: date(2026, 8, 11), calendar: calendar)
        let columns = layout.monthLabels.map(\.column)

        #expect(!layout.monthLabels.isEmpty)
        #expect(columns == columns.sorted())
        for (previous, current) in zip(columns, columns.dropFirst()) {
            #expect(current - previous >= 3)
        }
    }

    @Test("星期符号按 firstWeekday 轮转")
    func weekdaySymbolsRotate() {
        var mondayFirst = calendar
        mondayFirst.firstWeekday = 2
        let sunday = LeetCodeActivityCalendar.weekdaySymbols(calendar: calendar)
        let monday = LeetCodeActivityCalendar.weekdaySymbols(calendar: mondayFirst)

        #expect(sunday.count == 7)
        #expect(monday.count == 7)
        #expect(monday.first == sunday[1])
        #expect(monday.last == sunday[0])
    }

    @Test("命中判定落在格子上，缝隙里不命中")
    func hitTestIgnoresGaps() {
        let metrics = LeetCodeActivityCalendar.Metrics(cell: 12, gap: 3, columns: 53)

        #expect(LeetCodeActivityCalendar.hitTest(CGPoint(x: 1, y: 1), metrics: metrics)! == (0, 0))
        #expect(LeetCodeActivityCalendar.hitTest(CGPoint(x: 16, y: 16), metrics: metrics)! == (1, 1))
        // x=13.5 落在第 0 列与第 1 列之间的缝里。
        #expect(LeetCodeActivityCalendar.hitTest(CGPoint(x: 13.5, y: 4), metrics: metrics) == nil)
        #expect(LeetCodeActivityCalendar.hitTest(CGPoint(x: -1, y: 4), metrics: metrics) == nil)
        #expect(LeetCodeActivityCalendar.hitTest(CGPoint(x: 4, y: metrics.height + 4), metrics: metrics) == nil)
        #expect(LeetCodeActivityCalendar.hitTest(CGPoint(x: metrics.width + 4, y: 4), metrics: metrics) == nil)
    }

    @Test("格子尺寸随宽度收缩但有上下限")
    func metricsClampCellSize() {
        let narrow = LeetCodeActivityCalendar.metrics(availableWidth: 320, columns: 53)
        let wide = LeetCodeActivityCalendar.metrics(availableWidth: 4000, columns: 53)

        #expect(narrow.cell == 7)
        // 窄容器塞不下 53 周，改为横向滚动而不是把格子压扁。
        #expect(narrow.overflows(availableWidth: 320))
        #expect(wide.cell == 18)
        #expect(!wide.overflows(availableWidth: 4000))
        #expect(wide.height == wide.cell * 7 + wide.gap * 6, "实际高度 \(wide.height)")
    }

    @Test("分布卡按题目与提交聚合")
    func insightAggregatesQuestionsAndSubmissions() {
        let questions = [
            question(slug: "a", difficulty: "EASY", status: "SOLVED", group: "数组"),
            question(slug: "b", difficulty: "EASY", status: "TO_DO", group: "数组"),
            question(slug: "c", difficulty: "HARD", status: "SOLVED", group: "动态规划")
        ]
        let submissions = [
            submission(id: "1", language: "java"),
            submission(id: "2", language: "java"),
            submission(id: "3", language: "python3")
        ]
        let insight = LeetCodeActivityInsight.make(questions: questions, submissions: submissions, plan: nil)

        #expect(insight.solvedCount == 2)
        #expect(insight.totalQuestions == 3)
        #expect(insight.completion == 67)
        #expect(insight.difficulties.map(\.key) == ["EASY", "MEDIUM", "HARD"])
        #expect(insight.difficulties[0].solved == 1)
        #expect(insight.difficulties[0].total == 2)
        #expect(insight.difficulties[1].total == 0)
        #expect(insight.languages.first?.title == "java")
        #expect(insight.languages.first?.count == 2)
        #expect(Set(insight.topics.map(\.title)) == ["数组", "动态规划"])
    }

    @Test("题单存在时完成度以题单为准")
    func insightPrefersActivePlan() {
        let plan = LeetCodePlanSummary(id: "top-100", name: "热题 100", questionCount: 100, solvedCount: 25)
        let insight = LeetCodeActivityInsight.make(
            questions: [question(slug: "a", difficulty: "EASY", status: "SOLVED", group: "数组")],
            submissions: [],
            plan: plan
        )

        #expect(insight.solvedCount == 25)
        #expect(insight.totalQuestions == 100)
        #expect(insight.completion == 25)
        #expect(insight.planName == "热题 100")
    }

    @Test("题目为空时完成度不除零")
    func insightHandlesEmptyLibrary() {
        let insight = LeetCodeActivityInsight.make(questions: [], submissions: [], plan: nil)

        #expect(insight.completion == 0)
        #expect(insight.languages.isEmpty)
        #expect(insight.topics.isEmpty)
    }

    private func question(slug: String, difficulty: String, status: String, group: String) -> LeetCodeQuestion {
        LeetCodeQuestion(
            titleSlug: slug, frontendID: "1", title: slug, difficulty: difficulty, status: status,
            paidOnly: false, acceptanceRate: nil, groupName: group, topicTags: [],
            submissionCount: 0, acceptedCount: 0, lastSubmittedAt: nil
        )
    }

    private func submission(id: String, language: String) -> LeetCodeSubmission {
        LeetCodeSubmission(
            id: id, titleSlug: "a", title: "a", frontendID: "1", language: language,
            accepted: true, submittedAt: .now, activityType: "", status: "Accepted",
            runtime: "", memory: "", url: ""
        )
    }
}
