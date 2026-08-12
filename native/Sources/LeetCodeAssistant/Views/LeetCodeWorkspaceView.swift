import AppKit
import SwiftUI
import WebKit

struct LeetCodeWorkspaceView: View {
    @Bindable var workspace: WorkspaceState
    @Bindable var dataStore: LegacyDataStore
    @State private var section = Section.library
    @State private var searchText = ""
    @State private var debouncedSearchText = ""
    @State private var filteredQuestionsCache: [LeetCodeQuestion] = []
    @State private var activityLayout = LeetCodeActivityCalendar.Layout.empty
    @State private var activityInsight = LeetCodeActivityInsight.empty
    @State private var statusFilter = StatusFilter.all
    @State private var difficultyFilter = DifficultyFilter.all
    @State private var selectedQuestionSlug: String?
    @State private var selectedSubmissionID: String?
    @State private var isSolving = false
    @State private var selectedLanguage = "java"
    @State private var code = ""
    @State private var testCase = ""
    @State private var selectedTestCaseIndex = 0
    @State private var editableTestCasesBySlug: [String: [String]] = [:]
    @State private var selectedTestCaseIndexBySlug: [String: Int] = [:]
    @State private var bottomPanelHeightsBySlug: [String: CGFloat] = [:]
    @GestureState private var bottomPanelDragTranslation: CGFloat = 0
    @State private var workspaceLoadingSlug: String?
    @State private var workspaceError: String?
    @State private var submissionDetailLoadingIDs: Set<String> = []
    @State private var submissionDetailErrors: [String: String] = [:]
    @State private var historyLoadingSlug: String?
    @State private var historyErrors: [String: String] = [:]
    @State private var judgeProgress: LeetCodeJudgeProgress?
    @State private var judgeResult: LeetCodeJudgeResult?
    @State private var judgeError: String?
    @State private var judgeAction: JudgeAction?
    @State private var editorDiagnostics = LeetCodeEditorDiagnostics()
    @State private var editorLoadStatus = LeetCodeEditorLoadStatus.loading
    @State private var completionStatus = LeetCodeCompletionStatus.localOnly
    @State private var questionMeta = LeetCodeQuestionMeta.empty
    @State private var showsSolutions = false
    @State private var editorReloadRequest = 0
    @State private var editorFormatRequest = 0
    @State private var editorUndoRequest = 0
    @State private var editorRedoRequest = 0
    /// AI 提示：按题存，换题清空。一级一级点出来，不一次给完。
    @State private var codeHints: [CodingHint] = []
    @State private var hintSlug = ""
    @State private var isHinting = false
    @State private var hintError = ""
    @State private var showsHints = false
    /// 弹层里内容的真实高度。ScrollView 在 popover 里没有固有高度，
    /// 不量一下就会塌成一条缝。
    @State private var hintContentHeight: CGFloat = 0
    /// 提示卡的尺寸跟着系统文字大小走。写死 pt 的话，用户把文字调大、
    /// 或者换到 5K 屏，卡片还是那么小一块，字挤成一团。
    @ScaledMetric(relativeTo: .body) private var hintPanelWidth: CGFloat = 360
    @ScaledMetric(relativeTo: .body) private var hintPanelMaximumHeight: CGFloat = 400
    @ScaledMetric(relativeTo: .body) private var hintActionHeight: CGFloat = 32

    private var selectedQuestion: LeetCodeQuestion? {
        dataStore.leetCodeQuestions.first { $0.titleSlug == selectedQuestionSlug }
            ?? selectedSubmission.flatMap { submission in
                question(for: submission.titleSlug)
            }
    }

    private var selectedSubmission: LeetCodeSubmission? {
        dataStore.leetCodeSubmissions.first { $0.id == selectedSubmissionID }
    }

    private var selectedWorkspace: LeetCodeQuestionWorkspace? {
        selectedQuestionSlug.flatMap { dataStore.leetCodeWorkspaces[$0] }
    }

    private var filteredQuestions: [LeetCodeQuestion] {
        filteredQuestionsCache
    }

    private var currentTestCases: [String] {
        guard let slug = selectedQuestionSlug else { return [""] }
        return editableTestCasesBySlug[slug]
            ?? LeetCodeTestCaseWorkspace.editableCases(from: selectedWorkspace?.sampleTestCases ?? [])
    }

    var body: some View {
        VStack(spacing: 0) {
            if selectedQuestion == nil {
                overviewToolbar
                Divider()
                overview
            } else {
                questionToolbar
                Divider()
                questionWorkspace
            }
        }
        .background(AppDesign.ColorToken.canvas)
        .onAppear {
            rebuildQuestionFilterCache()
            rebuildActivityBoardCache()
        }
        .task(id: searchText) {
            try? await Task.sleep(for: .milliseconds(220))
            guard !Task.isCancelled else { return }
            debouncedSearchText = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
            rebuildQuestionFilterCache()
        }
        .onChange(of: statusFilter) { _, _ in rebuildQuestionFilterCache() }
        .onChange(of: difficultyFilter) { _, _ in rebuildQuestionFilterCache() }
        .onChange(of: dataStore.leetCodeQuestions) { _, _ in
            rebuildQuestionFilterCache()
            rebuildActivityBoardCache()
        }
        .onChange(of: dataStore.leetCodeActivity) { _, _ in rebuildActivityBoardCache() }
        .onChange(of: dataStore.activeLeetCodePlanID) { _, _ in rebuildActivityBoardCache() }
        .onChange(of: selectedQuestionSlug) { _, _ in
            prepareEditor()
            // 换题就把提示清空，否则按钮上还挂着上一题的 "提示 2/3"。
            codeHints = []
            hintError = ""
            showsHints = false
        }
        .task(id: selectedQuestionSlug) {
            guard let slug = selectedQuestionSlug else { return }
            await ensureWorkspace(slug)
        }
        .task(id: selectedQuestionSlug) {
            guard let slug = selectedQuestionSlug else { return }
            await ensureQuestionHistory(slug)
        }
        .task(id: selectedSubmissionID) {
            guard let id = selectedSubmissionID else { return }
            await ensureSubmissionDetail(id)
        }
        // 分析队列的 worker 已移到 RootWorkspaceView：它挂在这里时，
        // 离开刷题页就会取消任务、把取消当失败计数，最终把队列删空。
    }

    private var overviewToolbar: some View {
        HStack(spacing: 12) {
            GlassSegmentedControl(
                options: Section.allCases.map { ($0.rawValue, $0.title) },
                selection: Binding(
                    get: { section.rawValue },
                    set: { section = Section(rawValue: $0) ?? section }
                )
            )
            .frame(width: 248)

            if section == .library {
                Menu {
                    ForEach(dataStore.leetCodePlans) { plan in
                        Button {
                            try? dataStore.selectLeetCodePlan(plan.id)
                            selectedQuestionSlug = nil
                            selectedSubmissionID = nil
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
                        Text(activePlanName).lineLimit(1)
                        Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold))
                    }
                    .frame(maxWidth: 180, alignment: .leading)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
            }

            Spacer(minLength: 12)

            if section == .library {
                TextField("搜索题号、题目或标签", text: $searchText)
                    .textFieldStyle(.plain)
                    .padding(.horizontal, 10)
                    .frame(width: 220, height: 28)
                    .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 7))
            }

            Button {
                dataStore.reload()
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 26, height: 26)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .glassCircle()
            .help("重新读取同步数据")
        }
        .padding(.horizontal, 14)
        .frame(height: 46)
    }

    @ViewBuilder
    private var overview: some View {
        switch section {
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
                    options: StatusFilter.allCases.map { ($0.rawValue, $0.title) },
                    selection: Binding(
                        get: { statusFilter.rawValue },
                        set: { statusFilter = StatusFilter(rawValue: $0) ?? statusFilter }
                    )
                )
                .frame(width: 218)

                GlassSegmentedControl(
                    options: DifficultyFilter.allCases.map { ($0.rawValue, $0.title) },
                    selection: Binding(
                        get: { difficultyFilter.rawValue },
                        set: { difficultyFilter = DifficultyFilter(rawValue: $0) ?? difficultyFilter }
                    )
                )
                .frame(width: 232)
                Spacer()
                Text("\(filteredQuestions.count) 道题")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 16)
            .frame(height: 44)
            Divider()

            if filteredQuestions.isEmpty {
                ContentUnavailableView("没有符合条件的题目", systemImage: "magnifyingglass")
            } else {
                ScrollView {
                    LazyVStack(spacing: 14) {
                        ForEach(questionGroups) { group in
                            questionGroupCard(group)
                        }
                    }
                    .padding(.horizontal, 18)
                    .padding(.vertical, 16)
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
                    .font(.system(size: 19, weight: .semibold).monospacedDigit())
                    .foregroundStyle(color)
                Text(title).font(.caption).foregroundStyle(.secondary)
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
        VStack(spacing: 0) {
            HStack {
                Text(group.name)
                    .font(AppDesign.Typography.bodyEmphasis)
                Spacer()
                Text("\(group.solvedCount) / \(group.questions.count)")
                    .font(AppDesign.Typography.micro.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 16)
            .frame(height: 38)
            .frame(maxWidth: .infinity)
            .background(Color.primary.opacity(0.04))

            ForEach(Array(group.questions.enumerated()), id: \.element.id) { index, question in
                if index > 0 {
                    Divider().padding(.leading, 46)
                }
                questionRow(question)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: AppDesign.Radius.card, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: AppDesign.Radius.card, style: .continuous)
                .strokeBorder(AppDesign.ColorToken.separator)
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
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .frame(width: 44, alignment: .trailing)
                VStack(alignment: .leading, spacing: 3) {
                    Text(question.title).font(.system(size: 14, weight: .medium)).lineLimit(1)
                    Text(([question.groupName] + question.topicTags.prefix(3)).filter { !$0.isEmpty }.joined(separator: " · "))
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 8)
                if question.submissionCount > 0 {
                    Text("\(question.submissionCount) 次")
                        .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
                Text(difficultyTitle(question.difficulty))
                    .font(.caption.weight(.medium))
                    .foregroundStyle(difficultyColor(question.difficulty))
                    .frame(width: 40)
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 16)
            .frame(height: 54)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var activityView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                profileHeader
                LeetCodeActivityMetricsRow(
                    layout: activityLayout,
                    insight: activityInsight,
                    dueCount: dataStore.dueCount,
                    weakCount: dataStore.weakCount
                )
                HStack(alignment: .top, spacing: 14) {
                    LeetCodeActivityHeatmapCard(layout: activityLayout)
                    LeetCodeActivityWeekRhythm(layout: activityLayout)
                        .frame(width: 250)
                }
                LeetCodeActivityBreakdown(insight: activityInsight)
                HStack(alignment: .top, spacing: 14) {
                    planProgress
                    recentActivity
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity)
        }
        .floatingScrollIndicators()
        .background(activityBackdrop)
    }

    /// 玻璃需要背后有东西才折射得出来。给动态页铺一层极淡的冷暖渐变，
    /// 卡片压上去才有"浮在表面"的层次，而不是一块块灰方块。
    private var activityBackdrop: some View {
        LinearGradient(
            colors: [
                Color.accentColor.opacity(0.10),
                Color(nsColor: .systemTeal).opacity(0.05),
                Color.clear
            ],
            startPoint: .topLeading,
            endPoint: .bottom
        )
        .background(AppDesign.ColorToken.canvas)
        .ignoresSafeArea()
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
            .padding(.vertical, 6)
            .inlineGlass(cornerRadius: AppDesign.Radius.small)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .navigationGlass(cornerRadius: AppDesign.Radius.floating)
    }

    @ViewBuilder
    private var profileAvatar: some View {
        if let data = dataStore.leetCodeProfile.avatarData, let image = NSImage(data: data) {
            Image(nsImage: image).resizable().scaledToFill()
                .frame(width: 54, height: 54).clipShape(RoundedRectangle(cornerRadius: 10))
        } else {
            Image(systemName: "person.crop.square").font(.system(size: 34)).foregroundStyle(.secondary)
                .frame(width: 54, height: 54)
        }
    }

    private var planProgress: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("学习计划", systemImage: "list.bullet.clipboard")
                .font(AppDesign.Typography.bodyEmphasis)
            if dataStore.leetCodePlans.isEmpty {
                Text("导入题单后显示进度")
                    .font(AppDesign.Typography.aux)
                    .foregroundStyle(.secondary)
            }
            ForEach(dataStore.leetCodePlans) { plan in
                Button {
                    try? dataStore.selectLeetCodePlan(plan.id)
                    section = .library
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
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .inlineGlass(cornerRadius: AppDesign.Radius.card)
    }

    private var recentActivity: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("最近提交", systemImage: "clock.arrow.circlepath")
                .font(AppDesign.Typography.bodyEmphasis)
            if dataStore.leetCodeSubmissions.isEmpty {
                Text("同步后显示最近的提交记录")
                    .font(AppDesign.Typography.aux)
                    .foregroundStyle(.secondary)
            }
            ForEach(dataStore.leetCodeSubmissions.suffix(7).reversed()) { submission in
                submissionButton(submission, compact: true)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .inlineGlass(cornerRadius: AppDesign.Radius.card)
    }

    private var submissionsView: some View {
        VStack(spacing: 0) {
            HStack {
                Text("提交记录").font(.headline)
                Text("\(dataStore.leetCodeSubmissions.count) 条").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
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
            selectedSubmissionID = submission.id
            openQuestion(submission.titleSlug)
        } label: {
            HStack(spacing: 10) {
                Circle().fill(submission.accepted ? Color.green : Color.orange).frame(width: 7, height: 7)
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(submission.frontendID). \(submission.title)")
                        .font(.system(size: compact ? 13.5 : 14, weight: .medium)).lineLimit(1)
                    Text([submission.status.isEmpty ? (submission.accepted ? "通过" : "未通过") : submission.status,
                          submission.language.uppercased(), submission.runtime, submission.memory,
                          submission.submittedAt.formatted(date: .abbreviated, time: .shortened)]
                        .filter { !$0.isEmpty }.joined(separator: " · "))
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                if !compact { Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary) }
            }
            .padding(.vertical, compact ? 3 : 0)
            .padding(.horizontal, compact ? 0 : 16)
            .frame(minHeight: compact ? 38 : 54)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var questionToolbar: some View {
        HStack(spacing: 10) {
            Button {
                selectedQuestionSlug = nil
                selectedSubmissionID = nil
                isSolving = false
            } label: { Image(systemName: "chevron.left") }
                .buttonStyle(.plain).help("返回题库")
            if let question = selectedQuestion {
                Text("\(question.frontendID). \(question.title)")
                    .font(.system(size: 14, weight: .semibold)).lineLimit(1)
                Text(difficultyTitle(question.difficulty))
                    .font(.caption.weight(.medium)).foregroundStyle(difficultyColor(question.difficulty))
            }
            // 上/下一题跟着标题走（浮在题面左上角会盖住正文第一行）。
            // 只在「作答」下出现：看提交记录时连着翻题没有意义。
            if isSolving, let position = problemPosition, position.total > 1 {
                LeetCodeProblemNavBar(position: position) { slug in
                    selectedQuestionSlug = slug
                    selectedSubmissionID = nil
                }
            }
            Spacer()
            GlassSegmentedControl(
                options: [("view", "题目与提交"), ("solve", "作答")],
                selection: Binding(
                    get: { isSolving ? "solve" : "view" },
                    set: { isSolving = $0 == "solve" }
                )
            )
            .frame(width: 200)
            Button {
                guard let slug = selectedQuestion?.titleSlug else { return }
                guard let url = URL(string: "https://leetcode.cn/problems/\(slug)/") else { return }
                workspace.openURL(url)
            } label: {
                Image(systemName: "globe")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 26, height: 26)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .glassCircle()
            .help("在工具区打开题目来源")
        }
        .padding(.horizontal, 14).frame(height: 46)
    }

    /// 上一题 / 下一题在**当前筛选后的列表**里走，和左侧看到的顺序一致。
    private var problemPosition: LeetCodeProblemNavigator.Position? {
        LeetCodeProblemNavigator.position(
            of: selectedQuestionSlug,
            in: filteredQuestions.map(\.titleSlug)
        )
    }

    private var questionWorkspace: some View {
        HSplitView {
            Group {
                if let workspace = selectedWorkspace, !workspace.htmlContent.isEmpty {
                    LeetCodeProblemWebView(html: workspace.htmlContent)
                } else if workspaceLoadingSlug == selectedQuestionSlug {
                    ProgressView("正在从力扣读取题目…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let workspaceError {
                    VStack(spacing: 12) {
                        ContentUnavailableView("题目加载失败", systemImage: "exclamationmark.triangle", description: Text(workspaceError))
                        Button {
                            guard let slug = selectedQuestionSlug else { return }
                            Task { await ensureWorkspace(slug, force: true) }
                        } label: {
                            Label("重新加载", systemImage: "arrow.clockwise")
                                .font(.system(size: 12.5, weight: .medium))
                                .foregroundStyle(Color.accentColor)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 5)
                                .contentShape(Capsule())
                        }
                        .buttonStyle(.plain)
                        .glassCapsule()
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
            .frame(minWidth: 360, idealWidth: 560)
            // 两条都是**浮层**，不参与 HSplitView 的布局——力扣官网那条也是浮在题面窗格底部的胶囊。
            // 之前以为要把这一栏拆成上下结构才能加，是我想复杂了：题面照旧铺满，浮层压在它上面。
            .overlay(alignment: .bottom) { problemActionOverlay }
            .task(id: selectedQuestionSlug) { await loadQuestionMeta() }
            .sheet(isPresented: $showsSolutions) {
                if let slug = selectedQuestionSlug {
                    LeetCodeSolutionsBrowser(
                        titleSlug: slug,
                        title: selectedQuestion?.title ?? "题解",
                        onOpenURL: { url in
                            workspace.openURL(url)
                        }
                    )
                }
            }

            Group {
                if isSolving { editorPane } else { submissionDetailPane }
            }
            .frame(minWidth: 380, idealWidth: 560)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private var problemActionOverlay: some View {
        if let slug = selectedQuestionSlug, selectedWorkspace != nil {
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
        guard let slug = selectedQuestionSlug else {
            questionMeta = .empty
            return
        }
        // 换题时先清空：否则新题面配着上一题的点赞数，看着像数据错了。
        questionMeta = .empty
        guard let meta = try? await LeetCodeAPIClient.shared.fetchQuestionMeta(titleSlug: slug) else { return }
        guard selectedQuestionSlug == slug else { return }
        questionMeta = meta
    }

    private var submissionDetailPane: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                if let question = selectedQuestion {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("提交记录").font(.headline)
                                Text("\(question.submissionCount) 次提交 · \(question.acceptedCount) 次通过")
                                    .font(.caption).foregroundStyle(.secondary)
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
                            Text(error).font(.caption).foregroundStyle(.orange)
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
        let expanded = selectedSubmissionID == submission.id
        let insight = dataStore.leetCodeAnalyses[submission.titleSlug]?.attemptInsights.first { $0.submissionID == submission.id }
        return VStack(spacing: 0) {
            Button {
                selectedSubmissionID = expanded ? nil : submission.id
            } label: {
                HStack(spacing: 10) {
                    Circle().fill(submission.accepted ? Color.green : Color.orange).frame(width: 7, height: 7)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(submission.status.isEmpty ? (submission.accepted ? "通过" : "未通过") : submission.status)
                            .font(.subheadline.weight(.medium))
                        Text([submission.language.uppercased(), submission.runtime, submission.memory, submission.submittedAt.formatted(date: .abbreviated, time: .shortened)]
                            .filter { !$0.isEmpty }.joined(separator: " · "))
                            .font(.caption).foregroundStyle(.secondary)
                        if let insight, !insight.issue.isEmpty {
                            Text(insight.issue).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                        }
                    }
                    Spacer()
                    Image(systemName: "chevron.down").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
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
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(14)
                    } else if let error = submissionDetailErrors[submission.id] {
                        HStack(spacing: 10) {
                            Text(error).font(.caption).foregroundStyle(.secondary)
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
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.blue)
                    Text(analysis.rootCause.isEmpty ? analysis.summary : analysis.rootCause)
                        .font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if !analysis.suggestions.isEmpty {
                        VStack(alignment: .leading, spacing: 5) {
                            Text("建议").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                            ForEach(analysis.suggestions, id: \.self) { item in
                                Label(item, systemImage: "arrow.turn.down.right")
                                    .font(.caption)
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
                        .font(.subheadline.weight(.semibold))
                    Spacer()
                    if dataStore.leetCodeAnalysisProcessingSlug == question.titleSlug {
                        ProgressView().controlSize(.small)
                        Text("AI 正在分析").font(.caption).foregroundStyle(.secondary)
                    } else if let task {
                        Text("\(task.submissionIDs.count) 条待分析").font(.caption).foregroundStyle(.secondary)
                    } else if let analysis, analysis.updatedAt != .distantPast {
                        Text(analysis.updatedAt.formatted(.relative(presentation: .named)))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                if let task, !task.lastError.isEmpty {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
                        Text("上次分析失败：\(task.lastError)。将自动重试。")
                            .font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button("立即重试") {
                            try? dataStore.retryLeetCodeAnalysis(question.titleSlug)
                        }
                        .controlSize(.small)
                    }
                }
                if let analysis {
                    if !analysis.summary.isEmpty {
                        Text(analysis.summary).font(.callout).fixedSize(horizontal: false, vertical: true)
                    }
                    HStack(alignment: .top, spacing: 20) {
                        analysisList("待巩固", values: analysis.weaknesses, color: .orange)
                        analysisList("下一步", values: analysis.improvements, color: .blue)
                    }
                } else {
                    Text(task?.lastError.isEmpty == false ? "分析失败，等待重试" : "已进入分析队列")
                        .font(.caption).foregroundStyle(.secondary)
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
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(color)
            if values.isEmpty {
                Text("暂无").font(.caption).foregroundStyle(.tertiary)
            } else {
                ForEach(values, id: \.self) { value in
                    HStack(alignment: .top, spacing: 6) {
                        Circle().fill(color).frame(width: 4, height: 4).padding(.top, 6)
                        Text(value).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
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
                Text(label).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                SyntaxHighlightedCodeView(code: value, language: blockLanguage)
            }
        }
    }

    private func detailMetric(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(.subheadline.weight(.semibold).monospacedDigit())
            Text(title).font(.caption2).foregroundStyle(.secondary)
        }
    }

    private var editorPane: some View {
        GeometryReader { proxy in
            let slug = selectedQuestionSlug ?? ""
            let storedHeight = bottomPanelHeightsBySlug[slug] ?? LeetCodeBottomPanelLayout.defaultHeight
            let panelHeight = LeetCodeBottomPanelLayout.clampedHeight(
                storedHeight - bottomPanelDragTranslation,
                availableHeight: proxy.size.height
            )
            VStack(spacing: 0) {
                editorToolbar
                Divider()
                LeetCodeCodeEditor(
                    code: $code,
                    language: selectedLanguage,
                    diagnostics: $editorDiagnostics,
                    loadStatus: $editorLoadStatus,
                    completionStatus: $completionStatus,
                    formatRequest: editorFormatRequest,
                    undoRequest: editorUndoRequest,
                    redoRequest: editorRedoRequest
                )
                .id(editorReloadRequest)
                .background(AppDesign.ColorToken.canvas)
                .overlay {
                    editorLoadOverlay
                }
                panelResizeHandle(slug: slug, availableHeight: proxy.size.height)
                testCasePanel(slug: slug)
                    .frame(height: panelHeight)
            }
        }
    }

    private func editorToolButton(
        _ systemName: String,
        help: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 26, height: 26)
                .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private var editorToolbar: some View {
        HStack(spacing: 10) {
            Menu {
                ForEach(selectedWorkspace?.snippets ?? []) { snippet in
                    Button {
                        selectedLanguage = snippet.languageSlug
                        loadSnippet()
                    } label: {
                        Label(
                            snippet.language,
                            systemImage: snippet.languageSlug == selectedLanguage ? "checkmark" : "circle"
                        )
                    }
                }
            } label: {
                HStack(spacing: 6) {
                    Text(selectedWorkspace?.snippets.first { $0.languageSlug == selectedLanguage }?.language ?? selectedLanguage)
                        .font(.system(size: 12.5, weight: .medium))
                        .lineLimit(1)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                .frame(width: 108)
                .padding(.vertical, 5)
                .contentShape(Capsule())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .glassCapsule()
            .help("切换语言")

            Label(completionStatus.title, systemImage: completionStatus.isOnline ? "bolt.horizontal.circle.fill" : "bolt.slash")
                .font(.caption2)
                .foregroundStyle(completionStatus.isOnline ? Color.green : Color.secondary)
                .lineLimit(1)
                .layoutPriority(-1)
                .help(completionStatus.detail)
            Spacer(minLength: 12)
            // 每个图标给足 26pt 的方形点击区，彼此留 4pt。
            // 原来是 spacing 2 + 纯字形尺寸，四个图标几乎贴在一起，既难点也难看。
            hintButton
            HStack(spacing: 4) {
                editorToolButton("arrow.uturn.backward", help: "撤销") { editorUndoRequest &+= 1 }
                editorToolButton("arrow.uturn.forward", help: "重做") { editorRedoRequest &+= 1 }
                Divider().frame(height: 14).padding(.horizontal, 2)
                editorToolButton("doc.on.doc", help: "复制代码") { copy(code) }
                editorToolButton("textformat", help: "安全格式化缩进") { editorFormatRequest &+= 1 }
            }
            .padding(.horizontal, 5)
            .frame(height: 30)
            .glassCapsule()
        }
        .padding(.horizontal, 12)
        .frame(height: 42)
    }

    // MARK: - AI 提示
    //
    // 交互刻意做成"一级一级要"：点开先只给方向，卡住了再点「还想不出来」
    // 才给卡点，最后才给下一步该做什么。每一级都读当前编辑器里的代码，
    // 但提示词禁止给完整解法——直接把答案贴出来，这道题就白做了。

    private var hintButton: some View {
        Button {
            showsHints = true
            if codeHints.isEmpty { Task { await requestHint() } }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: isHinting ? "ellipsis" : "lightbulb.max")
                    .font(.system(size: 12, weight: .medium))
                    .symbolEffect(.pulse, isActive: isHinting)
                Text(codeHints.isEmpty ? "AI 提示" : "提示 \(codeHints.count)/3")
                    .font(.system(size: 12.5, weight: .medium))
            }
            .foregroundStyle(codeHints.isEmpty ? Color.secondary : Color.accentColor)
            .padding(.horizontal, 11)
            .frame(height: 30)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .glassCapsule()
        .help("读当前代码给提示，只点方向不给答案")
        .popover(isPresented: $showsHints, arrowEdge: .bottom) {
            // 宽度也跟着系统文字大小走：字变大而框不变，只会把每行挤成两三个词。
            hintPanel.frame(width: hintPanelWidth)
        }
    }

    private var hintPanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "lightbulb.max")
                    .font(.callout)
                    .foregroundStyle(Color.accentColor)
                Text("AI 提示")
                    .font(.headline)
                Spacer()
                if !codeHints.isEmpty {
                    // 和下面「还想不出来」同一套外观：一段灰字看不出来是能点的。
                    Button {
                        codeHints = []
                        Task { await requestHint() }
                    } label: {
                        Label("重新看一遍代码", systemImage: "arrow.clockwise")
                            .font(.callout.weight(.medium))
                            .foregroundStyle(isHinting ? Color.secondary : Color.accentColor)
                            .padding(.horizontal, 9)
                            .frame(height: 25)
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .background(
                        (isHinting ? Color.secondary : Color.accentColor).opacity(0.12),
                        in: Capsule()
                    )
                    .disabled(isHinting)
                    .help("按当前编辑器里的代码重新给一轮提示")
                }
            }
            .padding(.horizontal, 14)
            .padding(.top, 13)
            .padding(.bottom, 8)

            Text("只给方向和卡点，不给完整解法")
                .font(.callout)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 14)
                .padding(.bottom, 10)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(codeHints) { hint in
                        hintCard(hint)
                    }
                    if isHinting {
                        HStack(spacing: 7) {
                            ProgressView().controlSize(.small)
                            Text(codeHints.isEmpty ? "正在读你的代码…" : "再想想怎么说更具体…")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                    }
                    if !hintError.isEmpty {
                        Label(hintError, systemImage: "exclamationmark.triangle")
                            .font(.callout)
                            .foregroundStyle(AppDesign.ColorToken.warning)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if !isHinting, codeHints.count < 3, !codeHints.isEmpty {
                        Button {
                            Task { await requestHint() }
                        } label: {
                            Label(
                                codeHints.count == 1 ? "还想不出来，指一下我卡在哪" : "告诉我下一步做什么",
                                systemImage: "arrow.down.circle"
                            )
                            .font(.body.weight(.medium))
                            .frame(maxWidth: .infinity)
                            .frame(height: hintActionHeight)
                            .contentShape(Capsule())
                        }
                        .buttonStyle(.plain)
                        .background(Color.accentColor.opacity(0.12), in: Capsule())
                        .foregroundStyle(Color.accentColor)
                    }
                    if codeHints.count >= 3 {
                        Text("到此为止。再往下就是替你写了——剩下的自己试。")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { hintContentHeight = $0 }
            }
            .floatingScrollIndicators()
            // 内容不高就贴着内容，高了才封顶滚动。
            .frame(height: min(max(hintContentHeight, 60), hintPanelMaximumHeight))
        }
    }

    /// 一级提示。
    ///
    /// 字号全部走系统文字样式而不是写死的 pt：换到大屏或把系统文字调大时，
    /// 这张卡跟着变，而不是缩成一小块看不清的灰字。正文用主色不用次级色——
    /// 这是要读完的内容，不是脚注。
    private func hintCard(_ hint: CodingHint) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text(hint.levelTitle)
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(Color.accentColor.opacity(0.16), in: Capsule())
                    .foregroundStyle(Color.accentColor)
                if !hint.title.isEmpty {
                    Text(hint.title)
                        .font(.callout.weight(.medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Text(InlineMarkdown.attributed(hint.hint, codeFont: .system(.body, design: .monospaced)))
                .font(.body)
                .foregroundStyle(.primary)
                .lineSpacing(2.5)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            ForEach(hint.checkpoints.filter { !$0.isEmpty }, id: \.self) { point in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: "checkmark.circle")
                        .font(.callout)
                        .foregroundStyle(Color.accentColor.opacity(0.75))
                    Text(InlineMarkdown.attributed(point))
                        .font(.callout)
                        .foregroundStyle(.primary.opacity(0.82))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if !hint.question.isEmpty {
                Text(InlineMarkdown.attributed(hint.question))
                    .font(.callout.italic())
                    .foregroundStyle(Color.accentColor)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .inlineGlass(cornerRadius: AppDesign.Radius.medium)
    }

    private func requestHint() async {
        guard !isHinting, let workspace = selectedWorkspace else { return }
        // 换题了就从头来，别把上一题的提示接着往下发。
        if hintSlug != workspace.titleSlug {
            hintSlug = workspace.titleSlug
            codeHints = []
        }
        guard codeHints.count < 3 else { return }
        isHinting = true
        hintError = ""
        defer { isHinting = false }
        do {
            let hint = try await ChatService(dataDirectory: dataStore.dataDirectory).requestCodingHint(
                title: selectedQuestion?.title ?? workspace.titleSlug,
                content: LeetCodeQuestionActionBar.plainText(workspace.htmlContent),
                code: code,
                language: selectedLanguage,
                level: codeHints.count + 1,
                previousHints: codeHints.map(\.hint),
                providerID: AITaskRoute.codingHint.providerID(in: dataStore.settings)
            )
            codeHints.append(hint)
        } catch {
            hintError = error.localizedDescription
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
                    .font(.subheadline.weight(.semibold))
                Text(message).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
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
        .gesture(
            DragGesture(minimumDistance: 1)
                .updating($bottomPanelDragTranslation) { value, state, _ in
                    state = value.translation.height
                }
                .onEnded { value in
                    let current = bottomPanelHeightsBySlug[slug] ?? LeetCodeBottomPanelLayout.defaultHeight
                    bottomPanelHeightsBySlug[slug] = LeetCodeBottomPanelLayout.clampedHeight(
                        current - value.translation.height,
                        availableHeight: availableHeight
                    )
                }
        )
        .help("拖拽调整测试与运行结果区高度")
    }

    private func testCasePanel(slug: String) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Text("测试与结果")
                    .font(.caption.weight(.semibold))
                Spacer(minLength: 8)
                Label(
                    editorDiagnostics.statusText,
                    systemImage: editorDiagnostics.issues.isEmpty ? "checkmark.circle" : "exclamationmark.triangle"
                )
                .font(.caption)
                .foregroundStyle(editorDiagnostics.issues.isEmpty ? Color.secondary : Color.orange)
                .help(editorDiagnostics.issues.prefix(4).map { "第 \($0.line) 行：\($0.message)" }.joined(separator: "\n"))
            }
            .padding(.horizontal, 12)
            .frame(height: 32)

            testCaseTabs(slug: slug)
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
                    if judgeAction != nil || judgeResult != nil || judgeError != nil {
                        Divider()
                        judgeResultPanel
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .floatingScrollIndicators()

            Divider()
            HStack {
                Text(judgeProgress?.status ?? "运行与提交使用力扣官方评测环境")
                    .font(.caption).foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer()
                judgeButton(
                    title: "运行",
                    systemImage: "play.fill",
                    tint: .primary,
                    disabled: judgeAction != nil || selectedWorkspace?.canRun != true || code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ) {
                    Task { await judge(.run) }
                }
                judgeButton(
                    title: "提交",
                    systemImage: "paperplane.fill",
                    tint: .accentColor,
                    disabled: judgeAction != nil || selectedWorkspace?.canSubmit != true || code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ) {
                    Task { await judge(.submit) }
                }
            }
            .padding(.horizontal, 12)
            .frame(height: 42)
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
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(tint)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .glassCapsule()
        .opacity(disabled ? 0.45 : 1)
        .allowsHitTesting(!disabled)
        .help(title)
    }

    private func testCaseTabs(slug: String) -> some View {
        let cases = currentTestCases
        return ScrollView(.horizontal) {
            HStack(spacing: 0) {
                ForEach(cases.indices, id: \.self) { index in
                    let selected = selectedTestCaseIndex == index
                    Button {
                        selectTestCase(index, slug: slug)
                    } label: {
                        VStack(spacing: 5) {
                            Text("样例 \(index + 1)")
                                .font(.caption.weight(selected ? .semibold : .regular))
                                .foregroundStyle(selected ? Color.primary : Color.secondary)
                                .lineLimit(1)
                            Rectangle()
                                .fill(selected ? Color.accentColor : Color.clear)
                                .frame(height: 2)
                        }
                        .padding(.horizontal, 12)
                        .frame(height: 34)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .floatingScrollIndicators(.horizontal)
        .frame(height: 34)
    }

    private var judgeResultPanel: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 8) {
                if judgeAction != nil {
                    ProgressView().controlSize(.small)
                    Text(judgeProgress?.status ?? "正在连接力扣评测")
                        .font(.subheadline.weight(.medium))
                } else if let result = judgeResult {
                    Image(systemName: result.accepted ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .foregroundStyle(result.accepted ? .green : .red)
                    Text(result.status).font(.subheadline.weight(.semibold))
                    Spacer()
                    if result.totalTestCases > 0 {
                        Text("\(result.totalCorrect)/\(result.totalTestCases)")
                            .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    }
                    if !result.runtime.isEmpty { Text(result.runtime).font(.caption).foregroundStyle(.secondary) }
                    if !result.memory.isEmpty { Text(result.memory).font(.caption).foregroundStyle(.secondary) }
                } else if let judgeError {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Text(judgeError).font(.caption).foregroundStyle(.secondary)
                }
            }
            if let result = judgeResult {
                let diagnostics = [
                    ("编译信息", result.compileError, "text"),
                    ("运行错误", result.runtimeError, "text"),
                    ("失败用例", result.input, selectedLanguage),
                    ("实际输出", result.output, selectedLanguage),
                    ("预期输出", result.expectedOutput, selectedLanguage)
                ].filter { !$0.1.isEmpty }
                ForEach(diagnostics, id: \.0) { label, value, language in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(label).font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                        SyntaxHighlightedCodeView(code: value, language: language)
                    }
                }
                if !result.aiJudgeMessage.isEmpty {
                    Text(result.aiJudgeMessage).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .padding(11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(judgeResult?.accepted == true ? Color.green.opacity(0.08) : Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 7))
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
            return queryMatches && statusFilter.matches(question) && difficultyFilter.matches(question)
        }
    }

    private func openQuestion(_ slug: String) {
        selectedQuestionSlug = slug
        isSolving = false
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
        guard let snippets = selectedWorkspace?.snippets, !snippets.isEmpty else {
            code = ""; testCase = ""; return
        }
        if !snippets.contains(where: { $0.languageSlug == selectedLanguage }) {
            selectedLanguage = snippets.first(where: { $0.languageSlug == "java" })?.languageSlug ?? snippets[0].languageSlug
        }
        loadSnippet()
        let slug = selectedQuestionSlug ?? ""
        if editableTestCasesBySlug[slug] == nil {
            editableTestCasesBySlug[slug] = LeetCodeTestCaseWorkspace.editableCases(
                from: selectedWorkspace?.sampleTestCases ?? []
            )
        }
        let cases = editableTestCasesBySlug[slug] ?? [""]
        let index = LeetCodeTestCaseWorkspace.clampedIndex(
            selectedTestCaseIndexBySlug[slug] ?? 0,
            caseCount: cases.count
        )
        selectedTestCaseIndex = index
        selectedTestCaseIndexBySlug[slug] = index
        testCase = cases[index]
        judgeProgress = nil
        judgeResult = nil
        judgeError = nil
    }

    private func selectTestCase(_ index: Int, slug: String) {
        let cases = currentTestCases
        let safeIndex = LeetCodeTestCaseWorkspace.clampedIndex(index, caseCount: cases.count)
        selectedTestCaseIndex = safeIndex
        selectedTestCaseIndexBySlug[slug] = safeIndex
        testCase = cases[safeIndex]
    }

    private func testCaseBinding(for slug: String) -> Binding<String> {
        Binding {
            let cases = editableTestCasesBySlug[slug]
                ?? LeetCodeTestCaseWorkspace.editableCases(from: selectedWorkspace?.sampleTestCases ?? [])
            let index = LeetCodeTestCaseWorkspace.clampedIndex(selectedTestCaseIndex, caseCount: cases.count)
            return cases[index]
        } set: { value in
            var cases = editableTestCasesBySlug[slug]
                ?? LeetCodeTestCaseWorkspace.editableCases(from: selectedWorkspace?.sampleTestCases ?? [])
            let index = LeetCodeTestCaseWorkspace.clampedIndex(selectedTestCaseIndex, caseCount: cases.count)
            cases[index] = value
            editableTestCasesBySlug[slug] = cases
            testCase = value
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
            guard selectedQuestionSlug == slug else { return }
            prepareEditor()
        } catch {
            guard selectedQuestionSlug == slug else { return }
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
            guard selectedQuestionSlug == slug else { return }
            historyErrors[slug] = error.localizedDescription
        }
    }

    private func judge(_ action: JudgeAction) async {
        guard judgeAction == nil else {
            judgeError = "当前判题仍在进行，请等待本次结果返回"
            return
        }
        guard let question = selectedQuestion,
              let currentWorkspace = selectedWorkspace,
              !currentWorkspace.questionID.isEmpty
        else {
            judgeError = workspaceLoadingSlug == selectedQuestionSlug
                ? "题目数据仍在加载，加载完成后即可运行或提交"
                : "题目评测信息未加载完整，请重新加载题目"
            return
        }
        judgeAction = action
        judgeProgress = nil
        judgeResult = nil
        judgeError = nil
        defer { judgeAction = nil }
        do {
            let result: LeetCodeJudgeResult
            switch action {
            case .run:
                result = try await LeetCodeAPIClient.shared.runCode(
                    titleSlug: question.titleSlug,
                    questionID: currentWorkspace.questionID,
                    language: selectedLanguage,
                    code: code,
                    testCase: testCase
                ) { judgeProgress = $0 }
            case .submit:
                result = try await LeetCodeAPIClient.shared.submitCode(
                    titleSlug: question.titleSlug,
                    questionID: currentWorkspace.questionID,
                    language: selectedLanguage,
                    code: code
                ) { judgeProgress = $0 }
            }
            judgeResult = result
            if action == .submit {
                _ = try await dataStore.refreshLeetCodeQuestionHistory(
                    question.titleSlug,
                    expectedSubmissionID: result.taskID,
                    onDemand: false
                )
                selectedSubmissionID = result.taskID
                await ensureSubmissionDetail(result.taskID)
            }
        } catch {
            judgeError = error.localizedDescription
        }
    }

    private func loadSnippet() {
        guard let snippet = selectedWorkspace?.snippets.first(where: { $0.languageSlug == selectedLanguage }) else { return }
        code = snippet.code
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

    private enum Section: String, CaseIterable, Identifiable {
        case library, activity, submissions
        var id: String { rawValue }
        var title: String { switch self { case .library: "题库"; case .activity: "动态"; case .submissions: "提交" } }
    }

    private enum StatusFilter: String, CaseIterable, Identifiable {
        case all, todo, tried, solved
        var id: String { rawValue }
        var title: String { switch self { case .all: "全部"; case .todo: "未开始"; case .tried: "尝试过"; case .solved: "已通过" } }
        func matches(_ question: LeetCodeQuestion) -> Bool {
            switch self { case .all: true; case .todo: question.status == "TO_DO"; case .tried: question.status == "TRIED"; case .solved: question.status == "SOLVED" }
        }
    }

    private enum DifficultyFilter: String, CaseIterable, Identifiable {
        case all, easy, medium, hard
        var id: String { rawValue }
        var title: String { switch self { case .all: "全部难度"; case .easy: "简单"; case .medium: "中等"; case .hard: "困难" } }
        func matches(_ question: LeetCodeQuestion) -> Bool { self == .all || question.difficulty.lowercased() == rawValue }
    }

    private enum JudgeAction {
        case run
        case submit
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
    static let maximumHeight: CGFloat = 430
    static let minimumEditorHeight: CGFloat = 220

    static func clampedHeight(_ requestedHeight: CGFloat, availableHeight: CGFloat) -> CGFloat {
        let availableMaximum = max(minimumHeight, availableHeight - minimumEditorHeight - 52)
        return min(maximumHeight, availableMaximum, max(minimumHeight, requestedHeight))
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

    func makeCoordinator() -> Coordinator {
        Coordinator(onHeightChange: onHeightChange)
    }

    func makeNSView(context: Context) -> ProblemStatementWebView {
        let configuration = WKWebViewConfiguration()
        // 题面自身要么按内容铺开（不滚动），要么在刷题页里滚动——后者交给注入的悬浮 thumb。
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        WebViewPresentation.applyFloatingScrollbars(in: configuration)
        let webView = ProblemStatementWebView(frame: .zero, configuration: configuration)
        webView.underPageBackgroundColor = .clear
        webView.navigationDelegate = context.coordinator
        webView.setAccessibilityIdentifier(String(html.hashValue))
        webView.loadHTMLString(document, baseURL: Self.problemBaseURL)
        return webView
    }

    func updateNSView(_ webView: ProblemStatementWebView, context: Context) {
        context.coordinator.onHeightChange = onHeightChange
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
                webView.evaluateJavaScript("document.documentElement.scrollHeight") { [weak self, weak webView] value, _ in
                    guard let webView else { return }
                    guard let height = value as? CGFloat ?? (value as? NSNumber).map({ CGFloat($0.doubleValue) }) else { return }
                    (webView as? ProblemStatementWebView)?.contentScrollHeight = height
                    self?.onHeightChange?(height)
                }
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
        :root{color-scheme:light dark}body{margin:0;padding:24px 26px \(Int(bottomPadding))px;background:transparent;color:CanvasText;font:14px/1.7 -apple-system,BlinkMacSystemFont,sans-serif;letter-spacing:0}p{margin:0 0 15px}img{display:block;max-width:100%;height:auto;margin:16px auto}li{margin:6px 0}strong{font-weight:650}a{color:#0a7aff;text-decoration:none}
        </style></head><body>\(html)</body></html>
        """
    }

    private static let sharedCodeBlockCSS: String = {
        let url = Bundle.module.url(
            forResource: "code-block",
            withExtension: "css",
            subdirectory: "RichContent"
        ) ?? Bundle.module.url(forResource: "code-block", withExtension: "css")
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
