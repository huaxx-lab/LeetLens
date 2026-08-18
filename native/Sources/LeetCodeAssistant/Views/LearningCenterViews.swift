import AppKit
import SwiftUI

struct LearningLibraryWorkspaceView: View {
    @Bindable var workspace: WorkspaceState
    @Bindable var dataStore: LegacyDataStore
    @State private var selectedID: String?
    @State private var searchText = ""
    @State private var category = "全部"
    /// 从别处跳进来时要滚到的目标；滚完置空。
    @State private var pendingScrollTarget: String?

    private var categories: [String] {
        ["全部"] + Set(dataStore.learningRecords.map(\.primaryKnowledge)).sorted()
    }

    private var records: [LearningRecord] {
        dataStore.learningRecords.filter { record in
            let categoryMatches = category == "全部" || record.primaryKnowledge == category
            let queryMatches = searchText.isEmpty
                || record.title.localizedCaseInsensitiveContains(searchText)
                || record.labels.contains { $0.localizedCaseInsensitiveContains(searchText) }
                || record.question.localizedCaseInsensitiveContains(searchText)
            return categoryMatches && queryMatches
        }
        .sorted { $0.updatedAt > $1.updatedAt }
    }

    /// 优先看本地选中，其次接受外部（学习洞察、学习计划、今日复习）带过来的目标。
    /// 原来只认 `selectedID`，从别处跳进来时 `workspace.selectedLearningRecordID` 被忽略，
    /// 于是永远落在 `records.first`（最近更新的那条）——点哪道题都跳到同一个地方。
    private var selectedRecord: LearningRecord? {
        let id = selectedID ?? workspace.selectedLearningRecordID
        return dataStore.learningRecords.first { $0.id == id } ?? records.first
    }

    /// 外部指定了目标就采纳，并清掉会把它挡在列表外的筛选——
    /// 否则右边显示的是那道题，左边列表里却找不到它，看着像跳错了。
    private func adoptExternalSelection() {
        guard let target = workspace.selectedLearningRecordID,
              dataStore.learningRecords.contains(where: { $0.id == target })
        else { return }
        if !records.contains(where: { $0.id == target }) {
            category = "全部"
            searchText = ""
        }
        selectedID = target
        pendingScrollTarget = target
    }

    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    Menu {
                        ForEach(categories, id: \.self) { item in
                            Button {
                                category = item
                            } label: {
                                Label(item, systemImage: item == category ? "checkmark" : "circle")
                            }
                        }
                    } label: {
                        HStack(spacing: 6) {
                            Text(category)
                                .font(.system(size: 12.5, weight: .medium))
                                .lineLimit(1)
                            Image(systemName: "chevron.up.chevron.down")
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 5)
                        .contentShape(Capsule())
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .glassCapsule()
                    .help("知识分类")
                    Text("\(records.count) 项")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                .padding(10)

                Divider()

                LearningSidebarSearchField(prompt: "搜索题目或知识", text: $searchText)
                    .padding(.horizontal, 10)
                    .padding(.top, 10)
                    .padding(.bottom, 12)

                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 2) {
                            ForEach(records) { record in
                                Button {
                                    selectedID = record.id
                                } label: {
                                    HStack(spacing: 10) {
                                        Circle()
                                            .fill(learningMasteryColor(record.effectiveMastery()))
                                            .frame(width: 7, height: 7)
                                        VStack(alignment: .leading, spacing: 4) {
                                            Text(record.title)
                                                .font(.subheadline.weight(.medium))
                                                .lineLimit(1)
                                            HStack(spacing: 5) {
                                                Text(record.primaryKnowledge).lineLimit(1)
                                                Spacer(minLength: 3)
                                                Text("\(Int(record.effectiveMastery()))")
                                                    .monospacedDigit()
                                            }
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                        }
                                        Spacer(minLength: 0)
                                    }
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 9)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .background(
                                        selectedID == record.id ? Color.primary.opacity(0.07) : .clear,
                                        in: RoundedRectangle(cornerRadius: 9, style: .continuous)
                                    )
                                    .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                                }
                                .buttonStyle(.plain)
                                .id(record.id)
                            }
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 6)
                    }
                    .floatingScrollIndicators()
                    // 列表这一帧可能刚因为清筛选而重建，等它铺完再滚；
                    // 用 task(id:) 而不是 onChange，是因为 onAppear 期间设的目标不会触发 onChange。
                    .task(id: pendingScrollTarget) {
                        guard let target = pendingScrollTarget else { return }
                        try? await Task.sleep(for: .milliseconds(80))
                        guard !Task.isCancelled else { return }
                        withAnimation(AppDesign.Motion.selection) {
                            proxy.scrollTo(target, anchor: .center)
                        }
                        pendingScrollTarget = nil
                    }
                }
            }
            .frame(minWidth: 250, idealWidth: 300, maxWidth: 360)
            .background(AppDesign.ColorToken.canvas)

            if let record = selectedRecord {
                LearningRecordDetailView(record: record, workspace: workspace, dataStore: dataStore)
                    .frame(minWidth: 500, maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ContentUnavailableView("没有符合条件的学习项", systemImage: "books.vertical")
            }
        }
        .onAppear {
            // 先认外部带过来的目标，再退回默认选中第一条。
            // 原来无条件 `selectedID = records.first?.id`，从洞察页点进来的目标当场被覆盖。
            adoptExternalSelection()
            if selectedID == nil { selectedID = records.first?.id }
        }
        .onChange(of: workspace.selectedLearningRecordID) { _, _ in
            adoptExternalSelection()
        }
        // 再点一次同一道题时 selectedLearningRecordID 没变，上面那条不会触发；
        // 视图又是常驻的（onAppear 也不再走），所以按"进入本页"这个事件补一次。
        .onChange(of: workspace.selectedSection) { _, section in
            if section == .library { adoptExternalSelection() }
        }
        .onChange(of: selectedID) { _, newValue in
            // 本地选中也要写回：其它页面（开始练习、新建任务的关联项）读的是这个。
            if let newValue, workspace.selectedLearningRecordID != newValue {
                workspace.selectedLearningRecordID = newValue
            }
        }
        .onChange(of: records.map(\.id)) { _, ids in
            if let selectedID, ids.contains(selectedID) { return }
            selectedID = ids.first
        }
    }
}

private struct LearningRecordDetailView: View {
    let record: LearningRecord
    @Bindable var workspace: WorkspaceState
    @Bindable var dataStore: LegacyDataStore

    @State private var problemLoadFailed = false
    @State private var problemHeight: CGFloat = 260
    @State private var expandedEvidenceID: String?
    @State private var submissionErrors: [String: String] = [:]

    /// 诊断与证据去重：有些证据的摘要与当前诊断完全重复
    private var visibleEvidence: [LearningEvidence] {
        record.evidence.filter { $0.summary != record.diagnosis }
    }

    private var leetCodeWorkspace: LeetCodeQuestionWorkspace? {
        record.leetCodeSlug.flatMap { dataStore.leetCodeWorkspaces[$0] }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(record.title)
                            .font(.system(size: 22, weight: .semibold))
                        Text(record.knowledgePath.joined(separator: "  ›  "))
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 2) {
                        Text("\(Int(record.effectiveMastery()))%")
                            .font(.system(size: 20, weight: .semibold).monospacedDigit())
                        // 显示的是按遗忘曲线折算后的"现在还剩多少"；
                        // 放久了它会自己往下走，不再是一个学会之后就冻住的数字。
                        Text(masteryCaption(record))
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.bottom, 20)

                ProgressView(value: record.effectiveMastery(), total: 100)
                    .tint(learningMasteryColor(record.effectiveMastery()))
                    .padding(.bottom, 26)

                detailSection(record.kind == "knowledge" ? "学习问题" : "题目内容") {
                    problemStatement
                }

                Divider().padding(.vertical, 22)

                detailSection("当前诊断") {
                    Text(record.diagnosis.isEmpty ? "等待更多学习证据" : record.diagnosis)
                        .font(.system(size: 14))
                        .foregroundStyle(.secondary)
                        .lineSpacing(5)
                    FlowLayout(spacing: 6) {
                        ForEach(record.labels, id: \.self) { label in
                            Text(label)
                                .font(.system(size: 12))
                                .padding(.horizontal, 9)
                                .padding(.vertical, 4)
                                .background(.quaternary, in: Capsule())
                        }
                    }
                }

                trajectoryAnalysisSection

                Divider().padding(.vertical, 22)

                detailSection("学习证据") {
                    if visibleEvidence.isEmpty {
                        Text("等待新的学习证据")
                            .font(AppDesign.Typography.body)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(visibleEvidence.prefix(8)) { evidence in
                            evidenceRow(evidence)
                        }
                    }
                }

                if !record.sourceRefs.isEmpty {
                    Divider().padding(.vertical, 22)
                    detailSection("原始提问快照") {
                        ForEach(record.sourceRefs.prefix(6)) { source in
                            Button {
                                workspace.selectedConversationID = source.conversationID
                                workspace.selectedSection = .conversation
                            } label: {
                                HStack(alignment: .top, spacing: 9) {
                                    Image(systemName: "arrow.up.right.square")
                                        .font(.system(size: 13))
                                        .foregroundStyle(.secondary)
                                    Text(source.excerpt)
                                        .font(.system(size: 13))
                                        .lineLimit(3)
                                        .multilineTextAlignment(.leading)
                                    Spacer(minLength: 0)
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .padding(.horizontal, 32)
            .padding(.vertical, 30)
            .frame(maxWidth: 760, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .floatingScrollIndicators()
        .safeAreaInset(edge: .bottom) {
            HStack(spacing: 8) {
                Spacer()
                // 联动是双向的：脑图能跳到这里，这里也要能跳回脑图并定位到这个节点。
                Button {
                    workspace.selectedLearningRecordID = record.id
                    workspace.selectedSection = .knowledge
                } label: {
                    Label("在脑图中查看", systemImage: "point.3.connected.trianglepath.dotted")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .glassCapsule()

                Button {
                    workspace.selectedLearningRecordID = record.id
                    workspace.selectedSection = .review
                } label: {
                    Label("开始练习", systemImage: "play.fill")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Color.accentColor)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .glassCapsule()
            }
            .padding(.horizontal, 16)
            .frame(height: 52)
            .background(.bar)
        }
    }

    private func detailSection<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - 题面

    /// 学习项本身只存了"力扣 1094 拼车"这种标题行；真正的题面复用刷题页那条链路
    /// （`fetchLeetCodeWorkspace` 带缓存 + `LeetCodeProblemWebView` 排版），不另起炉灶。
    @ViewBuilder
    private var problemStatement: some View {
        if let slug = record.leetCodeSlug {
            VStack(alignment: .leading, spacing: 10) {
                if let workspace = leetCodeWorkspace, !workspace.htmlContent.isEmpty {
                    if !workspace.difficulty.isEmpty || !workspace.topicTags.isEmpty {
                        HStack(spacing: 8) {
                            if !workspace.difficulty.isEmpty {
                                Text(difficultyTitle(workspace.difficulty))
                                    .font(AppDesign.Typography.micro.weight(.medium))
                                    .foregroundStyle(difficultyColor(workspace.difficulty))
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 3)
                                    .background(difficultyColor(workspace.difficulty).opacity(0.12), in: Capsule())
                            }
                            ForEach(workspace.topicTags.prefix(4), id: \.self) { tag in
                                Text(tag)
                                    .font(AppDesign.Typography.micro)
                                    .foregroundStyle(.secondary)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 3)
                                    .background(Color.primary.opacity(0.05), in: Capsule())
                            }
                            Spacer(minLength: 0)
                        }
                    }
                    // 高度跟着内容走：题面不自带滚动，整页只有一个滚动方向，
                    // 鼠标停在题面上滚动时不会被这块 WebView 吞掉。
                    LeetCodeProblemWebView(
                        html: workspace.htmlContent,
                        bottomPadding: 16,
                        onHeightChange: { problemHeight = $0 }
                    )
                    .frame(height: max(120, problemHeight))
                    .clipShape(RoundedRectangle(cornerRadius: AppDesign.Radius.card, style: .continuous))
                    .background(Color.primary.opacity(0.025), in: RoundedRectangle(cornerRadius: AppDesign.Radius.card, style: .continuous))
                } else if problemLoadFailed {
                    Text(record.question.isEmpty ? record.title : record.question)
                        .font(.system(size: 14))
                        .lineSpacing(5)
                        .textSelection(.enabled)
                    Text("题面未能加载，可能是未登录力扣或网络不可用")
                        .font(AppDesign.Typography.micro)
                        .foregroundStyle(.tertiary)
                } else {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("正在读取题面…")
                            .font(AppDesign.Typography.aux)
                            .foregroundStyle(.secondary)
                    }
                    .frame(height: 60)
                }
            }
            .task(id: slug) {
                guard dataStore.leetCodeWorkspaces[slug] == nil else { return }
                problemLoadFailed = false
                do {
                    _ = try await dataStore.fetchLeetCodeWorkspace(slug)
                } catch {
                    problemLoadFailed = true
                }
            }
        } else {
            Text(record.question.isEmpty ? record.title : record.question)
                .font(.system(size: 14))
                .lineSpacing(5)
                .textSelection(.enabled)
        }
    }

    // MARK: - 证据

    @ViewBuilder
    private func evidenceRow(_ evidence: LearningEvidence) -> some View {
        let submissionID = evidence.leetCodeSubmissionID
        let isExpanded = expandedEvidenceID == evidence.id
        VStack(alignment: .leading, spacing: 8) {
            Button {
                guard submissionID != nil else { return }
                expandedEvidenceID = isExpanded ? nil : evidence.id
            } label: {
                HStack(alignment: .top, spacing: 10) {
                    Circle()
                        .fill(evidence.signal == "positive" || evidence.signal == "demonstrated" ? .green : .blue)
                        .frame(width: 7, height: 7)
                        .padding(.top, 6)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(evidence.summary)
                            .font(AppDesign.Typography.body)
                            .lineSpacing(3)
                            .multilineTextAlignment(.leading)
                        Text(evidence.observedAt, style: .date)
                            .font(AppDesign.Typography.micro)
                            .foregroundStyle(.tertiary)
                    }
                    Spacer(minLength: 0)
                    if submissionID != nil {
                        Image(systemName: "chevron.right")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.tertiary)
                            .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(submissionID == nil)

            if isExpanded, let submissionID {
                submissionCode(submissionID)
            }
        }
        .padding(.vertical, 2)
        .animation(AppDesign.Motion.subtle, value: isExpanded)
    }

    /// 展开即拉取，用的是刷题页同一个带缓存的 `fetchLeetCodeSubmissionDetail`。
    @ViewBuilder
    private func submissionCode(_ submissionID: String) -> some View {
        if let detail = dataStore.leetCodeSubmissionDetails[submissionID] {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 10) {
                    Text(detail.status)
                        .font(AppDesign.Typography.micro.weight(.medium))
                        .foregroundStyle(detail.status.localizedCaseInsensitiveContains("accepted") ? .green : .orange)
                    if !detail.runtime.isEmpty {
                        Text("耗时 \(detail.runtime)").font(AppDesign.Typography.micro).foregroundStyle(.secondary)
                    }
                    if !detail.memory.isEmpty {
                        Text("内存 \(detail.memory)").font(AppDesign.Typography.micro).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                }
                // 不限高：代码整段铺开，页面只有一个竖向滚动，滚轮不会被代码块截走。
                SyntaxHighlightedCodeView(code: detail.code, language: detail.language)
                if let analysis = submissionAnalysis(for: submissionID) {
                    submissionAnalysisView(analysis)
                }
            }
            .padding(.leading, 17)
        } else if let message = submissionErrors[submissionID] {
            Text(message)
                .font(AppDesign.Typography.micro)
                .foregroundStyle(.secondary)
                .padding(.leading, 17)
        } else {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("正在读取提交代码…")
                    .font(AppDesign.Typography.micro)
                    .foregroundStyle(.secondary)
            }
            .padding(.leading, 17)
            .task(id: submissionID) {
                submissionErrors[submissionID] = nil
                do {
                    _ = try await dataStore.fetchLeetCodeSubmissionDetail(submissionID)
                } catch {
                    submissionErrors[submissionID] = "提交代码读取失败：\(error.localizedDescription)"
                }
            }
        }
    }

    // MARK: - 已有的 AI 分析

    private var trajectoryAnalysis: LeetCodeTrajectoryAnalysis? {
        record.leetCodeSlug.flatMap { dataStore.leetCodeAnalyses[$0] }
    }

    /// 这条提交此前跑过的 AI 分析，直接取分析队列存下来的结果，不重新调模型。
    private func submissionAnalysis(for submissionID: String) -> LeetCodeSubmissionAnalysis? {
        trajectoryAnalysis?.submissionAnalyses[submissionID]
    }

    private func submissionAnalysisView(_ analysis: LeetCodeSubmissionAnalysis) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("AI 分析", systemImage: "sparkles")
                .font(AppDesign.Typography.micro.weight(.medium))
                .foregroundStyle(.secondary)
            if !analysis.summary.isEmpty {
                Text(analysis.summary).font(AppDesign.Typography.aux).lineSpacing(3)
            }
            if !analysis.rootCause.isEmpty {
                Text("根因：\(analysis.rootCause)")
                    .font(AppDesign.Typography.aux)
                    .foregroundStyle(.secondary)
                    .lineSpacing(3)
            }
            ForEach(analysis.suggestions.prefix(3), id: \.self) { suggestion in
                Label(suggestion, systemImage: "arrow.right")
                    .font(AppDesign.Typography.micro)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.accentColor.opacity(0.05), in: RoundedRectangle(cornerRadius: AppDesign.Radius.medium, style: .continuous))
    }

    /// 力扣分析的 summary 会被 `mergeLeetCodeAnalysis` 直接抄进 `diagnosis`，
    /// 两个区块原样各印一遍，同一段话在一屏里出现两次。诊断留在上面（它是"当前状态"），
    /// 这里只在真的不一样时才展开——与 `visibleEvidence` 的去重口径一致。
    private var duplicatesDiagnosis: Bool {
        guard let summary = trajectoryAnalysis?.summary else { return false }
        return Self.normalized(summary) == Self.normalized(record.diagnosis)
    }

    private static func normalized(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\\s+", with: "", options: .regularExpression)
    }

    /// 整题维度的 AI 分析（薄弱点 / 下一步 / 每次尝试的变化），刷题页分析队列已经算过。
    @ViewBuilder
    private var trajectoryAnalysisSection: some View {
        if let analysis = trajectoryAnalysis,
           (!analysis.summary.isEmpty && !duplicatesDiagnosis)
               || !analysis.weaknesses.isEmpty
               || !analysis.improvements.isEmpty
               || !analysis.attemptInsights.isEmpty {
            Divider().padding(.vertical, 22)
            detailSection("AI 解题分析") {
                if !analysis.summary.isEmpty, !duplicatesDiagnosis {
                    Text(analysis.summary)
                        .font(.system(size: 14))
                        .lineSpacing(6)
                        .textSelection(.enabled)
                }
                // 「待巩固」「下一步」并排：两栏都是短句列表，竖着堆会把「每次尝试」推到屏外。
                if !analysis.weaknesses.isEmpty || !analysis.improvements.isEmpty {
                    HStack(alignment: .top, spacing: 14) {
                        if !analysis.weaknesses.isEmpty {
                            analysisList("待巩固", values: analysis.weaknesses, tint: .orange)
                        }
                        if !analysis.improvements.isEmpty {
                            analysisList("下一步", values: analysis.improvements, tint: .blue)
                        }
                    }
                    .fixedSize(horizontal: false, vertical: true)
                }
                if !analysis.attemptInsights.isEmpty {
                    attemptTimeline(analysis.attemptInsights)
                }
                Text("分析更新于 \(analysis.updatedAt.formatted(date: .abbreviated, time: .shortened))")
                    .font(AppDesign.Typography.micro)
                    .foregroundStyle(.tertiary)
                    .padding(.top, 2)
            }
        }
    }

    private func analysisList(_ title: String, values: [String], tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(AppDesign.Typography.auxEmphasis)
                .foregroundStyle(tint)
            ForEach(values.prefix(4), id: \.self) { value in
                HStack(alignment: .top, spacing: 8) {
                    Circle().fill(tint.opacity(0.6)).frame(width: 5, height: 5).padding(.top, 6)
                    Text(value)
                        .font(AppDesign.Typography.body)
                        .lineSpacing(4)
                        .textSelection(.enabled)
                    Spacer(minLength: 0)
                }
            }
        }
        .padding(11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tint.opacity(0.06), in: RoundedRectangle(cornerRadius: AppDesign.Radius.medium, style: .continuous))
    }

    /// 每次尝试是一条时间线：序号在左边一列对齐，issue 是标题，改动/结果是从属行。
    /// 原来三行同级、字号还一路降到 11pt 的 `.tertiary`，四次提交连成一片灰字读不出边界。
    private func attemptTimeline(_ insights: [LeetCodeAttemptInsight]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("每次尝试")
                .font(AppDesign.Typography.auxEmphasis)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(insights.prefix(5).enumerated()), id: \.element.submissionID) { index, insight in
                    if index > 0 {
                        Divider().padding(.leading, 30).padding(.vertical, 10)
                    }
                    attemptRow(index: index, insight: insight)
                }
            }
        }
    }

    private func attemptRow(index: Int, insight: LeetCodeAttemptInsight) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text("\(index + 1)")
                .font(AppDesign.Typography.micro.weight(.semibold).monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 20, height: 20)
                .background(.quaternary, in: Circle())
            VStack(alignment: .leading, spacing: 5) {
                if !insight.issue.isEmpty {
                    Text(insight.issue)
                        .font(AppDesign.Typography.body)
                        .lineSpacing(4)
                        .textSelection(.enabled)
                }
                if !insight.change.isEmpty {
                    attemptDetail("改动", value: insight.change, tint: .secondary)
                }
                if !insight.outcome.isEmpty {
                    attemptDetail("结果", value: insight.outcome, tint: Self.verdictStyle(insight.outcome))
                }
            }
            Spacer(minLength: 0)
        }
    }

    private func attemptDetail(_ label: String, value: String, tint: some ShapeStyle) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(label)
                .font(AppDesign.Typography.micro)
                .foregroundStyle(.tertiary)
                .frame(width: 24, alignment: .leading)
            Text(value)
                .font(AppDesign.Typography.aux)
                .foregroundStyle(tint)
                .lineSpacing(3)
                .textSelection(.enabled)
            Spacer(minLength: 0)
        }
    }

    /// 判定词决定这一行的颜色。只看第一个分句——整句里的"通过 4/93"是用例数，
    /// 拿它判成功会把每一次 Wrong Answer 都染成绿色。
    private static func verdictStyle(_ outcome: String) -> AnyShapeStyle {
        let verdict = outcome
            .prefix(while: { !"，,。;；:：(（".contains($0) })
            .trimmingCharacters(in: .whitespaces)
            .lowercased()
        if verdict.contains("accepted") || verdict.contains("通过") { return AnyShapeStyle(Color.green) }
        if verdict.isEmpty { return AnyShapeStyle(HierarchicalShapeStyle.secondary) }
        return AnyShapeStyle(Color.orange)
    }

    private func difficultyTitle(_ value: String) -> String {
        switch value.uppercased() { case "EASY": "简单"; case "HARD": "困难"; case "MEDIUM": "中等"; default: value }
    }

    private func difficultyColor(_ value: String) -> Color {
        switch value.uppercased() { case "EASY": .green; case "HARD": .red; default: .orange }
    }
}

struct LearningInsightsWorkspaceView: View {
    @Bindable var workspace: WorkspaceState
    @Bindable var dataStore: LegacyDataStore

    private var records: [LearningRecord] { dataStore.learningRecords }
    private var focus: [LearningRecord] { LearningInsights.focus(records: dataStore.activeLearningRecords) }
    private var topics: [LearningInsights.TopicStat] { LearningInsights.topics(records: records) }
    private var forecast: [LearningInsights.DueBucket] { LearningInsights.dueForecast(records: records) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AppDesign.Spacing.rowInset) {
                header

                if records.isEmpty {
                    ContentUnavailableView(
                        "还没有可分析的学习项",
                        systemImage: "chart.line.uptrend.xyaxis",
                        description: Text("在对话里讨论题目、或在刷题页提交代码后，学习项会自动沉淀到这里。")
                    )
                    .frame(maxWidth: .infinity, minHeight: 320)
                } else {
                    metricStrip

                    // 两列等高：不给 maxHeight 的话短的那张卡会缩成一半，
                    // 和右边的长卡片底边对不齐。
                    HStack(alignment: .top, spacing: AppDesign.Spacing.rowInset) {
                        focusCard
                        topicCard
                    }
                    .fixedSize(horizontal: false, vertical: true)

                    forecastCard
                }
            }
            .padding(.horizontal, AppDesign.Spacing.lg)
            .padding(.vertical, AppDesign.Spacing.lg)
            .frame(maxWidth: 1_120, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .floatingScrollIndicators()
        .background(AppDesign.ColorToken.canvas)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("学习洞察")
                .font(AppDesign.Typography.pageTitle)
            Text("按掌握度、FSRS 到期时间与证据可信度统计，排序口径与「今日复习」一致")
                .font(AppDesign.Typography.aux)
                .foregroundStyle(.secondary)
        }
        .padding(.bottom, AppDesign.Spacing.xxs)
    }

    // MARK: - 概览

    private var metricStrip: some View {
        HStack(alignment: .top, spacing: AppDesign.Spacing.sm) {
            metric("学习项", value: records.count, detail: "累计沉淀", icon: "books.vertical", tint: .accentColor)
            metric(
                "已到期",
                value: dataStore.dueCount,
                detail: dataStore.dueCount == 0 ? "进度正常" : "需要尽快复习",
                icon: "clock.badge.exclamationmark",
                tint: dataStore.dueCount == 0 ? .secondary : .orange
            )
            metric(
                "待巩固",
                value: dataStore.weakCount,
                detail: "掌握度低于 \(Int(LearningInsights.weakThreshold))",
                icon: "exclamationmark.triangle",
                tint: dataStore.weakCount == 0 ? .secondary : .pink
            )
            metric(
                "证据",
                value: records.reduce(0) { $0 + $1.evidenceCount },
                detail: "对话与提交记录",
                icon: "doc.text.magnifyingglass",
                tint: .green
            )
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private func metric(_ title: String, value: Int, detail: String, icon: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(AppDesign.Typography.iconCompact)
                    .foregroundStyle(tint)
                Text(title).font(AppDesign.Typography.aux).foregroundStyle(.secondary)
            }
            Text("\(value)").font(AppDesign.Typography.metricValue)
            Text(detail)
                .font(AppDesign.Typography.micro)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
        }
        .padding(AppDesign.Spacing.md)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .inlineGlass(cornerRadius: AppDesign.Radius.floating)
    }

    // MARK: - 优先巩固

    private var focusCard: some View {
        insightCard("优先巩固", systemImage: "scope", tint: .orange, hint: "逾期越久、掌握越差越靠前") {
            if focus.isEmpty {
                emptyLine("没有待巩固的学习项")
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(focus.enumerated()), id: \.element.id) { index, record in
                        Button {
                            workspace.selectedLearningRecordID = record.id
                            workspace.selectedSection = .library
                        } label: {
                            focusRow(record)
                        }
                        .buttonStyle(.plain)
                        if index != focus.count - 1 {
                            Divider().padding(.leading, 22)
                        }
                    }
                }
            }
        }
    }

    private func focusRow(_ record: LearningRecord) -> some View {
        HStack(spacing: AppDesign.Spacing.compact) {
            Circle()
                .fill(learningMasteryColor(record.effectiveMastery()))
                .frame(width: 7, height: 7)

            VStack(alignment: .leading, spacing: 2) {
                Text(record.title)
                    .font(AppDesign.Typography.bodyEmphasis)
                    .lineLimit(1)
                HStack(spacing: 6) {
                    Text(record.primaryKnowledge)
                        .font(AppDesign.Typography.micro)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Text(LearningReviewSchedule.reason(for: record))
                        .font(AppDesign.Typography.micro)
                        .foregroundStyle(reasonTint(record))
                }
            }

            Spacer(minLength: AppDesign.Spacing.xs)

            Text("\(Int(record.effectiveMastery().rounded()))")
                .font(AppDesign.Typography.auxEmphasis.monospacedDigit())
                .foregroundStyle(learningMasteryColor(record.effectiveMastery()))
            Text("分")
                .font(AppDesign.Typography.micro)
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 9)
        .contentShape(Rectangle())
    }

    private func reasonTint(_ record: LearningRecord) -> Color {
        let reason = LearningReviewSchedule.reason(for: record)
        if reason.hasPrefix("逾期") { return .orange }
        if reason == "新知识" { return .accentColor }
        return .secondary
    }

    // MARK: - 知识分布

    private var topicCard: some View {
        insightCard("知识分布", systemImage: "chart.bar.xaxis", tint: .accentColor, hint: "最薄弱的主题排在最前") {
            if topics.isEmpty {
                emptyLine("还没有可统计的主题")
            } else {
                VStack(spacing: AppDesign.Spacing.compact) {
                    ForEach(topics.prefix(8)) { topic in
                        topicRow(topic)
                    }
                }
            }
        }
    }

    private func topicRow(_ topic: LearningInsights.TopicStat) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Text(topic.name)
                    .font(AppDesign.Typography.bodyEmphasis)
                    .lineLimit(1)
                if topic.overdueCount > 0 {
                    Text("逾期 \(topic.overdueCount)")
                        .font(AppDesign.Typography.micro)
                        .foregroundStyle(.orange)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Color.orange.opacity(0.12), in: Capsule())
                }
                Spacer(minLength: AppDesign.Spacing.xs)
                Text("\(Int(topic.averageMastery.rounded()))")
                    .font(AppDesign.Typography.auxEmphasis.monospacedDigit())
                    .foregroundStyle(learningMasteryColor(topic.averageMastery))
                Text("· \(topic.count) 项")
                    .font(AppDesign.Typography.micro)
                    .foregroundStyle(.tertiary)
            }

            // 自绘而不是 ProgressView：系统进度条在紧凑列表里高度不可控，
            // 也没法把"薄弱项占比"叠上去。
            GeometryReader { proxy in
                let width = proxy.size.width
                let ratio = min(max(topic.averageMastery / 100, 0), 1)
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.06))
                    Capsule()
                        .fill(learningMasteryColor(topic.averageMastery))
                        .frame(width: max(3, width * ratio))
                }
            }
            .frame(height: 4)
        }
    }

    // MARK: - 到期分布

    private var forecastCard: some View {
        insightCard(
            "未来 7 天到期",
            systemImage: "calendar",
            tint: .teal,
            hint: "逾期项计入今天——它们是今天的欠账"
        ) {
            let peak = max(1, forecast.map(\.count).max() ?? 1)
            HStack(alignment: .bottom, spacing: AppDesign.Spacing.xs) {
                ForEach(forecast) { bucket in
                    VStack(spacing: 6) {
                        Text(bucket.count == 0 ? " " : "\(bucket.count)")
                            .font(AppDesign.Typography.micro.monospacedDigit())
                            .foregroundStyle(.secondary)
                        if bucket.count == 0 {
                            Capsule()
                                .fill(Color.accentColor.opacity(0.22))
                                .frame(height: 3)
                        } else {
                            RoundedRectangle(cornerRadius: 5, style: .continuous)
                                .fill(forecastBarFill(bucket))
                                .frame(maxWidth: 30)
                                .frame(height: max(6, 72 * CGFloat(bucket.count) / CGFloat(peak)))
                        }
                        Text(bucket.day, format: .dateTime.month(.defaultDigits).day())
                            .font(AppDesign.Typography.micro)
                            .foregroundStyle(Calendar.current.isDateInToday(bucket.day) ? .primary : .tertiary)
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            .frame(height: 108, alignment: .bottom)
        }
    }

    private func forecastBarFill(_ bucket: LearningInsights.DueBucket) -> LinearGradient {
        bucket.includesOverdue
            ? LinearGradient(colors: [.orange.opacity(0.9), .orange.opacity(0.55)], startPoint: .top, endPoint: .bottom)
            : LinearGradient(colors: [Color.accentColor.opacity(0.75), Color.accentColor.opacity(0.45)], startPoint: .top, endPoint: .bottom)
    }

    // MARK: - 通用容器

    private func insightCard<Content: View>(
        _ title: String,
        systemImage: String,
        tint: Color,
        hint: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: AppDesign.Spacing.compact) {
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                Image(systemName: systemImage)
                    .font(AppDesign.Typography.iconCompact)
                    .foregroundStyle(tint)
                Text(title).font(AppDesign.Typography.sectionTitle)
                Spacer(minLength: AppDesign.Spacing.xs)
                Text(hint)
                    .font(AppDesign.Typography.micro)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
            content()
        }
        .padding(AppDesign.Spacing.md)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .inlineGlass(cornerRadius: AppDesign.Radius.floating)
    }

    private func emptyLine(_ text: String) -> some View {
        Text(text)
            .font(AppDesign.Typography.aux)
            .foregroundStyle(.tertiary)
            .frame(maxWidth: .infinity, minHeight: 60)
    }
}

struct LearningTemplatesWorkspaceView: View {
    @Bindable var workspace: WorkspaceState
    @Bindable var dataStore: LegacyDataStore
    @State private var selectedID: String?
    @State private var searchText = ""

    private var templates: [LearningTemplate] {
        searchText.isEmpty ? dataStore.learningTemplates : dataStore.learningTemplates.filter {
            $0.title.localizedCaseInsensitiveContains(searchText) || $0.summary.localizedCaseInsensitiveContains(searchText)
        }
    }

    private var selectedTemplate: LearningTemplate? {
        dataStore.learningTemplates.first { $0.id == selectedID } ?? templates.first
    }

    var body: some View {
        // 不用 HSplitView：它给每个 pane 画不透明底，圆角卡外面会套出直角矩形。
        HStack(alignment: .top, spacing: AppDesign.Spacing.sm) {
            templateSidebar
                .frame(minWidth: 268, maxWidth: 268, maxHeight: .infinity)

            if let template = selectedTemplate {
                templateDetail(template)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ContentUnavailableView(
                    searchText.isEmpty ? "暂无算法模板" : "没有匹配的模板",
                    systemImage: "doc.on.doc",
                    description: Text(searchText.isEmpty
                        ? "模板会在学习项积累到一定程度后自动生成。"
                        : "换个关键词试试。")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .padding(AppDesign.Spacing.sm)
        .background(AppDesign.ColorToken.canvas)
        .onAppear {
            selectedID = selectedID ?? templates.first?.id
        }
        .onChange(of: templates.map(\.id)) { _, ids in
            if let selectedID, ids.contains(selectedID) { return }
            selectedID = ids.first
        }
    }

    private var templateSidebar: some View {
        VStack(spacing: 0) {
            LearningSidebarSearchField(prompt: "搜索模板", text: $searchText)
                .padding(.horizontal, AppDesign.Spacing.compact)
                .padding(.top, AppDesign.Spacing.compact)
                .padding(.bottom, AppDesign.Spacing.xs)

            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(templates) { template in
                        Button {
                            selectedID = template.id
                        } label: {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(template.title)
                                    .font(AppDesign.Typography.bodyEmphasis)
                                    .lineLimit(1)
                                HStack(spacing: 6) {
                                    Text(template.path.last ?? template.language)
                                        .lineLimit(1)
                                    Spacer(minLength: AppDesign.Spacing.xxs)
                                    Text("\(template.itemCount) 项")
                                        .monospacedDigit()
                                }
                                .font(AppDesign.Typography.micro)
                                .foregroundStyle(.secondary)
                            }
                            .padding(.horizontal, AppDesign.Spacing.compact)
                            .padding(.vertical, 8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(
                                selectionBackground(isSelected: selectedTemplate?.id == template.id),
                                in: RoundedRectangle(cornerRadius: AppDesign.Radius.medium, style: .continuous)
                            )
                            // 未选中时底色是 clear，透明区不参与命中测试，
                            // 不补 contentShape 就只有文字几个像素能点。
                            .contentShape(RoundedRectangle(cornerRadius: AppDesign.Radius.medium, style: .continuous))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 6)
                .padding(.bottom, AppDesign.Spacing.xs)
            }
            .floatingScrollIndicators()
        }
        .navigationGlass(cornerRadius: AppDesign.Radius.floating)
    }

    private func templateDetail(_ template: LearningTemplate) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AppDesign.Spacing.rowInset) {
                templateHeader(template)

                // 宽窗口分两栏：左边是"怎么想"（时机 / 步骤 / 陷阱），右边是"怎么写"（代码）。
                // 原来单栏 860pt 封顶，右侧永远空一大片，代码又被挤在窄条里。
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: AppDesign.Spacing.sm) {
                        VStack(alignment: .leading, spacing: AppDesign.Spacing.sm) {
                            reasoningSections(template)
                        }
                        .frame(width: 340, alignment: .topLeading)

                        codeSection(template)
                            .frame(maxWidth: .infinity, alignment: .topLeading)
                    }

                    VStack(alignment: .leading, spacing: AppDesign.Spacing.sm) {
                        reasoningSections(template)
                        codeSection(template)
                    }
                }
            }
            .padding(AppDesign.Spacing.md)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .floatingScrollIndicators()
        .navigationGlass(cornerRadius: AppDesign.Radius.floating)
    }

    @ViewBuilder
    private func reasoningSections(_ template: LearningTemplate) -> some View {
        if !template.applicableWhen.isEmpty {
            templateSection("适用时机", systemImage: "target", tint: .accentColor) {
                VStack(alignment: .leading, spacing: 7) {
                    ForEach(Array(template.applicableWhen.enumerated()), id: \.offset) { _, value in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Image(systemName: "checkmark")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(Color.accentColor)
                                .frame(width: 12)
                            Text(value)
                                .font(AppDesign.Typography.body)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
        }

        if !template.steps.isEmpty {
            templateSection("实现步骤", systemImage: "list.number", tint: .teal) {
                // 用真实序号，不再每行重复同一个 list.number 图标。
                VStack(alignment: .leading, spacing: 9) {
                    ForEach(Array(template.steps.enumerated()), id: \.offset) { index, value in
                        HStack(alignment: .firstTextBaseline, spacing: 9) {
                            Text("\(index + 1)")
                                .font(AppDesign.Typography.micro.monospacedDigit().weight(.semibold))
                                .foregroundStyle(.secondary)
                                .frame(width: 17, height: 17)
                                .background(Color.primary.opacity(0.06), in: Circle())
                            Text(value)
                                .font(AppDesign.Typography.body)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
        }

        if !template.pitfalls.isEmpty {
            templateSection("常见陷阱", systemImage: "exclamationmark.triangle", tint: .orange) {
                VStack(alignment: .leading, spacing: 7) {
                    ForEach(Array(template.pitfalls.enumerated()), id: \.offset) { _, value in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Circle()
                                .fill(Color.orange.opacity(0.55))
                                .frame(width: 5, height: 5)
                                .frame(width: 12)
                            Text(value)
                                .font(AppDesign.Typography.body)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
        }
    }

    private func codeSection(_ template: LearningTemplate) -> some View {
        // 代码块自带头部与圆角底，再套一层 section 卡就是三层嵌套盒。
        // 标题行裸排，代码块直接贴上去，少一层。
        VStack(alignment: .leading, spacing: AppDesign.Spacing.xs) {
            HStack(spacing: 6) {
                Image(systemName: "chevron.left.forwardslash.chevron.right")
                    .font(AppDesign.Typography.iconCompact)
                    .foregroundStyle(.purple)
                Text("参考实现").font(AppDesign.Typography.rowTitleEmphasis)
            }
            SyntaxHighlightedCodeView(code: template.code, language: template.language)
        }
        .padding(AppDesign.Spacing.rowInset)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func templateHeader(_ template: LearningTemplate) -> some View {
        VStack(alignment: .leading, spacing: AppDesign.Spacing.xs) {
            HStack(alignment: .top, spacing: AppDesign.Spacing.compact) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(template.title).font(AppDesign.Typography.pageTitle)
                    HStack(spacing: 6) {
                        Text(template.path.joined(separator: "  ›  "))
                            .font(AppDesign.Typography.micro)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        Text(template.language.uppercased())
                            .font(AppDesign.Typography.micro.weight(.medium))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Color.primary.opacity(0.06), in: Capsule())
                    }
                }
                // 这里原来还有个"复制代码"按钮：多余的，
                // SyntaxHighlightedCodeView 自己的头部就带复制。
                Spacer(minLength: AppDesign.Spacing.xs)
            }

            if !template.summary.isEmpty {
                Text(template.summary)
                    .font(AppDesign.Typography.body)
                    .foregroundStyle(.secondary)
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func templateSection<Content: View>(
        _ title: String,
        systemImage: String,
        tint: Color,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: AppDesign.Spacing.xs) {
            HStack(spacing: 6) {
                Image(systemName: systemImage)
                    .font(AppDesign.Typography.iconCompact)
                    .foregroundStyle(tint)
                Text(title).font(AppDesign.Typography.rowTitleEmphasis)
            }
            content()
        }
        .padding(AppDesign.Spacing.rowInset)
        .frame(maxWidth: .infinity, alignment: .leading)
        // 每段独立成卡，页面才有结构；原来所有小节堆在一张白底上，读起来是一篇长文档。
        .background(
            Color.primary.opacity(0.022),
            in: RoundedRectangle(cornerRadius: AppDesign.Radius.card, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: AppDesign.Radius.card, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.055))
        }
    }

}

private struct LearningSidebarSearchField: View {
    let prompt: String
    @Binding var text: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)
            TextField(prompt, text: $text)
                .textFieldStyle(.plain)
            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .help("清除搜索")
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 36)
        .background(Color.primary.opacity(0.025), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.09))
        }
    }
}

private func selectionBackground(isSelected: Bool) -> Color {
    isSelected ? Color(nsColor: .unemphasizedSelectedContentBackgroundColor) : .clear
}

struct LearningTrashWorkspaceView: View {
    @Bindable var dataStore: LegacyDataStore
    @State private var showsEmptyConfirmation = false
    @State private var pendingPurge: LearningRecord?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("回收站").font(.headline)
                    Text("删除的学习快照保留 30 天").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("清空", systemImage: "trash", role: .destructive) { showsEmptyConfirmation = true }
                    .disabled(dataStore.deletedLearningRecords.isEmpty)
            }
            .padding(.horizontal, 16)
            .frame(height: 54)
            Divider()
            if dataStore.deletedLearningRecords.isEmpty {
                ContentUnavailableView("回收站为空", systemImage: "trash", description: Text("删除的学习项会在这里保留 30 天"))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(dataStore.deletedLearningRecords) { record in
                    HStack {
                        VStack(alignment: .leading, spacing: 3) { Text(record.title); Text(record.primaryKnowledge).font(.caption).foregroundStyle(.secondary) }
                        Spacer()
                        Button("恢复") { Task { try? await dataStore.restoreLearningRecord(record.id) } }.controlSize(.small)
                        Button("彻底删除", role: .destructive) { pendingPurge = record }.controlSize(.small)
                    }
                    .padding(.vertical, 4)
                }
                .floatingScrollIndicators()
            }
        }
        .confirmationDialog("清空回收站？", isPresented: $showsEmptyConfirmation, titleVisibility: .visible) {
            Button("永久删除全部记录", role: .destructive) { Task { try? await dataStore.emptyLearningTrash() } }
            Button("取消", role: .cancel) { }
        } message: {
            Text("清空后无法恢复。")
        }
        .confirmationDialog(
            "永久删除这条学习记录？",
            isPresented: Binding(
                get: { pendingPurge != nil },
                set: { if !$0 { pendingPurge = nil } }
            ),
            titleVisibility: .visible,
            presenting: pendingPurge
        ) { record in
            Button("删除「\(record.title)」", role: .destructive) {
                Task { try? await dataStore.purgeLearningRecord(record.id) }
            }
            Button("取消", role: .cancel) { pendingPurge = nil }
        } message: { _ in
            Text("该操作无法撤销。")
        }
    }
}

/// 掌握度下面那行小字。放久了会多一句"记忆 x%"，
/// 说明这个百分比为什么比自己记得的那次低——是忘掉的，不是分数被改了。
private func masteryCaption(_ record: LearningRecord) -> String {
    guard let retention = record.retention() else { return "掌握度" }
    return "掌握度 · 记忆 \(Int((retention * 100).rounded()))%"
}

private func learningMasteryColor(_ score: Double) -> Color {
    switch score {
    case ..<40: AppDesign.ColorToken.warning
    case ..<70: .accentColor
    default: AppDesign.ColorToken.success
    }
}

/// 标签云换行布局。SwiftUI 没有内置的 flow container，
/// 知识点标签与力扣「优势专题」都用它，所以放在模块作用域共享。
struct FlowLayout: Layout {
    let spacing: CGFloat

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) -> CGSize {
        let width = proposal.width ?? .infinity
        var lineWidth: CGFloat = 0
        var lineHeight: CGFloat = 0
        var height: CGFloat = 0
        var maximumWidth: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if lineWidth > 0, lineWidth + spacing + size.width > width {
                maximumWidth = max(maximumWidth, lineWidth)
                height += lineHeight + spacing
                lineWidth = size.width
                lineHeight = size.height
            } else {
                lineWidth += (lineWidth > 0 ? spacing : 0) + size.width
                lineHeight = max(lineHeight, size.height)
            }
        }
        return CGSize(width: min(width, max(maximumWidth, lineWidth)), height: height + lineHeight)
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) {
        var x = bounds.minX
        var y = bounds.minY
        var lineHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                x = bounds.minX
                y += lineHeight + spacing
                lineHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
    }
}
