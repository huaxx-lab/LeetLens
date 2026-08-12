import SwiftUI

/// 力扣「动态」页热力图的纯布局与取色逻辑。
/// 抽成独立类型是为了能在测试里断言周对齐、月份标签与命中判定，不必渲染视图。
enum LeetCodeActivityCalendar {
    static let rowCount = 7
    static let weekCount = 53

    struct Day: Identifiable, Hashable, Sendable {
        var id: Date { date }
        let date: Date
        let submissionCount: Int
        let acceptedCount: Int
    }

    struct MonthLabel: Identifiable, Hashable, Sendable {
        var id: Int { column }
        let column: Int
        let title: String
    }

    /// 颜色分档阈值。用非零提交量的分位数，而不是 `max` 的四等分：
    /// 偶发的一天 30 次提交会把其余所有日子压成最浅一档，整张图就没有信息量了。
    struct Thresholds: Hashable, Sendable {
        let level1: Int
        let level2: Int
        let level3: Int
        let level4: Int

        static let empty = Thresholds(level1: 1, level2: 2, level3: 3, level4: 4)
    }

    struct Layout: Equatable, Sendable {
        /// 每列是一个自然周，行号即星期（受 `calendar.firstWeekday` 影响）。
        /// 未来日期用 nil 占位，保证每列恒为 7 行。
        var columns: [[Day?]] = []
        var monthLabels: [MonthLabel] = []
        var weekdaySymbols: [String] = []
        var thresholds = Thresholds.empty
        var recentWeek: [Day] = []
        var totalSubmissions = 0
        var totalAccepted = 0
        var activeDays = 0
        var currentStreak = 0
        var longestStreak = 0
        var busiestDay: Day?

        static let empty = Layout()

        func day(column: Int, row: Int) -> Day? {
            guard columns.indices.contains(column), columns[column].indices.contains(row) else { return nil }
            return columns[column][row]
        }
    }

    struct Metrics: Equatable, Sendable {
        let cell: CGFloat
        let gap: CGFloat
        let columns: Int

        var pitch: CGFloat { cell + gap }
        var width: CGFloat { CGFloat(max(0, columns - 1)) * pitch + cell }
        var height: CGFloat { CGFloat(rowCount - 1) * pitch + cell }

        /// 53 周 × 最小格子仍要 527pt；窄于此就横向滚动，而不是把格子压到看不清。
        func overflows(availableWidth: CGFloat) -> Bool { width > availableWidth + 0.5 }
    }

    /// 由可用宽度反推格子边长。上限 18 是为了让 53 周在宽窗口里仍是「一张热力图」
    /// 而不是一片方块墙；下限 7 保证窄窗口下相邻两天还看得出缝。
    static func metrics(availableWidth: CGFloat, columns: Int, gap: CGFloat = 3) -> Metrics {
        let columnCount = max(1, columns)
        let usable = max(0, availableWidth) - CGFloat(columnCount - 1) * gap
        let raw = usable / CGFloat(columnCount)
        return Metrics(cell: min(18, max(7, raw)), gap: gap, columns: columnCount)
    }

    /// 命中判定。落在格与格之间的缝里返回 nil，否则 tooltip 会在两格之间来回抖。
    static func hitTest(_ point: CGPoint, metrics: Metrics) -> (column: Int, row: Int)? {
        guard point.x >= 0, point.y >= 0, metrics.pitch > 0 else { return nil }
        let column = Int(point.x / metrics.pitch)
        let row = Int(point.y / metrics.pitch)
        guard column >= 0, column < metrics.columns, row >= 0, row < rowCount else { return nil }
        guard point.x - CGFloat(column) * metrics.pitch <= metrics.cell,
              point.y - CGFloat(row) * metrics.pitch <= metrics.cell
        else { return nil }
        return (column, row)
    }

    static func level(_ count: Int, thresholds: Thresholds) -> Int {
        guard count > 0 else { return 0 }
        if count >= thresholds.level4 { return 4 }
        if count >= thresholds.level3 { return 3 }
        if count >= thresholds.level2 { return 2 }
        return 1
    }

    static func thresholds(from counts: [Int]) -> Thresholds {
        let active = counts.filter { $0 > 0 }.sorted()
        guard !active.isEmpty else { return .empty }
        func quantile(_ ratio: Double) -> Int {
            let index = Int((Double(active.count - 1) * ratio).rounded())
            return active[min(max(0, index), active.count - 1)]
        }
        var levels = [1, quantile(0.45), quantile(0.75), quantile(0.92)]
        // 阈值必须严格递增，否则相邻档位会被画成同一种绿色。
        for index in 1..<levels.count {
            levels[index] = max(levels[index], levels[index - 1] + 1)
        }
        return Thresholds(level1: levels[0], level2: levels[1], level3: levels[2], level4: levels[3])
    }

    static func layout(
        activity: [LeetCodeActivityDay],
        reference: Date = .now,
        calendar: Calendar = .current
    ) -> Layout {
        let today = calendar.startOfDay(for: reference)
        // 以「今天所在自然周」的周首为锚点，向前推 52 周。
        // 旧实现直接从 today-363 起算，列与星期完全对不上，行标签根本没法标。
        let currentWeekStart = calendar.dateInterval(of: .weekOfYear, for: today)?.start ?? today
        guard let firstColumnStart = calendar.date(byAdding: .day, value: -7 * (weekCount - 1), to: currentWeekStart) else {
            return .empty
        }

        var counts: [Date: LeetCodeActivityDay] = [:]
        counts.reserveCapacity(activity.count)
        for day in activity {
            counts[calendar.startOfDay(for: day.date)] = day
        }

        var result = Layout()
        result.columns.reserveCapacity(weekCount)
        var observedCounts: [Int] = []
        var activeDates: Set<Date> = []

        for column in 0..<weekCount {
            var week: [Day?] = []
            week.reserveCapacity(rowCount)
            for row in 0..<rowCount {
                guard let date = calendar.date(byAdding: .day, value: column * rowCount + row, to: firstColumnStart),
                      date <= today
                else {
                    week.append(nil)
                    continue
                }
                let record = counts[date]
                let day = Day(
                    date: date,
                    submissionCount: record?.submissionCount ?? 0,
                    acceptedCount: record?.acceptedCount ?? 0
                )
                week.append(day)
                if day.submissionCount > 0 {
                    observedCounts.append(day.submissionCount)
                    activeDates.insert(date)
                    result.totalSubmissions += day.submissionCount
                    result.totalAccepted += day.acceptedCount
                    if day.submissionCount > (result.busiestDay?.submissionCount ?? 0) {
                        result.busiestDay = day
                    }
                }
            }
            result.columns.append(week)
        }

        result.activeDays = activeDates.count
        result.thresholds = thresholds(from: observedCounts)
        result.monthLabels = monthLabels(firstColumnStart: firstColumnStart, calendar: calendar)
        result.weekdaySymbols = weekdaySymbols(calendar: calendar)
        result.recentWeek = recentWeek(until: today, counts: counts, calendar: calendar)
        result.currentStreak = currentStreak(until: today, activeDates: activeDates, calendar: calendar)
        result.longestStreak = longestStreak(activeDates: activeDates, calendar: calendar)
        return result
    }

    static func monthLabels(firstColumnStart: Date, calendar: Calendar) -> [MonthLabel] {
        var labels: [MonthLabel] = []
        var lastMonth = -1
        for column in 0..<weekCount {
            guard let columnStart = calendar.date(byAdding: .day, value: column * rowCount, to: firstColumnStart) else { continue }
            let month = calendar.component(.month, from: columnStart)
            guard month != lastMonth else { continue }
            lastMonth = month
            // 相邻标签至少隔 3 列，否则月初落在周中时两个月份会挤成一团。
            if let previous = labels.last, column - previous.column < 3 { continue }
            labels.append(MonthLabel(column: column, title: "\(month) 月"))
        }
        return labels
    }

    static func weekdaySymbols(calendar: Calendar) -> [String] {
        let symbols = calendar.veryShortWeekdaySymbols
        guard symbols.count == rowCount else { return symbols }
        let offset = max(0, min(rowCount - 1, calendar.firstWeekday - 1))
        return Array(symbols[offset...] + symbols[..<offset])
    }

    static func recentWeek(until today: Date, counts: [Date: LeetCodeActivityDay], calendar: Calendar) -> [Day] {
        (0..<rowCount).reversed().compactMap { offset in
            calendar.date(byAdding: .day, value: -offset, to: today).map { date in
                let record = counts[date]
                return Day(
                    date: date,
                    submissionCount: record?.submissionCount ?? 0,
                    acceptedCount: record?.acceptedCount ?? 0
                )
            }
        }
    }

    /// 当前连续天数：今天没提交也允许从昨天起算（当天还没开始刷不该把连击清零）。
    static func currentStreak(until today: Date, activeDates: Set<Date>, calendar: Calendar) -> Int {
        var cursor = today
        if !activeDates.contains(cursor) {
            guard let yesterday = calendar.date(byAdding: .day, value: -1, to: today) else { return 0 }
            cursor = yesterday
        }
        var streak = 0
        while activeDates.contains(cursor) {
            streak += 1
            guard let previous = calendar.date(byAdding: .day, value: -1, to: cursor) else { break }
            cursor = previous
        }
        return streak
    }

    static func longestStreak(activeDates: Set<Date>, calendar: Calendar) -> Int {
        var best = 0
        for date in activeDates {
            guard let previous = calendar.date(byAdding: .day, value: -1, to: date),
                  !activeDates.contains(previous)
            else { continue }
            var streak = 0
            var cursor = date
            while activeDates.contains(cursor) {
                streak += 1
                guard let next = calendar.date(byAdding: .day, value: 1, to: cursor) else { break }
                cursor = next
            }
            best = max(best, streak)
        }
        return best
    }

    static func palette(for scheme: ColorScheme) -> [Color] {
        scheme == .dark
            ? [
                Color(red: 1, green: 1, blue: 1, opacity: 0.07),
                Color(red: 0.055, green: 0.267, blue: 0.161),
                Color(red: 0, green: 0.427, blue: 0.196),
                Color(red: 0.149, green: 0.651, blue: 0.255),
                Color(red: 0.224, green: 0.827, blue: 0.325)
            ]
            : [
                Color(red: 0, green: 0, blue: 0, opacity: 0.06),
                Color(red: 0.784, green: 0.918, blue: 0.816),
                Color(red: 0.482, green: 0.835, blue: 0.545),
                Color(red: 0.208, green: 0.678, blue: 0.329),
                Color(red: 0.094, green: 0.525, blue: 0.231)
            ]
    }
}

/// 「动态」页右侧几张分布卡的数据，一次遍历算好，避免每帧重扫题库与提交。
struct LeetCodeActivityInsight: Equatable, Sendable {
    struct DifficultyRow: Identifiable, Equatable, Sendable {
        var id: String { key }
        let key: String
        let title: String
        let solved: Int
        let total: Int
    }

    struct CountRow: Identifiable, Equatable, Sendable {
        var id: String { title }
        let title: String
        let count: Int
    }

    var difficulties: [DifficultyRow] = []
    var languages: [CountRow] = []
    var topics: [CountRow] = []
    var solvedCount = 0
    var totalQuestions = 0
    var planName = ""

    static let empty = LeetCodeActivityInsight()

    var completion: Int {
        guard totalQuestions > 0 else { return 0 }
        return Int((Double(solvedCount) / Double(totalQuestions) * 100).rounded())
    }

    static func make(
        questions: [LeetCodeQuestion],
        submissions: [LeetCodeSubmission],
        plan: LeetCodePlanSummary?
    ) -> LeetCodeActivityInsight {
        var insight = LeetCodeActivityInsight()
        var difficultyTotals: [String: (solved: Int, total: Int)] = [:]
        var topicCounts: [String: Int] = [:]
        var solved = 0

        for question in questions {
            let difficulty = question.difficulty.uppercased()
            let isSolved = question.status == "SOLVED"
            if isSolved { solved += 1 }
            if !difficulty.isEmpty {
                var bucket = difficultyTotals[difficulty] ?? (0, 0)
                bucket.total += 1
                if isSolved { bucket.solved += 1 }
                difficultyTotals[difficulty] = bucket
            }
            guard isSolved else { continue }
            let topic = question.groupName.isEmpty ? (question.topicTags.first ?? "") : question.groupName
            guard !topic.isEmpty else { continue }
            topicCounts[topic, default: 0] += 1
        }

        var languageCounts: [String: Int] = [:]
        for submission in submissions {
            let language = submission.language.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !language.isEmpty else { continue }
            languageCounts[language, default: 0] += 1
        }

        insight.difficulties = [("EASY", "简单"), ("MEDIUM", "中等"), ("HARD", "困难")].map { key, title in
            let bucket = difficultyTotals[key] ?? (0, 0)
            return DifficultyRow(key: key, title: title, solved: bucket.solved, total: bucket.total)
        }
        insight.languages = topRows(languageCounts, limit: 4)
        insight.topics = topRows(topicCounts, limit: 6)
        insight.solvedCount = plan?.solvedCount ?? solved
        insight.totalQuestions = plan?.questionCount ?? questions.count
        insight.planName = plan?.name ?? "全部题目"
        return insight
    }

    private static func topRows(_ counts: [String: Int], limit: Int) -> [CountRow] {
        counts
            .sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }
            .prefix(limit)
            .map { CountRow(title: $0.key, count: $0.value) }
    }
}

// MARK: - 热力图

struct LeetCodeActivityHeatmapCard: View {
    let layout: LeetCodeActivityCalendar.Layout

    @Environment(\.colorScheme) private var colorScheme
    @State private var cardWidth: CGFloat = 0
    @State private var hover: Hover?
    @State private var tooltipSize = CGSize.zero

    /// 卡片左右各 18pt 内边距，星期列 16pt + 8pt 间距。
    private var gridWidth: CGFloat { max(0, cardWidth - 18 * 2 - 16 - 8) }

    private var metrics: LeetCodeActivityCalendar.Metrics {
        LeetCodeActivityCalendar.metrics(availableWidth: gridWidth, columns: layout.columns.count)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            grid
            footer
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .navigationGlass(cornerRadius: AppDesign.Radius.floating)
        // 测卡片而不是测格子：格子宽度由 metrics 决定，测它自己会形成布局回环。
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { cardWidth = $0 }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 3) {
                Text("年度提交").font(AppDesign.Typography.sectionTitle)
                Text("过去 53 周 · 颜色越深，当天提交越密集")
                    .font(AppDesign.Typography.aux)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            HStack(spacing: 6) {
                Text("\(layout.totalSubmissions)")
                    .font(AppDesign.Typography.metricValue)
                Text("次提交")
                    .font(AppDesign.Typography.aux)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var grid: some View {
        HStack(alignment: .top, spacing: 8) {
            weekdayColumn
            // 窗口窄到塞不下 53 周时横向滚动并停在最近一周，
            // 而不是把格子压到看不出深浅。
            ScrollView(.horizontal) {
                VStack(alignment: .leading, spacing: 5) {
                    monthRow
                    canvas
                }
                .frame(width: metrics.width, alignment: .leading)
            }
            // 只有真的溢出才靠右（停在最近一周）；否则靠右会把整张图推离星期列。
            .defaultScrollAnchor(metrics.overflows(availableWidth: gridWidth) ? .trailing : .leading)
            .scrollDisabled(!metrics.overflows(availableWidth: gridWidth))
            .floatingScrollIndicators(.horizontal)
        }
    }

    private var weekdayColumn: some View {
        VStack(alignment: .trailing, spacing: metrics.gap) {
            ForEach(0..<LeetCodeActivityCalendar.rowCount, id: \.self) { row in
                Text(row % 2 == 1 ? symbol(row) : "")
                    .font(AppDesign.Typography.micro)
                    .foregroundStyle(.secondary)
                    .frame(height: metrics.cell, alignment: .center)
            }
        }
        .frame(width: 16, alignment: .trailing)
        // 与月份标签行等高的顶部留白，让星期与格子逐行对齐。
        .padding(.top, monthRowHeight + 5)
    }

    private var monthRow: some View {
        ZStack(alignment: .topLeading) {
            ForEach(layout.monthLabels) { label in
                Text(label.title)
                    .font(AppDesign.Typography.micro)
                    .foregroundStyle(.secondary)
                    .fixedSize()
                    .offset(x: CGFloat(label.column) * metrics.pitch)
            }
        }
        .frame(width: metrics.width, height: monthRowHeight, alignment: .topLeading)
    }

    private var canvas: some View {
        let palette = LeetCodeActivityCalendar.palette(for: colorScheme)
        let metrics = metrics
        let layout = layout
        let hoveredIndex = hover.map { (column: $0.column, row: $0.row) }
        return Canvas(opaque: false) { context, _ in
            let radius = max(2, metrics.cell * 0.24)
            for (columnIndex, week) in layout.columns.enumerated() {
                for (rowIndex, day) in week.enumerated() {
                    guard let day else { continue }
                    let level = LeetCodeActivityCalendar.level(day.submissionCount, thresholds: layout.thresholds)
                    let rect = CGRect(
                        x: CGFloat(columnIndex) * metrics.pitch,
                        y: CGFloat(rowIndex) * metrics.pitch,
                        width: metrics.cell,
                        height: metrics.cell
                    )
                    context.fill(
                        Path(roundedRect: rect, cornerRadius: radius, style: .continuous),
                        with: .color(palette[min(level, palette.count - 1)])
                    )
                }
            }
            guard let hoveredIndex else { return }
            let rect = CGRect(
                x: CGFloat(hoveredIndex.column) * metrics.pitch,
                y: CGFloat(hoveredIndex.row) * metrics.pitch,
                width: metrics.cell,
                height: metrics.cell
            )
            context.stroke(
                Path(roundedRect: rect.insetBy(dx: -1.5, dy: -1.5), cornerRadius: radius + 1.5, style: .continuous),
                with: .color(.primary.opacity(0.55)),
                lineWidth: 1.5
            )
        }
        .frame(width: metrics.width, height: metrics.height)
        // Canvas 只画不参与命中，没有这行整块 hover 收不到指针事件。
        .contentShape(Rectangle())
        // 371 个格子各挂一个 .help 会建 371 个 tracking area；改成整块 hover + 命中计算，只留一个浮层。
        .onContinuousHover(coordinateSpace: .local) { phase in
            switch phase {
            case .active(let point):
                guard let hit = LeetCodeActivityCalendar.hitTest(point, metrics: metrics),
                      let day = layout.day(column: hit.column, row: hit.row)
                else {
                    hover = nil
                    return
                }
                hover = Hover(column: hit.column, row: hit.row, day: day)
            case .ended:
                hover = nil
            }
        }
        .overlay(alignment: .topLeading) { tooltip }
        .accessibilityElement()
        .accessibilityLabel("近一年提交热力图")
        .accessibilityValue("\(layout.activeDays) 个活跃日，共 \(layout.totalSubmissions) 次提交")
    }

    @ViewBuilder
    private var tooltip: some View {
        if let hover {
            let text = tooltipText(hover.day)
            Text(text)
                .font(AppDesign.Typography.aux)
                .fixedSize()
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .navigationGlass(cornerRadius: AppDesign.Radius.medium)
                .onGeometryChange(for: CGSize.self) { $0.size } action: { tooltipSize = $0 }
                .offset(tooltipOffset(hover))
                .allowsHitTesting(false)
                .transition(.opacity)
        }
    }

    private var footer: some View {
        HStack(spacing: 12) {
            HStack(spacing: 5) {
                Text("少").font(AppDesign.Typography.micro).foregroundStyle(.secondary)
                ForEach(0..<5, id: \.self) { level in
                    RoundedRectangle(cornerRadius: 2.5, style: .continuous)
                        .fill(LeetCodeActivityCalendar.palette(for: colorScheme)[level])
                        .frame(width: 10, height: 10)
                }
                Text("多").font(AppDesign.Typography.micro).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .inlineGlass(cornerRadius: AppDesign.Radius.small)

            Spacer(minLength: 8)

            Text(summary)
                .font(AppDesign.Typography.aux)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }

    private var summary: String {
        var parts = ["\(layout.activeDays) 个活跃日", "最长连续 \(layout.longestStreak) 天"]
        if let busiest = layout.busiestDay, busiest.submissionCount > 0 {
            parts.append("单日最多 \(busiest.submissionCount) 次（\(shortDate(busiest.date))）")
        }
        return parts.joined(separator: " · ")
    }

    private var monthRowHeight: CGFloat { 13 }

    private func symbol(_ row: Int) -> String {
        layout.weekdaySymbols.indices.contains(row) ? layout.weekdaySymbols[row] : ""
    }

    private func tooltipText(_ day: LeetCodeActivityCalendar.Day) -> String {
        let date = day.date.formatted(.dateTime.year().month(.defaultDigits).day().weekday(.wide))
        guard day.submissionCount > 0 else { return "\(date) · 没有提交" }
        return "\(date) · \(day.submissionCount) 次提交 · \(day.acceptedCount) 次通过"
    }

    private func tooltipOffset(_ hover: Hover) -> CGSize {
        let centerX = CGFloat(hover.column) * metrics.pitch + metrics.cell / 2
        let maximumX = max(0, metrics.width - tooltipSize.width)
        let x = min(max(0, centerX - tooltipSize.width / 2), maximumX)
        let anchorY = CGFloat(hover.row) * metrics.pitch
        // 顶部两行没有向上的空间，改为挂在格子下方。
        let y = anchorY - tooltipSize.height - 7 < 0
            ? anchorY + metrics.cell + 7
            : anchorY - tooltipSize.height - 7
        return CGSize(width: x, height: y)
    }

    private func shortDate(_ date: Date) -> String {
        date.formatted(.dateTime.month(.defaultDigits).day())
    }

    private struct Hover: Equatable {
        let column: Int
        let row: Int
        let day: LeetCodeActivityCalendar.Day
    }
}

// MARK: - 指标条

struct LeetCodeActivityMetricsRow: View {
    let layout: LeetCodeActivityCalendar.Layout
    let insight: LeetCodeActivityInsight
    let dueCount: Int
    let weakCount: Int

    private var acceptanceRate: Int {
        guard layout.totalSubmissions > 0 else { return 0 }
        return Int((Double(layout.totalAccepted) / Double(layout.totalSubmissions) * 100).rounded())
    }

    private var weekSubmissions: Int {
        layout.recentWeek.reduce(0) { $0 + $1.submissionCount }
    }

    var body: some View {
        LazyVGrid(
            columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 4),
            spacing: 12
        ) {
            completionCard
            metricCard(
                value: "\(layout.currentStreak)",
                unit: " 天",
                title: "连续学习",
                caption: "最长 \(layout.longestStreak) 天 · 本周 \(weekSubmissions) 次",
                icon: "flame.fill",
                tint: .orange
            )
            metricCard(
                value: "\(acceptanceRate)",
                unit: "%",
                title: "通过提交占比",
                caption: "\(layout.totalAccepted) 次通过 / \(layout.totalSubmissions) 次",
                icon: "checkmark.seal.fill",
                tint: .green
            )
            metricCard(
                value: "\(dueCount)",
                unit: " 题",
                title: "等待复习",
                caption: weakCount > 0 ? "\(weakCount) 个薄弱知识点" : "复习进度良好",
                icon: "clock.arrow.circlepath",
                tint: dueCount > 0 ? .pink : .secondary
            )
        }
    }

    private var completionCard: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle()
                    .stroke(Color.primary.opacity(0.08), lineWidth: 5)
                Circle()
                    .trim(from: 0, to: max(0.001, Double(insight.completion) / 100))
                    .stroke(
                        AngularGradient(
                            colors: [Color.accentColor.opacity(0.55), .accentColor],
                            center: .center
                        ),
                        style: StrokeStyle(lineWidth: 5, lineCap: .round)
                    )
                    .rotationEffect(.degrees(-90))
                Text("\(insight.completion)%")
                    .font(AppDesign.Typography.auxEmphasis.monospacedDigit())
            }
            .frame(width: 46, height: 46)
            .animation(AppDesign.Motion.fade, value: insight.completion)

            VStack(alignment: .leading, spacing: 3) {
                Text("题单完成度").font(AppDesign.Typography.bodyEmphasis)
                Text("\(insight.solvedCount) / \(insight.totalQuestions) 题")
                    .font(AppDesign.Typography.aux)
                    .foregroundStyle(.secondary)
                Text(insight.planName)
                    .font(AppDesign.Typography.micro)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .inlineGlass(cornerRadius: AppDesign.Radius.card)
    }

    private func metricCard(
        value: String,
        unit: String,
        title: String,
        caption: String,
        icon: String,
        tint: Color
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(AppDesign.Typography.iconCompact)
                    .foregroundStyle(tint)
                Text(title).font(AppDesign.Typography.aux).foregroundStyle(.secondary)
            }
            HStack(alignment: .firstTextBaseline, spacing: 0) {
                Text(value).font(AppDesign.Typography.metricValue)
                Text(unit).font(AppDesign.Typography.aux).foregroundStyle(.secondary)
            }
            Text(caption)
                .font(AppDesign.Typography.micro)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .inlineGlass(cornerRadius: AppDesign.Radius.card)
    }
}

// MARK: - 分布卡

struct LeetCodeActivityBreakdown: View {
    let insight: LeetCodeActivityInsight

    var body: some View {
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 300), spacing: 14)],
            alignment: .leading,
            spacing: 14
        ) {
            difficultyCard
            languageCard
            topicCard
        }
    }

    private var difficultyCard: some View {
        ActivityInsightCard("难度完成", subtitle: insight.planName) {
            VStack(spacing: 9) {
                ForEach(insight.difficulties) { row in
                    bar(
                        title: row.title,
                        value: Double(row.solved),
                        total: Double(max(1, row.total)),
                        trailing: "\(row.solved) / \(row.total)",
                        tint: difficultyTint(row.key)
                    )
                }
            }
        }
    }

    private var languageCard: some View {
        ActivityInsightCard("常用语言", subtitle: "全部提交") {
            if insight.languages.isEmpty {
                emptyHint("同步提交记录后自动统计")
            } else {
                let maximum = Double(max(1, insight.languages.map(\.count).max() ?? 1))
                VStack(spacing: 9) {
                    ForEach(insight.languages) { row in
                        bar(
                            title: row.title,
                            value: Double(row.count),
                            total: maximum,
                            trailing: "\(row.count)",
                            tint: .blue
                        )
                    }
                }
            }
        }
    }

    private var topicCard: some View {
        ActivityInsightCard("优势专题", subtitle: "已通过题目") {
            if insight.topics.isEmpty {
                emptyHint("完成题目后自动形成")
            } else {
                FlowLayout(spacing: 6) {
                    ForEach(insight.topics) { row in
                        HStack(spacing: 5) {
                            Text(row.title).font(AppDesign.Typography.aux)
                            Text("\(row.count)")
                                .font(AppDesign.Typography.micro.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 9)
                        .padding(.vertical, 5)
                        .inlineGlass(cornerRadius: AppDesign.Radius.small)
                    }
                }
            }
        }
    }

    private func bar(title: String, value: Double, total: Double, trailing: String, tint: Color) -> some View {
        HStack(spacing: 10) {
            Text(title)
                .font(AppDesign.Typography.aux)
                .frame(width: 62, alignment: .leading)
                .lineLimit(1)
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.06))
                    Capsule()
                        .fill(LinearGradient(colors: [tint.opacity(0.9), tint.opacity(0.55)], startPoint: .leading, endPoint: .trailing))
                        .frame(width: max(0, proxy.size.width * min(1, value / max(1, total))))
                }
            }
            .frame(height: 7)
            Text(trailing)
                .font(AppDesign.Typography.micro.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 60, alignment: .trailing)
        }
    }

    private func emptyHint(_ text: String) -> some View {
        Text(text)
            .font(AppDesign.Typography.aux)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func difficultyTint(_ key: String) -> Color {
        switch key { case "EASY": .green; case "HARD": .red; default: .orange }
    }
}

/// 最近七天的提交节奏。放在热力图右侧，既补上年度视图看不出的「本周手感」，
/// 也让热力图卡片收窄到格子刚好铺满的宽度。
struct LeetCodeActivityWeekRhythm: View {
    let layout: LeetCodeActivityCalendar.Layout

    var body: some View {
        ActivityInsightCard("最近七天", subtitle: "每日提交") {
            let maximum = max(1, layout.recentWeek.map(\.submissionCount).max() ?? 1)
            HStack(alignment: .bottom, spacing: 8) {
                ForEach(layout.recentWeek) { day in
                    VStack(spacing: 6) {
                        Spacer(minLength: 0)
                        Text(day.submissionCount > 0 ? "\(day.submissionCount)" : "")
                            .font(AppDesign.Typography.micro.monospacedDigit())
                            .foregroundStyle(.secondary)
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .fill(
                                LinearGradient(
                                    colors: [Color.accentColor.opacity(0.85), Color.accentColor.opacity(0.45)],
                                    startPoint: .top,
                                    endPoint: .bottom
                                )
                            )
                            .frame(height: max(4, 58 * CGFloat(day.submissionCount) / CGFloat(maximum)))
                            .opacity(day.submissionCount > 0 ? 1 : 0.25)
                        Text(weekdayTitle(day.date))
                            .font(AppDesign.Typography.micro)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            .frame(height: 92)
        }
    }

    private func weekdayTitle(_ date: Date) -> String {
        date.formatted(.dateTime.weekday(.abbreviated))
    }
}

/// 分布卡的统一外壳：标题 + 副标题 + 内容，贴附式玻璃。
struct ActivityInsightCard<Content: View>: View {
    private let title: String
    private let subtitle: String
    private let content: Content

    init(_ title: String, subtitle: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.subtitle = subtitle
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(title).font(AppDesign.Typography.bodyEmphasis)
                Text(subtitle)
                    .font(AppDesign.Typography.micro)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            content
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .inlineGlass(cornerRadius: AppDesign.Radius.card)
    }
}
