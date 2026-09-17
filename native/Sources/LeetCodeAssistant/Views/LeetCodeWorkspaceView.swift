import AppKit
import SwiftUI
import WebKit

struct LeetCodeWorkspaceView: View {
    @Bindable var workspace: WorkspaceState
    @Bindable var dataStore: LegacyDataStore
    /// 刷题页的工作状态归根视图所有，见 `LeetCodeCodingSession`：
    /// 放在这里的 @State 会在切到对话页时随页面一起销毁，代码就没了。
    @Bindable var session: LeetCodeCodingSession
    @State private var debouncedSearchText = ""
    @State private var filteredQuestionsCache: [LeetCodeQuestion] = []
    @State private var activityLayout = LeetCodeActivityCalendar.Layout.empty
    @State private var activityInsight = LeetCodeActivityInsight.empty
    @GestureState private var bottomPanelDragTranslation: CGFloat = 0
    /// 结果区里内容的实际高度（样例输入 + 判题结果），用来在出结果时自动撑开。
    @State private var resultContentHeight: CGFloat = 0
    @State private var workspaceLoadingSlug: String?
    @State private var workspaceError: String?
    @State private var submissionDetailLoadingIDs: Set<String> = []
    @State private var submissionDetailErrors: [String: String] = [:]
    @State private var historyLoadingSlug: String?
    @State private var historyErrors: [String: String] = [:]
    @State private var editorLoadStatus = LeetCodeEditorLoadStatus.loading
    @State private var completionStatus = LeetCodeCompletionStatus.localOnly
    @State private var questionMeta = LeetCodeQuestionMeta.empty
    @State private var showsSolutions = false
    @State private var editorReloadRequest = 0
    @State private var editorFormatRequest = 0
    @State private var editorUndoRequest = 0
    @State private var editorRedoRequest = 0

    private var selectedQuestion: LeetCodeQuestion? {
        dataStore.leetCodeQuestions.first { $0.titleSlug == session.selectedQuestionSlug }
            ?? selectedSubmission.flatMap { submission in
                question(for: submission.titleSlug)
            }
    }

    private var selectedSubmission: LeetCodeSubmission? {
        dataStore.leetCodeSubmissions.first { $0.id == session.selectedSubmissionID }
    }

    private var selectedWorkspace: LeetCodeQuestionWorkspace? {
        session.selectedQuestionSlug.flatMap { dataStore.leetCodeWorkspaces[$0] }
    }

    private var filteredQuestions: [LeetCodeQuestion] {
        filteredQuestionsCache
    }

    private var currentTestCases: [String] {
        guard let slug = session.selectedQuestionSlug else { return [""] }
        return session.testCases(for: slug, official: selectedWorkspace?.sampleTestCases ?? [])
    }

    private var judge: (action: LeetCodeJudgeAction?, progress: LeetCodeJudgeProgress?, result: LeetCodeJudgeResult?, error: String?) {
        session.judgeState(for: session.selectedQuestionSlug)
    }

    var body: some View {
        Group {
            if selectedQuestion == nil {
                overview
                    .workspaceHeader(id: "leetcode.overview", hidesTitle: false) {
                        overviewHeaderLeading
                    } trailing: {
                        overviewHeaderTrailing
                    }
            } else {
                questionWorkspace
                    .workspaceHeader(id: "leetcode.question") {
                        questionHeaderLeading
                    } trailing: {
                        questionHeaderTrailing
                    }
            }
        }
        .overlay(alignment: .top) { Divider() }
        .background(AppDesign.ColorToken.canvas)
        .onAppear {
            session.attach(dataDirectory: dataStore.dataDirectory)
            rebuildQuestionFilterCache()
            rebuildActivityBoardCache()
        }
        .task(id: session.searchText) {
            try? await Task.sleep(for: .milliseconds(220))
            guard !Task.isCancelled else { return }
            debouncedSearchText = session.searchText.trimmingCharacters(in: .whitespacesAndNewlines)
            rebuildQuestionFilterCache()
        }
        .onChange(of: session.statusFilter) { _, _ in rebuildQuestionFilterCache() }
        .onChange(of: session.difficultyFilter) { _, _ in rebuildQuestionFilterCache() }
        .onChange(of: dataStore.leetCodeQuestions) { _, _ in
            rebuildQuestionFilterCache()
            rebuildActivityBoardCache()
        }
        .onChange(of: dataStore.leetCodeActivity) { _, _ in rebuildActivityBoardCache() }
        .onChange(of: dataStore.activeLeetCodePlanID) { _, _ in rebuildActivityBoardCache() }
        // 工具卡片里的「去做这道题」落在这里。取用后清空，
        // 否则用户在页内换了题、再切回来又会被拽回去。
        .task(id: workspace.pendingLeetCodeSlug) {
            guard let slug = workspace.pendingLeetCodeSlug, !slug.isEmpty else { return }
            session.openQuestion(slug)
            workspace.pendingLeetCodeSlug = nil
        }
        .task(id: session.selectedQuestionSlug) {
            guard let slug = session.selectedQuestionSlug else { return }
            await ensureWorkspace(slug)
        }
        .task(id: session.selectedQuestionSlug) {
            guard let slug = session.selectedQuestionSlug else { return }
            await ensureQuestionHistory(slug)
        }
        .task(id: session.selectedSubmissionID) {
            guard let id = session.selectedSubmissionID else { return }
            await ensureSubmissionDetail(id)
        }
        // 分析队列的 worker 已移到 RootWorkspaceView：它挂在这里时，
        // 离开刷题页就会取消任务、把取消当失败计数，最终把队列删空。
    }

    // MARK: - 列头

    /// 题库总览：分区切换 + 题单，紧跟在「刷题」标题后面。
    private var overviewHeaderLeading: some View {
        HStack(spacing: AppDesign.Spacing.xs) {
            GlassSegmentedControl(
                options: LeetCodeOverviewSection.allCases.map { ($0.rawValue, $0.title) },
                selection: Binding(
                    get: { session.overviewSection.rawValue },
                    set: { session.overviewSection = LeetCodeOverviewSection(rawValue: $0) ?? session.overviewSection }
                )
            )
            .frame(width: AppDesign.Size.scaledControl(210))

            if session.overviewSection == .library, !dataStore.leetCodePlans.isEmpty {
                Menu {
                    ForEach(dataStore.leetCodePlans) { plan in
                        Button {
                            try? dataStore.selectLeetCodePlan(plan.id)
                            session.closeQuestion()
                        } label: {
                            if plan.id == dataStore.activeLeetCodePlanID {
                                Label(plan.name, systemImage: "checkmark")
                            } else {
                                Text(plan.name)
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 5) {
                        Text(activePlanName)
                            .font(AppDesign.Typography.auxEmphasis)
                            .lineLimit(1)
                        Image(systemName: "chevron.down")
                            .font(.appScaled(size: 9, weight: .semibold))
                            .foregroundStyle(.secondary)
                    }
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                // borderlessButton 的 Menu 不理会 label 尺寸，不钉死宽高会把列头整行吃掉。
                .frame(width: AppDesign.Size.scaledControl(150), height: AppDesign.Size.toolbarControl)
                .help("切换题单")
            }
        }
    }

    private var overviewHeaderTrailing: some View {
        HStack(spacing: AppDesign.Spacing.xxs) {
            if session.overviewSection == .library {
                HStack(spacing: 5) {
                    Image(systemName: "magnifyingglass")
                        .font(AppDesign.Typography.micro)
                        .foregroundStyle(.tertiary)
                    TextField("搜索题号、题目或标签", text: $session.searchText)
                        .textFieldStyle(.plain)
                        .font(AppDesign.Typography.aux)
                }
                .padding(.horizontal, 9)
                .frame(width: AppDesign.Size.scaledControl(200), height: AppDesign.Size.toolbarControl - 2)
                .background(AppDesign.ColorToken.inlineFill, in: Capsule())
            }
            HeaderIconButton(systemName: "arrow.clockwise", help: "重新读取同步数据") {
                dataStore.reload()
            }
        }
    }

    /// 打开题目后：返回 · 题号标题难度 · 上下题，全在一行里。
    private var questionHeaderLeading: some View {
        HStack(spacing: AppDesign.Spacing.xxs) {
            HeaderIconButton(systemName: "square.grid.2x2", help: "返回题库") {
                session.closeQuestion()
            }
            if let question = selectedQuestion {
                Text("\(question.frontendID). \(question.title)")
                    .font(AppDesign.Typography.rowTitleEmphasis)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .layoutPriority(-1)
                    .padding(.leading, 2)
                if !difficultyTitle(question.difficulty).isEmpty {
                    Text(difficultyTitle(question.difficulty))
                        .font(AppDesign.Typography.micro.weight(.semibold))
                        .foregroundStyle(difficultyColor(question.difficulty))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(difficultyColor(question.difficulty).opacity(0.12), in: Capsule())
                        .fixedSize()
                }
                if !session.isPristine, session.documentID.hasPrefix(question.titleSlug + "|") {
                    Circle()
                        .fill(Color.secondary.opacity(0.6))
                        .frame(width: 5, height: 5)
                        .help("有未提交的草稿（已自动保存）")
                }
            }
            // 上/下一题跟着标题走。只在「作答」下出现：看提交记录时连着翻题没有意义。
            if session.isSolving, let position = problemPosition, position.total > 1 {
                LeetCodeProblemNavBar(position: position) { slug in
                    session.selectedQuestionSlug = slug
                    session.selectedSubmissionID = nil
                }
                .fixedSize()
            }
        }
    }

    private var questionHeaderTrailing: some View {
        HStack(spacing: AppDesign.Spacing.xs) {
            GlassSegmentedControl(
                options: [("view", "题目与提交"), ("solve", "作答")],
                selection: Binding(
                    get: { session.isSolving ? "solve" : "view" },
                    set: { session.isSolving = $0 == "solve" }
                )
            )
            .frame(width: AppDesign.Size.scaledControl(176))

            HeaderPillButton(
                title: "问 AI",
                systemImage: "sparkles",
                isSelected: session.isAssistantPresented,
                help: "在这道题里问 AI，自动附带题面、当前代码与评测结果（⌘L）"
            ) {
                toggleAssistant()
            }
            .keyboardShortcut("l", modifiers: .command)
        }
    }

    @ViewBuilder
    private var overview: some View {
        switch session.overviewSection {
        case .library: libraryView
        case .activity: activityView
        case .submissions: submissionsView
        }
    }

    private var libraryView: some View {
        VStack(spacing: 0) {
            summaryStrip
            Divider()
            HStack(spacing: 10) {
                GlassSegmentedControl(
                    options: LeetCodeStatusFilter.allCases.map { ($0.rawValue, $0.title) },
                    selection: Binding(
                        get: { session.statusFilter.rawValue },
                        set: { session.statusFilter = LeetCodeStatusFilter(rawValue: $0) ?? session.statusFilter }
                    )
                )
                .frame(maxWidth: 218)

                GlassSegmentedControl(
                    options: LeetCodeDifficultyFilter.allCases.map { ($0.rawValue, $0.title) },
                    selection: Binding(
                        get: { session.difficultyFilter.rawValue },
                        set: { session.difficultyFilter = LeetCodeDifficultyFilter(rawValue: $0) ?? session.difficultyFilter }
                    )
                )
                .frame(maxWidth: 232)
                Spacer()
                Text("\(filteredQuestions.count) 道题")
                    .font(AppDesign.Typography.micro.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 16)
            .frame(height: 44)
            Divider()

            if filteredQuestions.isEmpty {
                ContentUnavailableView("没有符合条件的题目", systemImage: "magnifyingglass")
            } else {
                ScrollView {
                    LazyVStack(spacing: AppDesign.Spacing.section) {
                        ForEach(questionGroups) { group in
                            questionGroupCard(group)
                        }
                    }
                    .padding(.horizontal, AppDesign.Spacing.xs)
                    .padding(.vertical, AppDesign.Spacing.lg)
                    .frame(maxWidth: AppDesign.Size.dashboardColumnMaximum)
                    .frame(maxWidth: .infinity)
                }
                .floatingScrollIndicators()
            }
        }
    }

    private var summaryStrip: some View {
        HStack(spacing: 0) {
            metric("题目", dataStore.leetCodeQuestions.count, color: .primary)
            metric("已通过", dataStore.leetCodeQuestions.lazy.filter { $0.status == "SOLVED" }.count, color: .green)
            metric("尝试过", dataStore.leetCodeQuestions.lazy.filter { $0.status == "TRIED" }.count, color: .orange)
            metric("提交", dataStore.leetCodeSubmissions.count, color: .blue)
            metric("连续", dataStore.currentLeetCodeStreak, suffix: " 天", color: .pink)
        }
        .frame(height: 68)
    }

    private func metric(_ title: String, _ value: Int, suffix: String = "", color: Color) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("\(value)\(suffix)")
                    .font(.appScaled(size: 19, weight: .semibold).monospacedDigit())
                    .foregroundStyle(color)
                Text(title).font(AppDesign.Typography.micro).foregroundStyle(.secondary)
            }
            Spacer()
            Divider().frame(height: 28)
        }
        .padding(.leading, 18)
        .frame(maxWidth: .infinity)
    }

    /// 题单按专题分组显示（对齐 Electron 旧版：`groupName` 分组，组头带"已通过/总数"）。
    /// 热题 100 这种自带专题的题单，平铺一长条根本看不出结构。
    private var questionGroups: [LeetCodeQuestionGroup] {
        var order: [String] = []
        var buckets: [String: [LeetCodeQuestion]] = [:]
        for question in filteredQuestions {
            let name = question.groupName.isEmpty ? "未分类" : question.groupName
            if buckets[name] == nil {
                buckets[name] = []
                order.append(name)
            }
            buckets[name]?.append(question)
        }
        return order.map { name in
            LeetCodeQuestionGroup(name: name, questions: buckets[name] ?? [])
        }
    }

    private func questionGroupCard(_ group: LeetCodeQuestionGroup) -> some View {
        // 专题是一段带小标题的列表，不再是一张描边卡：标题行不铺底，行与行之间发丝线。
        VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text(group.name)
                    .font(AppDesign.Typography.headline)
                Text("\(group.solvedCount) / \(group.questions.count)")
                    .font(AppDesign.Typography.micro.monospacedDigit())
                    .foregroundStyle(.tertiary)
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 4)
            .frame(maxWidth: .infinity)

            ForEach(Array(group.questions.enumerated()), id: \.element.id) { index, question in
                if index > 0 {
                    Hairline().padding(.leading, 48)
                }
                questionRow(question)
            }
        }
    }

    private func questionRow(_ question: LeetCodeQuestion) -> some View {
        Button {
            openQuestion(question.titleSlug)
        } label: {
            HStack(spacing: 12) {
                Image(systemName: question.status == "SOLVED" ? "checkmark.circle.fill" : question.status == "TRIED" ? "circle.dashed" : "circle")
                    .foregroundStyle(statusColor(question.status))
                    .frame(width: 20)
                Text(question.frontendID)
                    .font(.appScaled(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .frame(width: 44, alignment: .trailing)
                VStack(alignment: .leading, spacing: 3) {
                    Text(question.title).font(.appScaled(size: 14, weight: .medium)).lineLimit(1)
                    Text(([question.groupName] + question.topicTags.prefix(3)).filter { !$0.isEmpty }.joined(separator: " · "))
                        .font(AppDesign.Typography.micro).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 8)
                if question.submissionCount > 0 {
                    Text("\(question.submissionCount) 次")
                        .font(AppDesign.Typography.micro.monospacedDigit()).foregroundStyle(.secondary)
                }
                Text(difficultyTitle(question.difficulty))
                    .font(AppDesign.Typography.micro.weight(.medium))
                    .foregroundStyle(difficultyColor(question.difficulty))
                    .frame(width: 40)
                Image(systemName: "chevron.right")
                    .font(AppDesign.Typography.micro.weight(.semibold)).foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 16)
            .frame(height: 54)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var activityView: some View {
        // 一张画布从上往下读：档案 / 指标带 / 热力图与周节奏 / 分布 / 题单与最近提交。
        // 区块之间一条发丝线，不再是七张玻璃卡铺在渐变底上。
        ScrollView {
            VStack(alignment: .leading, spacing: AppDesign.Spacing.lg) {
                profileHeader
                LeetCodeActivityMetricsRow(
                    layout: activityLayout,
                    insight: activityInsight,
                    dueCount: dataStore.dueCount,
                    weakCount: dataStore.weakCount
                )
                Hairline()
                HStack(alignment: .top, spacing: AppDesign.Spacing.xl) {
                    LeetCodeActivityHeatmapCard(layout: activityLayout)
                    LeetCodeActivityWeekRhythm(layout: activityLayout)
                        .frame(width: AppDesign.Size.scaledControl(250))
                }
                Hairline()
                LeetCodeActivityBreakdown(insight: activityInsight)
                Hairline()
                HStack(alignment: .top, spacing: AppDesign.Spacing.xl) {
                    planProgress
                    recentActivity
                }
            }
            .padding(.horizontal, AppDesign.Spacing.xl)
            .padding(.vertical, AppDesign.Spacing.lg)
            .frame(maxWidth: AppDesign.Size.dashboardColumnMaximum)
            .frame(maxWidth: .infinity)
        }
        .floatingScrollIndicators()
        .background(AppDesign.ColorToken.canvas)
    }

    private var profileHeader: some View {
        HStack(spacing: 14) {
            profileAvatar
            VStack(alignment: .leading, spacing: 3) {
                Text(dataStore.leetCodeProfile.displayName.isEmpty ? "LeetCode 学习档案" : dataStore.leetCodeProfile.displayName)
                    .font(AppDesign.Typography.pageTitle)
                Text(
                    dataStore.leetCodeProfile.username.isEmpty
                        ? "刷题节奏与能力分布"
                        : "@\(dataStore.leetCodeProfile.username) · 刷题节奏与能力分布"
                )
                .font(AppDesign.Typography.aux)
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            HStack(spacing: 6) {
                Circle()
                    .fill(dataStore.leetCodeSignedIn ? Color.green : Color.secondary.opacity(0.6))
                    .frame(width: 6, height: 6)
                Text(dataStore.leetCodeSignedIn ? "已连接" : "未连接")
                    .font(AppDesign.Typography.auxEmphasis)
                    .foregroundStyle(dataStore.leetCodeSignedIn ? .green : .secondary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(AppDesign.ColorToken.inlineFill, in: Capsule())
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var profileAvatar: some View {
        if let data = dataStore.leetCodeProfile.avatarData, let image = NSImage(data: data) {
            Image(nsImage: image).resizable().scaledToFill()
                .frame(width: 54, height: 54).clipShape(RoundedRectangle(cornerRadius: 10))
        } else {
            Image(systemName: "person.crop.square").font(.appScaled(size: 34)).foregroundStyle(.secondary)
                .frame(width: 54, height: 54)
        }
    }

    private var planProgress: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("题单进度")
                .font(AppDesign.Typography.rowTitleEmphasis)
            if dataStore.leetCodePlans.isEmpty {
                Text("导入题单后显示进度")
                    .font(AppDesign.Typography.aux)
                    .foregroundStyle(.secondary)
            }
            ForEach(dataStore.leetCodePlans) { plan in
                Button {
                    try? dataStore.selectLeetCodePlan(plan.id)
                    session.overviewSection = .library
                } label: {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text(plan.name).font(AppDesign.Typography.aux).lineLimit(1)
                            Spacer()
                            Text("\(plan.solvedCount)/\(plan.questionCount)")
                                .font(AppDesign.Typography.micro.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                        ProgressView(value: Double(plan.solvedCount), total: Double(max(1, plan.questionCount)))
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var recentActivity: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("最近提交")
                .font(AppDesign.Typography.rowTitleEmphasis)
            if dataStore.leetCodeSubmissions.isEmpty {
                Text("同步后显示最近的提交记录")
                    .font(AppDesign.Typography.aux)
                    .foregroundStyle(.secondary)
            }
            ForEach(dataStore.leetCodeSubmissions.suffix(7).reversed()) { submission in
                submissionButton(submission, compact: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var submissionsView: some View {
        VStack(spacing: 0) {
            HStack {
                Text("提交记录").font(AppDesign.Typography.headline)
                Text("\(dataStore.leetCodeSubmissions.count) 条").font(AppDesign.Typography.micro.monospacedDigit()).foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.horizontal, 16).frame(height: 46)
            Divider()
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(dataStore.leetCodeSubmissions.reversed()) { submission in
                        submissionButton(submission, compact: false)
                        Divider().padding(.leading, 42)
                    }
                }
            }
            .floatingScrollIndicators()
        }
    }

    private func submissionButton(_ submission: LeetCodeSubmission, compact: Bool) -> some View {
        Button {
            session.selectedSubmissionID = submission.id
            openQuestion(submission.titleSlug)
        } label: {
            HStack(spacing: 10) {
                Circle().fill(submission.accepted ? Color.green : Color.orange).frame(width: 7, height: 7)
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(submission.frontendID). \(submission.title)")
                        .font(.appScaled(size: compact ? 13.5 : 14, weight: .medium)).lineLimit(1)
                    Text([submission.status.isEmpty ? (submission.accepted ? "通过" : "未通过") : submission.status,
                          submission.language.uppercased(), submission.runtime, submission.memory,
                          submission.submittedAt.formatted(date: .abbreviated, time: .shortened)]
                        .filter { !$0.isEmpty }.joined(separator: " · "))
                        .font(AppDesign.Typography.micro).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                if !compact { Image(systemName: "chevron.right").font(AppDesign.Typography.micro).foregroundStyle(.tertiary) }
            }
            .padding(.vertical, compact ? 3 : 0)
            .padding(.horizontal, compact ? 0 : 16)
            .frame(minHeight: compact ? 38 : 54)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// 上一题 / 下一题在**当前筛选后的列表**里走，和左侧看到的顺序一致。
    private var problemPosition: LeetCodeProblemNavigator.Position? {
        LeetCodeProblemNavigator.position(
            of: session.selectedQuestionSlug,
            in: filteredQuestions.map(\.titleSlug)
        )
    }

    private var questionWorkspace: some View {
        // 不用 HSplitView：它是 NSSplitView，三列开合时列宽在补间，
        // 它会逐帧重新分配窗格、里面的 WKWebView 每帧重排，画面上窗格互相错位。
        ProportionalSplit(
            storageKey: "native.leetcode.problemFraction",
            minLeading: 360,
            minTrailing: 380
        ) {
            Group {
                if let workspace = selectedWorkspace, !workspace.htmlContent.isEmpty {
                    LeetCodeProblemWebView(html: workspace.htmlContent)
                } else if workspaceLoadingSlug == session.selectedQuestionSlug {
                    ProgressView("正在从力扣读取题目…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let workspaceError {
                    VStack(spacing: 12) {
                        ContentUnavailableView("题目加载失败", systemImage: "exclamationmark.triangle", description: Text(workspaceError))
                        Button {
                            guard let slug = session.selectedQuestionSlug else { return }
                            Task { await ensureWorkspace(slug, force: true) }
                        } label: {
                            Label("重新加载", systemImage: "arrow.clockwise")
                                .font(.appScaled(size: 12.5, weight: .medium))
                                .foregroundStyle(Color.accentColor)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 5)
                                .contentShape(Capsule())
                        }
                        .buttonStyle(.plain)
                        .quietCapsule()
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ContentUnavailableView(
                        "正在准备题目",
                        systemImage: "doc.text.magnifyingglass",
                        description: Text("题面、代码片段和官方样例会自动从力扣读取。")
                    )
                }
            }
            // 两条都是**浮层**，不参与分栏布局——力扣官网那条也是浮在题面窗格底部的胶囊。
            // 之前以为要把这一栏拆成上下结构才能加，是我想复杂了：题面照旧铺满，浮层压在它上面。
            .overlay(alignment: .bottom) { problemActionOverlay }
            .task(id: session.selectedQuestionSlug) { await loadQuestionMeta() }
            .sheet(isPresented: $showsSolutions) {
                if let slug = session.selectedQuestionSlug {
                    LeetCodeSolutionsBrowser(
                        titleSlug: slug,
                        title: selectedQuestion?.title ?? "题解",
                        onOpenURL: { url in
                            workspace.openURL(url)
                        }
                    )
                }
            }

        } trailing: {
            Group {
                if session.isSolving { editorPane } else { submissionDetailPane }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // AI 助手是一扇浮窗，不再开一列或一个标签页：默认停在题面那一栏上，
        // 按住标题栏可以拖到任意位置、右下角可以拉大小（位置会记住）。
        // 关掉浮窗题面原样还在，滚动位置也不丢。
        .overlay { assistantOverlay }
    }

    @ViewBuilder
    private var assistantOverlay: some View {
        // 不要求题面已经加载：没登录、网络失败时题面读不到，
        // 以前这里 `let questionWorkspace = selectedWorkspace` 守卫不过，点「问 AI」毫无反应。
        if session.isAssistantPresented, let question = selectedQuestion {
            FloatingPanelHost(storageKey: "native.leetcode.assistantPlacement") { moveGesture in
                LeetCodeAssistantCard(
                    workspace: workspace,
                    dataStore: dataStore,
                    session: session,
                    question: question,
                    questionWorkspace: selectedWorkspace,
                    difficultyTitle: difficultyTitle(question.difficulty),
                    moveGesture: moveGesture
                )
            }
            .transition(.opacity.combined(with: .scale(scale: 0.98)))
        }
    }

    private func toggleAssistant() {
        withAnimation(AppDesign.Motion.selection) {
            session.isAssistantPresented.toggle()
        }
    }

    @ViewBuilder
    private var problemActionOverlay: some View {
        if let slug = session.selectedQuestionSlug, selectedWorkspace != nil {
            LeetCodeQuestionActionBar(
                meta: questionMeta,
                titleSlug: slug,
                dataDirectory: dataStore.dataDirectory,
                onOpenSolutions: { showsSolutions = true },
                onOpenInBrowser: { url in
                    workspace.openURL(url)
                }
            )
            .padding(.horizontal, AppDesign.Spacing.compact)
            .padding(.bottom, AppDesign.Spacing.compact)
        }
    }

    private func loadQuestionMeta() async {
        guard let slug = session.selectedQuestionSlug else {
            questionMeta = .empty
            return
        }
        // 换题时先清空：否则新题面配着上一题的点赞数，看着像数据错了。
        questionMeta = .empty
        guard let meta = try? await LeetCodeAPIClient.shared.fetchQuestionMeta(titleSlug: slug) else { return }
        guard session.selectedQuestionSlug == slug else { return }
        questionMeta = meta
    }

    private var submissionDetailPane: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                if let question = selectedQuestion {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("提交记录").font(AppDesign.Typography.headline)
                                Text("\(question.submissionCount) 次提交 · \(question.acceptedCount) 次通过")
                                    .font(AppDesign.Typography.micro).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if historyLoadingSlug == question.titleSlug {
                                ProgressView().controlSize(.small).help("正在同步该题完整提交历史")
                            } else {
                                Button {
                                    Task { await ensureQuestionHistory(question.titleSlug, force: true) }
                                } label: { Image(systemName: "arrow.clockwise") }
                                    .buttonStyle(.plain).help("同步该题提交历史")
                            }
                        }
                        if let error = historyErrors[question.titleSlug] {
                            Text(error).font(AppDesign.Typography.micro).foregroundStyle(.orange)
                        }
                    }
                    .padding(18)
                    trajectoryAnalysisPanel(question)
                }
                Divider()
                let submissions = dataStore.leetCodeSubmissions.filter { $0.titleSlug == selectedQuestion?.titleSlug }.reversed()
                if submissions.isEmpty {
                    ContentUnavailableView("暂无提交记录", systemImage: "clock.arrow.circlepath")
                        .frame(maxWidth: .infinity).padding(.top, 80)
                } else {
                    ForEach(submissions) { submission in
                        submissionDisclosure(submission)
                        Divider().padding(.leading, 34)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .floatingScrollIndicators()
    }

    private func submissionDisclosure(_ submission: LeetCodeSubmission) -> some View {
        let expanded = session.selectedSubmissionID == submission.id
        let insight = dataStore.leetCodeAnalyses[submission.titleSlug]?.attemptInsights.first { $0.submissionID == submission.id }
        return VStack(spacing: 0) {
            Button {
                session.selectedSubmissionID = expanded ? nil : submission.id
            } label: {
                HStack(spacing: 10) {
                    Circle().fill(submission.accepted ? Color.green : Color.orange).frame(width: 7, height: 7)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(submission.status.isEmpty ? (submission.accepted ? "通过" : "未通过") : submission.status)
                            .font(AppDesign.Typography.aux.weight(.medium))
                        Text([submission.language.uppercased(), submission.runtime, submission.memory, submission.submittedAt.formatted(date: .abbreviated, time: .shortened)]
                            .filter { !$0.isEmpty }.joined(separator: " · "))
                            .font(AppDesign.Typography.micro).foregroundStyle(.secondary)
                        if let insight, !insight.issue.isEmpty {
                            Text(insight.issue).font(AppDesign.Typography.micro).foregroundStyle(.secondary).lineLimit(2)
                        }
                    }
                    Spacer()
                    Image(systemName: "chevron.down").font(AppDesign.Typography.micro.weight(.semibold)).foregroundStyle(.secondary)
                        .rotationEffect(.degrees(expanded ? 180 : 0))
                }
                .padding(.horizontal, 16).frame(height: 54).contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if expanded {
                Group {
                    if let detail = dataStore.leetCodeSubmissionDetails[submission.id] {
                        submissionDetail(detail, analysis: dataStore.leetCodeAnalyses[submission.titleSlug]?.submissionAnalyses[submission.id])
                    } else if submissionDetailLoadingIDs.contains(submission.id) {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("正在读取源码与失败用例")
                                .font(AppDesign.Typography.micro).foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(14)
                    } else if let error = submissionDetailErrors[submission.id] {
                        HStack(spacing: 10) {
                            Text(error).font(AppDesign.Typography.micro).foregroundStyle(.secondary)
                            Spacer()
                            Button("重试", systemImage: "arrow.clockwise") {
                                Task { await ensureSubmissionDetail(submission.id, force: true) }
                            }
                            .controlSize(.small)
                        }
                        .padding(12)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16).padding(.bottom, 18)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func submissionDetail(_ detail: LeetCodeSubmissionDetail, analysis: LeetCodeSubmissionAnalysis?) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 24) {
                detailMetric("样例", detail.totalCaseCount > 0 ? "\(detail.correctCaseCount)/\(detail.totalCaseCount)" : "-")
                detailMetric("运行", detail.runtime.isEmpty ? "-" : detail.runtime)
                detailMetric("内存", detail.memory.isEmpty ? "-" : detail.memory)
                Spacer()
            }
            diagnostics(detail, language: detail.language)
            if let analysis {
                Divider()
                VStack(alignment: .leading, spacing: 8) {
                    Label("AI 分析", systemImage: "sparkles")
                        .font(AppDesign.Typography.micro.weight(.semibold))
                        .foregroundStyle(.blue)
                    Text(analysis.rootCause.isEmpty ? analysis.summary : analysis.rootCause)
                        .font(AppDesign.Typography.aux)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if !analysis.suggestions.isEmpty {
                        VStack(alignment: .leading, spacing: 5) {
                            Text("建议").font(AppDesign.Typography.micro.weight(.semibold)).foregroundStyle(.secondary)
                            ForEach(analysis.suggestions, id: \.self) { item in
                                Label(item, systemImage: "arrow.turn.down.right")
                                    .font(AppDesign.Typography.micro)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            if !detail.code.isEmpty {
                SyntaxHighlightedCodeView(
                    code: detail.code,
                    language: detail.language,
                    maxHeight: 420
                )
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func trajectoryAnalysisPanel(_ question: LeetCodeQuestion) -> some View {
        let analysis = dataStore.leetCodeAnalyses[question.titleSlug]
        let task = dataStore.leetCodeAnalysisTasks[question.titleSlug]
        if analysis != nil || task != nil {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    Label("提交轨迹", systemImage: "point.3.connected.trianglepath.dotted")
                        .font(AppDesign.Typography.aux.weight(.semibold))
                    Spacer()
                    if dataStore.leetCodeAnalysisProcessingSlug == question.titleSlug {
                        ProgressView().controlSize(.small)
                        Text("AI 正在分析").font(AppDesign.Typography.micro).foregroundStyle(.secondary)
                    } else if let task {
                        Text("\(task.submissionIDs.count) 条待分析").font(AppDesign.Typography.micro).foregroundStyle(.secondary)
                    } else if let analysis, analysis.updatedAt != .distantPast {
                        Text(analysis.updatedAt.formatted(.relative(presentation: .named)))
                            .font(AppDesign.Typography.micro).foregroundStyle(.secondary)
                    }
                }
                if let task, !task.lastError.isEmpty {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
                        Text("上次分析失败：\(task.lastError)。将自动重试。")
                            .font(AppDesign.Typography.micro).foregroundStyle(.secondary)
                        Spacer()
                        Button("立即重试") {
                            try? dataStore.retryLeetCodeAnalysis(question.titleSlug)
                        }
                        .controlSize(.small)
                    }
                }
                if let analysis {
                    if !analysis.summary.isEmpty {
                        Text(analysis.summary).font(AppDesign.Typography.aux).fixedSize(horizontal: false, vertical: true)
                    }
                    HStack(alignment: .top, spacing: 20) {
                        analysisList("待巩固", values: analysis.weaknesses, color: .orange)
                        analysisList("下一步", values: analysis.improvements, color: .blue)
                    }
                } else {
                    Text(task?.lastError.isEmpty == false ? "分析失败，等待重试" : "已进入分析队列")
                        .font(AppDesign.Typography.micro).foregroundStyle(.secondary)
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.primary.opacity(0.025))
            Divider()
        }
    }

    private func analysisList(_ title: String, values: [String], color: Color) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(AppDesign.Typography.micro.weight(.semibold)).foregroundStyle(color)
            if values.isEmpty {
                Text("暂无").font(AppDesign.Typography.micro).foregroundStyle(.tertiary)
            } else {
                ForEach(values, id: \.self) { value in
                    HStack(alignment: .top, spacing: 6) {
                        Circle().fill(color).frame(width: 4, height: 4).padding(.top, 6)
                        Text(value).font(AppDesign.Typography.micro).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func diagnostics(_ detail: LeetCodeSubmissionDetail, language: String) -> some View {
        let values = [
            ("编译信息", detail.compileError, "text"),
            ("运行错误", detail.runtimeError, "text"),
            ("失败用例", detail.lastTestCase, language),
            ("实际输出", detail.actualOutput, language),
            ("预期输出", detail.expectedOutput, language)
        ].filter { !$0.1.isEmpty }
        ForEach(values, id: \.0) { label, value, blockLanguage in
            VStack(alignment: .leading, spacing: 4) {
                Text(label).font(AppDesign.Typography.micro.weight(.semibold)).foregroundStyle(.secondary)
                SyntaxHighlightedCodeView(code: value, language: blockLanguage)
            }
        }
    }

    private func detailMetric(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(AppDesign.Typography.aux.weight(.semibold).monospacedDigit())
            Text(title).font(AppDesign.Typography.micro).foregroundStyle(.secondary)
        }
    }

    private var editorPane: some View {
        GeometryReader { proxy in
            let slug = session.selectedQuestionSlug ?? ""
            let storedHeight = session.bottomPanelHeightsBySlug[slug] ?? LeetCodeBottomPanelLayout.defaultHeight
            let panelHeight = LeetCodeBottomPanelLayout.clampedHeight(
                storedHeight - bottomPanelDragTranslation,
                availableHeight: proxy.size.height
            )
            VStack(spacing: 0) {
                editorToolbar
                Divider()
                LeetCodeCodeEditor(
                    code: .constant(session.code),
                    language: session.language,
                    diagnostics: $session.diagnostics,
                    externalDiagnostics: session.judgeDiagnostics.issues,
                    loadStatus: $editorLoadStatus,
                    completionStatus: $completionStatus,
                    formatRequest: editorFormatRequest,
                    undoRequest: editorUndoRequest,
                    redoRequest: editorRedoRequest,
                    documentID: session.documentID,
                    onCodeChange: { value, documentID in
                        session.editorDidChange(value, documentID: documentID)
                    },
                    onSelectionChange: { selection in
                        if session.selection != selection { session.selection = selection }
                    },
                    suggestions: session.visibleSuggestions,
                    suggestionsRevision: session.reviewRevision,
                    acceptAllSuggestionsRequest: session.acceptAllRequest,
                    onSuggestionResolved: { id, _ in
                        session.resolveSuggestion(id: id)
                    }
                )
                .id(editorReloadRequest)
                .background(AppDesign.ColorToken.canvas)
                .overlay {
                    editorLoadOverlay
                }
                .overlay(alignment: .bottom) {
                    VStack(spacing: AppDesign.Spacing.xs) {
                        reviewBar
                        resetNotice
                    }
                }
                panelResizeHandle(slug: slug, availableHeight: proxy.size.height)
                testCasePanel(slug: slug)
                    .frame(height: panelHeight)
            }
            // 结果出来时把结果区撑到能看全（不超过可用高度的六成），不用手动去拖。
            // 只往大里撑：用户自己拖得更大的保留。
            .onChange(of: judgeLayoutSignature) { _, _ in
                growResultsPanelToFit(slug: slug, availableHeight: proxy.size.height)
            }
            .onChange(of: resultContentHeight) { _, _ in
                growResultsPanelToFit(slug: slug, availableHeight: proxy.size.height)
            }
        }
    }

    /// 判题状态每变一次（开始 / 进度 / 出结果 / 出错）签名就变。
    private var judgeLayoutSignature: String {
        let judge = judge
        return "\(judge.action != nil)|\(judge.result?.taskID ?? "")|\(judge.error ?? "")"
    }

    private func growResultsPanelToFit(slug: String, availableHeight: CGFloat) {
        let judge = judge
        guard judge.action != nil || judge.result != nil || judge.error != nil, resultContentHeight > 0 else { return }
        let current = session.bottomPanelHeightsBySlug[slug] ?? LeetCodeBottomPanelLayout.defaultHeight
        let wanted = LeetCodeBottomPanelLayout.heightToFit(content: resultContentHeight, availableHeight: availableHeight)
        guard wanted > current + 4 else { return }
        withAnimation(AppDesign.Motion.panel) {
            session.bottomPanelHeightsBySlug[slug] = wanted
        }
    }

    private func editorToolButton(
        _ systemName: String,
        help: String,
        disabled: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(AppDesign.Typography.iconCompact)
                .foregroundStyle(disabled ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.secondary))
                .frame(width: AppDesign.Size.iconSlot + 2, height: AppDesign.Size.iconSlot + 2)
                .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .help(help)
    }

    /// 编辑器工具条：语言 · 补全状态 ——— 撤销/重做 | 复制/格式化/重置。
    /// 「AI 提示」不再单独占一颗胶囊：并进列头的「问 AI」浮窗里（分级提示是浮窗的一种模式）。
    private var editorToolbar: some View {
        HStack(spacing: AppDesign.Spacing.compact) {
            Menu {
                ForEach(selectedWorkspace?.snippets ?? []) { snippet in
                    Button {
                        guard let questionWorkspace = selectedWorkspace else { return }
                        session.switchLanguage(to: snippet.languageSlug, workspace: questionWorkspace)
                    } label: {
                        let hasDraft = session.drafts.archive.questions[questionWorkspaceSlug]?.codes[snippet.languageSlug] != nil
                        Label(
                            hasDraft ? "\(snippet.language)（有草稿）" : snippet.language,
                            systemImage: snippet.languageSlug == session.language ? "checkmark" : "circle"
                        )
                    }
                }
            } label: {
                HStack(spacing: 6) {
                    Text(selectedWorkspace?.snippets.first { $0.languageSlug == session.language }?.language ?? session.language)
                        .font(AppDesign.Typography.auxEmphasis)
                        .lineLimit(1)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.appScaled(size: 9, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                .frame(width: AppDesign.Size.scaledControl(96))
                .padding(.vertical, 5)
                .contentShape(Capsule())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .quietCapsule()
            .help("切换语言。每种语言的代码分别保存，切回来还在")

            Label(completionStatus.title, systemImage: completionStatus.isOnline ? "bolt.horizontal.circle.fill" : "bolt.slash")
                .font(AppDesign.Typography.micro)
                .foregroundStyle(completionStatus.isOnline ? Color.green : Color.secondary)
                .lineLimit(1)
                .layoutPriority(-1)
                .help(completionStatus.detail)
            Spacer(minLength: AppDesign.Spacing.sm)
            reviewButton
            HStack(spacing: 4) {
                editorToolButton("arrow.uturn.backward", help: "撤销") { editorUndoRequest &+= 1 }
                editorToolButton("arrow.uturn.forward", help: "重做") { editorRedoRequest &+= 1 }
                Divider().frame(height: 14).padding(.horizontal, 2)
                editorToolButton("doc.on.doc", help: "复制代码") { copy(session.code) }
                editorToolButton("textformat", help: "安全格式化缩进") { editorFormatRequest &+= 1 }
                editorToolButton(
                    "arrow.counterclockwise",
                    help: session.isPristine ? "已经是力扣初始代码" : "重置为力扣初始代码（可撤销）",
                    disabled: session.isPristine
                ) {
                    withAnimation(AppDesign.Motion.selection) { session.resetToTemplate() }
                }
            }
            .padding(.horizontal, 5)
            .frame(height: AppDesign.Size.toolbarControl + 2)
            .quietCapsule()
        }
        .padding(.horizontal, AppDesign.Spacing.sm)
        .frame(height: AppDesign.Size.pageHeader - 2)
    }

    // MARK: - AI 就地标注

    /// 「AI 检查」：读当前代码和最近一次评测，把问题标到具体行上，下面给可接受的修改。
    private var reviewButton: some View {
        Button {
            startReview()
        } label: {
            HStack(spacing: 5) {
                if session.isReviewing {
                    ProgressView().controlSize(.mini).frame(width: 12, height: 12)
                } else {
                    Image(systemName: "sparkles")
                        .font(AppDesign.Typography.aux.weight(.semibold))
                }
                Text(session.isReviewing ? "检查中" : (session.visibleSuggestions.isEmpty ? "AI 检查" : "标注 \(session.visibleSuggestions.count)"))
                    .font(AppDesign.Typography.auxEmphasis)
            }
            .foregroundStyle(session.visibleSuggestions.isEmpty ? Color.primary : Color.accentColor)
            .padding(.horizontal, 10)
            .frame(height: AppDesign.Size.toolbarControl)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .quietCapsule()
        .disabled(session.isReviewing || session.isPristine)
        .help(session.isPristine ? "先写点代码再检查" : "AI 读当前代码和评测结果，把问题标到具体行上，给出可以一键接受的修改")
        .contextMenu {
            Toggle("没通过时自动标注（默认关，先自己想）", isOn: $session.autoReviewOnFailure)
            if !session.visibleSuggestions.isEmpty {
                Button("清除全部标注", systemImage: "xmark.circle") { session.clearReview() }
            }
        }
    }

    private func startReview() {
        guard let questionWorkspace = selectedWorkspace else { return }
        session.requestReview(.manual, question: selectedQuestion, workspace: questionWorkspace, dataStore: dataStore)
    }

    /// 编辑器底部一条：标注了几处、全部接受、清除；检查中 / 出错时也在这里说。
    @ViewBuilder
    private var reviewBar: some View {
        let count = session.visibleSuggestions.count
        if session.isReviewing || count > 0 || !session.reviewError.isEmpty {
            HStack(spacing: AppDesign.Spacing.xs) {
                if session.isReviewing {
                    ProgressView().controlSize(.small)
                    Text("AI 正在把问题标到代码上…")
                        .font(AppDesign.Typography.aux)
                } else if count > 0 {
                    Image(systemName: "sparkles")
                        .foregroundStyle(Color.accentColor)
                    Text("标注了 \(count) 处，下面是修改建议")
                        .font(AppDesign.Typography.aux)
                    Button("全部接受") { session.acceptAllSuggestions() }
                        .buttonStyle(.plain)
                        .font(AppDesign.Typography.auxEmphasis)
                        .foregroundStyle(Color.accentColor)
                    Button("清除") { session.clearReview() }
                        .buttonStyle(.plain)
                        .font(AppDesign.Typography.aux)
                        .foregroundStyle(.secondary)
                } else {
                    Image(systemName: "info.circle")
                        .foregroundStyle(.secondary)
                    Text(session.reviewError)
                        .font(AppDesign.Typography.aux)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Button {
                        session.clearReview()
                    } label: {
                        Image(systemName: "xmark").font(.appScaled(size: 9, weight: .bold))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 12)
            .frame(height: AppDesign.Size.toolbarControl + 4)
            .navigationGlass(cornerRadius: AppDesign.Radius.floating)
            .padding(.bottom, session.discardedCode == nil ? AppDesign.Spacing.sm : 0)
            .transition(.move(edge: .bottom).combined(with: .opacity))
            .animation(AppDesign.Motion.selection, value: count)
        }
    }

    private var questionWorkspaceSlug: String {
        session.selectedQuestionSlug ?? ""
    }

    /// 重置后浮在编辑器底部的一条：给「撤销」一个明显的入口，几秒后自己消失。
    /// 编辑器里 ⌘Z 同样能撤回，这里只是不让人去猜。
    @ViewBuilder
    private var resetNotice: some View {
        if let discarded = session.discardedCode, discarded.documentID == session.documentID {
            HStack(spacing: AppDesign.Spacing.xs) {
                Image(systemName: "arrow.counterclockwise.circle.fill")
                    .foregroundStyle(Color.accentColor)
                Text("已恢复为力扣初始代码")
                    .font(AppDesign.Typography.aux)
                Button("撤销") {
                    withAnimation(AppDesign.Motion.selection) { session.undoReset() }
                }
                .buttonStyle(.plain)
                .font(AppDesign.Typography.auxEmphasis)
                .foregroundStyle(Color.accentColor)
                Button {
                    withAnimation(AppDesign.Motion.fade) { session.dismissResetNotice() }
                } label: {
                    Image(systemName: "xmark")
                        .font(.appScaled(size: 9, weight: .bold))
                        .foregroundStyle(.secondary)
                        .frame(width: 18, height: 18)
                }
                .buttonStyle(.plain)
            }
            .padding(.leading, 12)
            .padding(.trailing, 6)
            .frame(height: AppDesign.Size.toolbarControl + 4)
            .navigationGlass(cornerRadius: AppDesign.Radius.floating)
            .padding(.bottom, AppDesign.Spacing.sm)
            .transition(.move(edge: .bottom).combined(with: .opacity))
            .task(id: session.resetNoticeVersion) {
                try? await Task.sleep(for: .seconds(8))
                guard !Task.isCancelled else { return }
                withAnimation(AppDesign.Motion.fade) { session.dismissResetNotice() }
            }
        }
    }

    @ViewBuilder
    private var editorLoadOverlay: some View {
        switch editorLoadStatus {
        case .loading:
            ProgressView("正在加载本地代码编辑器")
                .controlSize(.small)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(AppDesign.ColorToken.canvas.opacity(0.94))
        case .ready:
            EmptyView()
        case .failed(let message):
            VStack(spacing: 9) {
                Label("代码编辑器加载失败", systemImage: "exclamationmark.triangle")
                    .font(AppDesign.Typography.bodyEmphasis)
                Text(message).font(AppDesign.Typography.micro).foregroundStyle(.secondary).multilineTextAlignment(.center)
                Button("重新加载", systemImage: "arrow.clockwise") {
                    editorLoadStatus = .loading
                    editorReloadRequest &+= 1
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(AppDesign.ColorToken.canvas.opacity(0.97))
        }
    }

    private func panelResizeHandle(slug: String, availableHeight: CGFloat) -> some View {
        ZStack {
            Rectangle().fill(Color.primary.opacity(0.09)).frame(height: 1)
            Capsule().fill(Color.secondary.opacity(0.42)).frame(width: 34, height: 3)
        }
        .frame(height: 9)
        .contentShape(Rectangle())
        // 全局坐标：把手本身跟着拖动在移动，用局部坐标量位移会一帧顶一帧地抖。
        .gesture(
            DragGesture(minimumDistance: 1, coordinateSpace: .global)
                .updating($bottomPanelDragTranslation) { value, state, _ in
                    state = value.translation.height
                }
                .onEnded { value in
                    let current = session.bottomPanelHeightsBySlug[slug] ?? LeetCodeBottomPanelLayout.defaultHeight
                    session.bottomPanelHeightsBySlug[slug] = LeetCodeBottomPanelLayout.clampedHeight(
                        current - value.translation.height,
                        availableHeight: availableHeight
                    )
                }
        )
        .help("拖拽调整测试与运行结果区高度")
    }

    /// 测试与结果：样例标签 + 语法状态一行，下面是用例与结果；运行 / 提交浮在右下角。
    /// 原来是「标题行 + 标签行 + 内容 + 底栏」四层，底栏只为放两个按钮和一句固定说明。
    private func testCasePanel(slug: String) -> some View {
        let judge = judge
        return ZStack(alignment: .bottomTrailing) {
            VStack(spacing: 0) {
                HStack(spacing: AppDesign.Spacing.xs) {
                    testCaseTabs(slug: slug)
                    Spacer(minLength: AppDesign.Spacing.xs)
                    if session.editableTestCasesBySlug[slug].map({ $0 != LeetCodeTestCaseWorkspace.editableCases(from: selectedWorkspace?.sampleTestCases ?? []) }) == true {
                        Button("恢复样例") {
                            session.restoreOfficialTestCases(slug: slug, official: selectedWorkspace?.sampleTestCases ?? [])
                        }
                        .buttonStyle(.plain)
                        .font(AppDesign.Typography.micro)
                        .foregroundStyle(Color.accentColor)
                        .help("把改过的测试用例恢复成力扣官方样例")
                    }
                    Label(
                        session.combinedDiagnostics.statusText,
                        systemImage: session.combinedDiagnostics.issues.isEmpty ? "checkmark.circle" : "exclamationmark.triangle"
                    )
                    .font(AppDesign.Typography.micro)
                    .foregroundStyle(session.combinedDiagnostics.issues.isEmpty ? Color.secondary : Color.orange)
                    .lineLimit(1)
                    .layoutPriority(-1)
                    .help(session.combinedDiagnostics.issues.prefix(4).map { "第 \($0.line) 行：\($0.message)" }.joined(separator: "\n"))
                }
                .padding(.trailing, AppDesign.Spacing.sm)
                Divider()

                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        TextEditor(text: testCaseBinding(for: slug))
                            .font(AppDesign.Typography.mono)
                            .scrollContentBackground(.hidden)
                            .floatingTextScrollIndicators()
                            .padding(7)
                            .frame(minHeight: 64)
                            .background(Color.primary.opacity(0.035))
                            .overlay {
                                RoundedRectangle(cornerRadius: 5)
                                    .stroke(Color.primary.opacity(0.09), lineWidth: 1)
                            }
                        if judge.action != nil || judge.result != nil || judge.error != nil {
                            judgeResultPanel
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.top, 10)
                    // 给右下角浮着的运行 / 提交让出位置，最后一行结果不被压住。
                    .padding(.bottom, 56)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .onGeometryChange(for: CGFloat.self) { proxy in
                        (proxy.size.height / 8).rounded(.up) * 8
                    } action: { resultContentHeight = $0 }
                }
                .floatingScrollIndicators()
            }

            HStack(spacing: AppDesign.Spacing.xs) {
                judgeButton(
                    title: "运行",
                    systemImage: "play.fill",
                    tint: .primary,
                    disabled: judge.action != nil || selectedWorkspace?.canRun != true || session.code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ) {
                    startJudge(.run)
                }
                .keyboardShortcut("'", modifiers: .command)
                judgeButton(
                    title: "提交",
                    systemImage: "paperplane.fill",
                    tint: .accentColor,
                    disabled: judge.action != nil || selectedWorkspace?.canSubmit != true || session.code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ) {
                    startJudge(.submit)
                }
                .keyboardShortcut(.return, modifiers: [.command, .shift])
            }
            .padding(AppDesign.Spacing.sm)
        }
        .background(AppDesign.ColorToken.canvas)
    }

    private func judgeButton(
        title: String,
        systemImage: String,
        tint: Color,
        disabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(AppDesign.Typography.auxEmphasis)
                .foregroundStyle(tint)
                .padding(.horizontal, 12)
                .frame(height: AppDesign.Size.toolbarControl + 2)
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .glassCapsule()
        .opacity(disabled ? 0.45 : 1)
        .allowsHitTesting(!disabled)
        .help(title == "运行" ? "用当前样例运行（⌘'）" : "提交到力扣评测（⌘⇧↩）")
    }

    private func testCaseTabs(slug: String) -> some View {
        let cases = currentTestCases
        let selectedIndex = session.selectedTestCaseIndex(for: slug, caseCount: cases.count)
        return ScrollView(.horizontal) {
            HStack(spacing: 0) {
                ForEach(cases.indices, id: \.self) { index in
                    let selected = selectedIndex == index
                    Button {
                        session.selectedTestCaseIndexBySlug[slug] = index
                    } label: {
                        VStack(spacing: 5) {
                            Text("样例 \(index + 1)")
                                .font(AppDesign.Typography.micro.weight(selected ? .semibold : .regular))
                                .foregroundStyle(selected ? Color.primary : Color.secondary)
                                .lineLimit(1)
                            Rectangle()
                                .fill(selected ? Color.accentColor : Color.clear)
                                .frame(height: 2)
                        }
                        .padding(.horizontal, 12)
                        .frame(height: AppDesign.Size.compactRow)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .scrollIndicators(.never)
        .frame(height: AppDesign.Size.compactRow)
    }

    private var judgeResultPanel: some View {
        let judge = judge
        return VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 8) {
                if judge.action != nil {
                    ProgressView().controlSize(.small)
                    Text(judge.progress?.status ?? "正在连接力扣评测")
                        .font(AppDesign.Typography.bodyEmphasis)
                } else if let result = judge.result {
                    Image(systemName: result.accepted ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .foregroundStyle(result.accepted ? .green : .red)
                    Text(result.status).font(AppDesign.Typography.bodyEmphasis)
                    Spacer()
                    if result.totalTestCases > 0 {
                        Text("\(result.totalCorrect)/\(result.totalTestCases)")
                            .font(AppDesign.Typography.micro.monospacedDigit()).foregroundStyle(.secondary)
                    }
                    if !result.runtime.isEmpty { Text(result.runtime).font(AppDesign.Typography.micro).foregroundStyle(.secondary) }
                    if !result.memory.isEmpty { Text(result.memory).font(AppDesign.Typography.micro).foregroundStyle(.secondary) }
                } else if let judgeError = judge.error {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Text(judgeError).font(AppDesign.Typography.micro).foregroundStyle(.secondary)
                }
            }
            if let result = judge.result {
                let diagnostics = [
                    ("编译信息", result.compileError, "text"),
                    ("运行错误", result.runtimeError, "text"),
                    // 用例与输出按纯文本显示：给几万个数字着色没有阅读价值。
                    ("失败用例", result.input, "text"),
                    ("实际输出", result.output, "text"),
                    ("预期输出", result.expectedOutput, "text"),
                    // 运行样例时函数返回值在 code_answer、print 出来的在 code_output，分开显示（#3）。
                    ("控制台输出", result.stdOutput, "text")
                ].filter { !$0.1.isEmpty }
                ForEach(diagnostics, id: \.0) { label, value, language in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(label).font(AppDesign.Typography.micro.weight(.semibold)).foregroundStyle(.secondary)
                        SyntaxHighlightedCodeView(code: value, language: language, maxHeight: 220)
                    }
                }
                if !result.accepted {
                    failureActions
                }
                if !result.aiJudgeMessage.isEmpty {
                    Text(result.aiJudgeMessage).font(AppDesign.Typography.micro).foregroundStyle(.secondary)
                }
            }
        }
        .padding(11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(judge.result?.accepted == true ? Color.green.opacity(0.08) : Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 7))
    }

    /// 运行 / 提交没通过后固定给两条清晰路径：只要方向，或直接把问题标到具体行。
    ///
    /// `标到行上` 不能依赖 `hasHints`：提示状态会随换题、重载和清空发生变化，
    /// 旧条件导致同一个失败结果里按钮时有时无。聊天仍在编辑器顶部的「问 AI」入口，
    /// 结果区不重复放一个含义模糊的「问 AI」。
    @ViewBuilder
    private var failureActions: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("先自己对着失败用例走一遍；想不出来可以要方向，或标到具体行。")
                .font(AppDesign.Typography.micro)
                .foregroundStyle(.secondary)
            HStack(spacing: AppDesign.Spacing.xs) {
                failureAction("给个方向", systemImage: "lightbulb.max") {
                    requestDirection()
                }
                failureAction("标到行上", systemImage: "text.badge.checkmark", prominent: true) {
                    startReview()
                }
            }
        }
        .padding(.top, 2)
    }

    private func failureAction(
        _ title: String,
        systemImage: String,
        prominent: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(AppDesign.Typography.auxEmphasis)
                .foregroundStyle(prominent ? Color.accentColor : Color.secondary)
                .padding(.horizontal, 9)
                .frame(height: AppDesign.Size.toolbarControl - 4)
                .background(prominent ? Color.accentColor.opacity(0.12) : AppDesign.ColorToken.inlineFill, in: Capsule())
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    /// 打开分级提示并要第一级：只给方向，不给代码。
    private func requestDirection() {
        guard let questionWorkspace = selectedWorkspace else { return }
        session.assistantMode = .hints
        withAnimation(AppDesign.Motion.selection) { session.isAssistantPresented = true }
        guard session.hints(for: session.selectedQuestionSlug).isEmpty else { return }
        Task { await session.requestHint(question: selectedQuestion, workspace: questionWorkspace, dataStore: dataStore) }
    }

    private func startJudge(_ action: LeetCodeJudgeAction) {
        guard let question = selectedQuestion else { return }
        guard let questionWorkspace = selectedWorkspace else {
            return
        }
        Task { await session.judge(action, question: question, workspace: questionWorkspace, dataStore: dataStore) }
    }

    /// 从结果区等位置直接带着一句话打开 AI 浮窗。已经在生成时只填进输入框，不打断。
    private func askAssistant(_ prompt: String) {
        guard let slug = session.selectedQuestionSlug else { return }
        session.assistantMode = .chat
        if (session.assistantDrafts[slug] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            session.assistantDrafts[slug] = prompt
        }
        withAnimation(AppDesign.Motion.selection) { session.isAssistantPresented = true }
    }

    private var activePlanName: String {
        dataStore.leetCodePlans.first { $0.id == dataStore.activeLeetCodePlanID }?.name ?? "选择题单"
    }

    private func rebuildActivityBoardCache() {
        activityLayout = LeetCodeActivityCalendar.layout(activity: dataStore.leetCodeActivity)
        activityInsight = LeetCodeActivityInsight.make(
            questions: dataStore.leetCodeQuestions,
            submissions: dataStore.leetCodeSubmissions,
            plan: dataStore.leetCodePlans.first { $0.id == dataStore.activeLeetCodePlanID }
        )
    }

    private func rebuildQuestionFilterCache() {
        let query = debouncedSearchText
        filteredQuestionsCache = dataStore.leetCodeQuestions.filter { question in
            let queryMatches = query.isEmpty
                || question.title.localizedCaseInsensitiveContains(query)
                || question.frontendID.localizedCaseInsensitiveContains(query)
                || question.topicTags.contains { $0.localizedCaseInsensitiveContains(query) }
            return queryMatches && session.statusFilter.matches(question) && session.difficultyFilter.matches(question)
        }
    }

    private func openQuestion(_ slug: String) {
        session.openQuestion(slug)
    }

    private func question(for slug: String) -> LeetCodeQuestion? {
        if let question = dataStore.leetCodeQuestions.first(where: { $0.titleSlug == slug }) { return question }
        guard let submission = dataStore.leetCodeSubmissions.first(where: { $0.titleSlug == slug }) else { return nil }
        let related = dataStore.leetCodeSubmissions.filter { $0.titleSlug == slug }
        return LeetCodeQuestion(
            titleSlug: slug, frontendID: submission.frontendID, title: submission.title,
            difficulty: "", status: related.contains(where: \.accepted) ? "SOLVED" : "TRIED",
            paidOnly: false, acceptanceRate: nil, groupName: "最近提交", topicTags: [],
            submissionCount: related.count, acceptedCount: related.lazy.filter(\.accepted).count,
            lastSubmittedAt: related.max(by: { $0.submittedAt < $1.submittedAt })?.submittedAt
        )
    }

    private func prepareEditor() {
        guard let questionWorkspace = selectedWorkspace else { return }
        session.prepareEditor(for: questionWorkspace)
    }

    private func testCaseBinding(for slug: String) -> Binding<String> {
        Binding {
            let cases = currentTestCases
            return cases[session.selectedTestCaseIndex(for: slug, caseCount: cases.count)]
        } set: { value in
            let cases = currentTestCases
            session.updateTestCase(
                value,
                at: session.selectedTestCaseIndex(for: slug, caseCount: cases.count),
                slug: slug,
                official: selectedWorkspace?.sampleTestCases ?? []
            )
        }
    }

    private func ensureWorkspace(_ slug: String, force: Bool = false) async {
        if !force, dataStore.leetCodeWorkspaces[slug] != nil {
            prepareEditor()
            return
        }
        guard workspaceLoadingSlug != slug else { return }
        workspaceLoadingSlug = slug
        workspaceError = nil
        defer { if workspaceLoadingSlug == slug { workspaceLoadingSlug = nil } }
        do {
            _ = try await dataStore.fetchLeetCodeWorkspace(slug)
            guard session.selectedQuestionSlug == slug else { return }
            prepareEditor()
        } catch {
            guard session.selectedQuestionSlug == slug else { return }
            workspaceError = error.localizedDescription
        }
    }

    private func ensureSubmissionDetail(_ id: String, force: Bool = false) async {
        if !force, dataStore.leetCodeSubmissionDetails[id] != nil { return }
        guard submissionDetailLoadingIDs.insert(id).inserted else { return }
        submissionDetailErrors[id] = nil
        defer { submissionDetailLoadingIDs.remove(id) }
        do {
            _ = try await dataStore.fetchLeetCodeSubmissionDetail(id)
        } catch {
            submissionDetailErrors[id] = error.localizedDescription
        }
    }

    private func ensureQuestionHistory(_ slug: String, force: Bool = false) async {
        if !force, historyLoadingSlug == slug { return }
        historyLoadingSlug = slug
        historyErrors[slug] = nil
        defer { if historyLoadingSlug == slug { historyLoadingSlug = nil } }
        do {
            _ = try await dataStore.refreshLeetCodeQuestionHistory(slug, onDemand: true)
        } catch {
            guard session.selectedQuestionSlug == slug else { return }
            historyErrors[slug] = error.localizedDescription
        }
    }

    private func copy(_ value: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
    }

    private func openInBrowser(_ value: String) {
        guard let url = URL(string: value) else { return }
        workspace.openURL(url)
    }

    private func statusColor(_ status: String) -> Color {
        status == "SOLVED" ? .green : status == "TRIED" ? .orange : .secondary.opacity(0.5)
    }

    private func difficultyTitle(_ value: String) -> String {
        switch value.uppercased() { case "EASY": "简单"; case "HARD": "困难"; case "MEDIUM": "中等"; default: "" }
    }

    private func difficultyColor(_ value: String) -> Color {
        switch value.uppercased() { case "EASY": .green; case "HARD": .red; default: .orange }
    }

    private struct LeetCodeQuestionGroup: Identifiable {
        var id: String { name }
        let name: String
        let questions: [LeetCodeQuestion]

        var solvedCount: Int { questions.lazy.filter { $0.status == "SOLVED" }.count }
    }
}

enum LeetCodeTestCaseWorkspace {
    static func editableCases(from officialCases: [String]) -> [String] {
        officialCases.isEmpty ? [""] : officialCases
    }

    static func clampedIndex(_ index: Int, caseCount: Int) -> Int {
        min(max(0, index), max(0, caseCount - 1))
    }
}

enum LeetCodeBottomPanelLayout {
    static let minimumHeight: CGFloat = 172
    static let defaultHeight: CGFloat = 236
    /// 固定上限的下限。大屏上按可用高度放宽（见 `maximumHeight(for:)`）：
    /// 原来钉死 430，1080p 全屏时一长串失败用例只能在一小格里滚。
    static let maximumHeight: CGFloat = 430
    static let minimumEditorHeight: CGFloat = 220
    /// 样例标签那一行的高度，自动撑开时要算进去。
    static let tabsHeight: CGFloat = 36

    static func maximumHeight(for availableHeight: CGFloat) -> CGFloat {
        max(maximumHeight, (availableHeight * 0.6).rounded())
    }

    static func clampedHeight(_ requestedHeight: CGFloat, availableHeight: CGFloat) -> CGFloat {
        let availableMaximum = max(minimumHeight, availableHeight - minimumEditorHeight - 52)
        return min(maximumHeight(for: availableHeight), availableMaximum, max(minimumHeight, requestedHeight))
    }

    /// 刚好放下结果内容的高度（再夹进可拖范围）。
    static func heightToFit(content: CGFloat, availableHeight: CGFloat) -> CGFloat {
        clampedHeight(content + tabsHeight + 1, availableHeight: availableHeight)
    }
}

/// 题面渲染。刷题页与学习题库详情页共用同一份排版，别再复制一份出来。
///
/// `onHeightChange` 给"嵌在长页面里"的调用方用：报告内容真实高度后由外面把
/// frame 撑到刚好，题面自身不再滚动，滚轮就不会被这块 WebView 吃掉。
struct LeetCodeProblemWebView: NSViewRepresentable {
    let html: String
    var bottomPadding: CGFloat = 80
    var onHeightChange: ((CGFloat) -> Void)?
    var pageZoom: CGFloat = WebViewPresentation.interfaceZoom

    func makeCoordinator() -> Coordinator {
        Coordinator(onHeightChange: onHeightChange)
    }

    func makeNSView(context: Context) -> ProblemStatementWebView {
        let configuration = WKWebViewConfiguration()
        // 题面自身要么按内容铺开（不滚动），要么在刷题页里滚动——后者交给注入的悬浮 thumb。
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        WebViewPresentation.applyFloatingScrollbars(in: configuration)
        let webView = ProblemStatementWebView(frame: .zero, configuration: configuration)
        WebViewPresentation.applyInterfaceZoom(pageZoom, to: webView)
        webView.underPageBackgroundColor = .clear
        webView.navigationDelegate = context.coordinator
        webView.setAccessibilityIdentifier(String(html.hashValue))
        webView.loadHTMLString(document, baseURL: Self.problemBaseURL)
        return webView
    }

    func updateNSView(_ webView: ProblemStatementWebView, context: Context) {
        context.coordinator.onHeightChange = onHeightChange
        if WebViewPresentation.applyInterfaceZoom(pageZoom, to: webView) {
            // 内容高度按新缩放重量一次，嵌在长页面里的题面才不会被截断或留白。
            context.coordinator.measureHeight(of: webView)
        }
        guard webView.accessibilityIdentifier() != String(html.hashValue) else { return }
        webView.setAccessibilityIdentifier(String(html.hashValue))
        webView.loadHTMLString(document, baseURL: Self.problemBaseURL)
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        var onHeightChange: ((CGFloat) -> Void)?

        init(onHeightChange: ((CGFloat) -> Void)?) {
            self.onHeightChange = onHeightChange
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            // LeetCode sends bare <pre><code> nodes. Normalize them to the same DOM contract
            // used by chat before measuring, so statement snippets get the shared header and
            // spacing without changing the statement's remote base URL.
            webView.evaluateJavaScript(Self.normalizeCodeBlocksScript) { [weak self, weak webView] _, _ in
                guard let webView else { return }
                self?.measureHeight(of: webView)
            }
        }

        /// scrollHeight 是 CSS px；页面缩放后乘回点数，外层 frame 才撑得刚好。
        func measureHeight(of webView: WKWebView) {
            webView.evaluateJavaScript("document.documentElement.scrollHeight") { [weak self, weak webView] value, _ in
                guard let webView else { return }
                guard let cssHeight = value as? CGFloat ?? (value as? NSNumber).map({ CGFloat($0.doubleValue) }) else { return }
                let height = (cssHeight * webView.pageZoom).rounded(.up)
                (webView as? ProblemStatementWebView)?.contentScrollHeight = height
                self?.onHeightChange?(height)
            }
        }

        private static let normalizeCodeBlocksScript = """
        (() => {
          const copyGlyph = '<span class="copy" aria-hidden="true">'
            + '<span class="copy-glyph" aria-hidden="true"></span></span>';
          document.querySelectorAll('pre').forEach(pre => {
            if (pre.closest('.code-block')) return;
            const code = pre.querySelector(':scope > code');
            if (!code) return;
            const raw = [...code.classList].find(value => value.startsWith('language-'))?.slice(9) || 'text';
            code.classList.add('hljs');
            const section = document.createElement('section');
            section.className = 'code-block';
            section.innerHTML = `<header class="code-head"><span>${raw}</span>${copyGlyph}</header>`;
            pre.replaceWith(section);
            section.append(pre);
          });
        })()
        """

    }

    /// Keep LeetCode as the document base so relative statement images and links still
    /// resolve to the problem site. Shared app resources are therefore inlined below;
    /// using the bundle as base URL fixes CSS but silently breaks those relative URLs.
    private static let problemBaseURL = URL(string: "https://leetcode.cn/")!

    private var document: String {
        """
        <!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
        <style>
        \(Self.sharedCodeBlockCSS)
        :root{color-scheme:light dark}body{margin:0;padding:24px 26px \(Int(bottomPadding))px;background:transparent;color:CanvasText;font:14px/1.7 -apple-system,BlinkMacSystemFont,sans-serif;letter-spacing:0;overflow-wrap:anywhere;word-break:break-word}pre:not(.code-block pre){white-space:pre-wrap}code{overflow-wrap:anywhere}table{display:block;max-width:100%;overflow-x:auto}p{margin:0 0 15px}img{display:block;max-width:100%;height:auto;margin:16px auto}li{margin:6px 0}strong{font-weight:650}a{color:#0a7aff;text-decoration:none}
        </style></head><body>\(html)</body></html>
        """
    }

    private static let sharedCodeBlockCSS: String = {
        let url = Bundle.appResources.url(
            forResource: "code-block",
            withExtension: "css",
            subdirectory: "RichContent"
        ) ?? Bundle.appResources.url(forResource: "code-block", withExtension: "css")
        guard let url, let css = try? String(contentsOf: url, encoding: .utf8) else { return "" }
        // A CSS file cannot normally contain a closing style tag. Escaping it keeps this
        // embedding safe even if the shared resource is edited with generated content later.
        return css.replacingOccurrences(of: "</style", with: "<\\/style", options: .caseInsensitive)
    }()
}

/// 嵌在长页面里按内容铺开的 WKWebView 仍会先 intercept 滚轮：内部滚动走不动，
/// 事件又不会自动冒泡给外层 SwiftUI ScrollView。内容不超出视口时把滚轮
/// 交给响应链，让外层页面继续滚；刷题页里内容超出时保持自身滚动。
final class ProblemStatementWebView: WKWebView {
    var contentScrollHeight: CGFloat = 0

    override func scrollWheel(with event: NSEvent) {
        guard contentScrollHeight > 0, contentScrollHeight <= bounds.height + 2 else {
            super.scrollWheel(with: event)
            return
        }
        nextResponder?.scrollWheel(with: event)
    }
}
