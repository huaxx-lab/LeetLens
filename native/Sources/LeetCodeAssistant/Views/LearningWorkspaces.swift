import AppKit
import SwiftUI


struct ReviewWorkspaceView: View {
    @Bindable var workspace: WorkspaceState
    @Bindable var dataStore: LegacyDataStore
    @Environment(\.colorScheme) private var colorScheme
    @State private var selectedID: String?
    @State private var answer = ""
    @State private var searchText = ""
    @State private var selectedChoice = ""
    @State private var isWorking = false
    @State private var learningError = ""
    @State private var answerDrafts: [String: String] = [:]
    @State private var practiceType = "auto"
    @State private var queueScope = QueueScope.today
    /// 从别处跳进来时要滚到的目标；滚完置空。
    @State private var pendingScrollTarget: String?
    @State private var answerDiagnostics = LeetCodeEditorDiagnostics()
    @State private var answerLoadStatus: LeetCodeEditorLoadStatus = .loading
    @State private var answerCompletionStatus: LeetCodeCompletionStatus = .localOnly
    @State private var answerFormatRequest = 0
    @State private var isSelfReviewing = false
    @State private var answerContentHeight: CGFloat = 0

    private static let codeExerciseTypes: Set<String> = ["coding", "code_completion"]

    private var currentDraftKey: String {
        guard let record = selectedRecord, record.activeStudyPackage != nil else { return "" }
        return "\(record.id):\(record.activeStudyPackage?.id ?? "")"
    }

    private func loadDraft(for key: String) {
        guard !key.isEmpty, let exercise = selectedRecord?.activeStudyPackage?.exercise else {
            answer = ""
            return
        }
        answer = answerDrafts[key]
            ?? (Self.codeExerciseTypes.contains(exercise.type) ? exercise.starterCode : "")
    }

    var body: some View {
        HSplitView {
            reviewQueue
                .frame(minWidth: 244, idealWidth: 276, maxWidth: 312)

            reviewDetail
                .frame(minWidth: 540, maxWidth: .infinity, maxHeight: .infinity)
        }
        .onAppear {
            adoptExternalSelection()
            if selectedID == nil { selectedID = filteredRecords.first?.id }
            loadDraft(for: currentDraftKey)
        }
        .onChange(of: workspace.selectedLearningRecordID) { _, _ in
            adoptExternalSelection()
        }
        // 再点一次同一项时 ID 没变、视图又常驻（onAppear 不再走），按"进入本页"补一次。
        .onChange(of: workspace.selectedSection) { _, section in
            if section == .review { adoptExternalSelection() }
        }
        .onChange(of: currentDraftKey) { oldKey, newKey in
            if !oldKey.isEmpty { answerDrafts[oldKey] = answer }
            selectedChoice = ""
            learningError = ""
            loadDraft(for: newKey)
        }
        .background(AppDesign.ColorToken.canvas)
    }

    /// 今日队列按「学习与复习」设置里的配额现算，逾期优先、熟练项沉底、新知识独立配额。
    /// 全部待复习仍然可以在"全部"里翻到，只是不再默认糊一屏。
    private var todayPlan: LearningReviewSchedule.Plan {
        LearningReviewSchedule.plan(
            records: dataStore.activeLearningRecords,
            settings: dataStore.learningSettings
        )
    }

    private var scopedRecords: [LearningRecord] {
        queueScope == .today ? todayPlan.queue : dataStore.activeLearningRecords
    }

    private var filteredRecords: [LearningRecord] {
        let records = scopedRecords
        guard !searchText.isEmpty else { return records }
        return records.filter {
            $0.title.localizedCaseInsensitiveContains(searchText)
                || $0.labels.contains { $0.localizedCaseInsensitiveContains(searchText) }
        }
    }

    private enum QueueScope: String, CaseIterable {
        case today
        case all
        var title: String { self == .today ? "今日" : "全部" }
    }

    private func reasonTint(_ record: LearningRecord) -> Color {
        record.dueAt < Calendar.current.startOfDay(for: .now) ? AppDesign.ColorToken.warning : .secondary
    }

    private var selectedRecord: LearningRecord? {
        let id = selectedID ?? workspace.selectedLearningRecordID
        return dataStore.learningRecords.first { $0.id == id } ?? filteredRecords.first
    }

    /// 外部（学习洞察、题库详情、学习计划）指定了目标就采纳，并把挡住它的筛选让开：
    /// 目标不在今日队列里就切到「全部」，被搜索过滤掉就清搜索——
    /// 否则右边讲的是那一项，左边队列里却找不到它，看着像没跳过去。
    private func adoptExternalSelection() {
        guard let target = workspace.selectedLearningRecordID,
              dataStore.activeLearningRecords.contains(where: { $0.id == target })
        else { return }
        if !filteredRecords.contains(where: { $0.id == target }) {
            if !todayPlan.queue.contains(where: { $0.id == target }) { queueScope = .all }
            searchText = ""
        }
        selectedID = target
        pendingScrollTarget = target
    }

    private var reviewQueue: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text("复习队列")
                    .font(.headline)
                Spacer(minLength: 8)
                GlassSegmentedControl(
                    options: QueueScope.allCases.map { ($0.rawValue, $0.title) },
                    selection: Binding(
                        get: { queueScope.rawValue },
                        set: { queueScope = QueueScope(rawValue: $0) ?? queueScope }
                    )
                )
                .frame(width: 108)
            }
            .padding(.horizontal, 12)
            .frame(height: 44)

            queueSummary
                .padding(.horizontal, 12)
                .padding(.bottom, 2)

            HStack(spacing: 7) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                TextField("搜索复习项", text: $searchText)
                    .textFieldStyle(.plain)
                if !searchText.isEmpty {
                    Button { searchText = "" } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 9)
            .frame(height: 30)
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .strokeBorder(.primary.opacity(0.07))
            }
            .padding(10)

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(filteredRecords) { record in
                            reviewQueueRow(record)
                                .id(record.id)
                        }
                    }
                    .padding(.horizontal, 7)
                    .padding(.bottom, 10)
                }
                .floatingScrollIndicators()
                // 队列这一帧可能刚因为切换范围而重建，等它铺完再滚；
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
        .background(AppDesign.ColorToken.canvas)
    }

    @ViewBuilder
    private var reviewDetail: some View {
        if let record = selectedRecord {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    reviewHeader(record)

                    reviewPrompt(record)

                    if !record.diagnosis.isEmpty {
                        diagnosis(record)
                    }

                    practiceTypeRow

                    if let package = record.activeStudyPackage {
                        lesson(
                            package.lesson,
                            language: package.exercise.language,
                            knowledgeTitle: record.primaryKnowledge
                        )
                        exercise(
                            package.exercise,
                            attemptCount: record.activePackageAttemptCount,
                            record: record
                        )
                        if let attempt = record.latestAttempt {
                            attemptResult(attempt)
                        }
                    } else if isWorking {
                        // 带 label 的 ProgressView 在 macOS 上会竖排（转圈压在文字上方且不对齐），
                        // 这里自己横排，并占住一块高度，避免正文与操作行之间出现大片空洞。
                        HStack(spacing: AppDesign.Spacing.compact) {
                            ProgressView()
                                .controlSize(.small)
                            Text("正在生成讲解与针对性检测…")
                                .font(AppDesign.Typography.body)
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, minHeight: 220)
                    } else {
                        generationPanel
                    }

                    if !learningError.isEmpty {
                        Label(learningError, systemImage: "exclamationmark.triangle")
                            .font(.callout)
                            .foregroundStyle(AppDesign.ColorToken.warning)
                    }

                    selfReviewBar(record)

                    HStack(spacing: AppDesign.Spacing.compact) {
                        Button("查看证据", systemImage: "doc.text.magnifyingglass") {
                            workspace.selectedLearningRecordID = record.id
                            workspace.presentTool(.evidence)
                        }
                        .buttonStyle(.borderless)
                        .foregroundStyle(.secondary)
                        .font(AppDesign.Typography.body)
                        Spacer()
                    }
                }
                .frame(maxWidth: 760, alignment: .leading)
                .padding(.horizontal, 32)
                .padding(.top, 28)
                .padding(.bottom, 56)
                .frame(maxWidth: .infinity)
            }
            .floatingScrollIndicators()
            .background(AppDesign.ColorToken.canvas)
        } else {
            ContentUnavailableView("今日复习已完成", systemImage: "checkmark.circle")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(AppDesign.ColorToken.canvas)
        }
    }

    private func reviewHeader(_ record: LearningRecord) -> some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 5) {
                Text(record.title)
                    .font(.title2.weight(.semibold))
                HStack(spacing: 8) {
                    Label(record.primaryKnowledge, systemImage: "scope")
                    Text("·")
                    Text("\(record.evidenceCount) 条证据")
                    Text("·")
                    Text("已复习 \(record.reviewCount) 次")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer()
            MasteryGauge(score: record.masteryScore)
        }
    }

    private func reviewPrompt(_ record: LearningRecord) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("本次复习")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(record.question.isEmpty ? record.title : record.question)
                .font(.title3.weight(.medium))
                .lineSpacing(4)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func diagnosis(_ record: LearningRecord) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Label("最近诊断", systemImage: "waveform.path.ecg")
                .font(.subheadline.weight(.semibold))
            Text(record.diagnosis)
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineSpacing(3)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.leading, 12)
        .overlay(alignment: .leading) {
            Rectangle().fill(AppDesign.ColorToken.warning).frame(width: 2)
        }
    }

    private func lesson(_ lesson: LearningLesson, language: String, knowledgeTitle: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("自适应讲解")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(knowledgeTitle)
                    .font(.headline)
                    .lineLimit(1)
                Spacer()
                // 脑图里的卡片直接读这份讲解（同一份数据），所以这里不是"导入"，
                // 只是把镜头挪过去——复制一份进脑图只会两边各存一套、各自过期。
                Button {
                    showLessonInGraph()
                } label: {
                    Image(systemName: "point.3.connected.trianglepath.dotted")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                        .frame(width: 26, height: 26)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .glassCircle()
                .help("在知识脑图里定位这道题")

                Button {
                    Task { await preparePackageIfNeeded(force: true) }
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                        .frame(width: 26, height: 26)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .glassCircle()
                .disabled(isWorking)
                .help("重新生成讲解与检测")
            }
            Text(lesson.overview)
                .lineSpacing(4)
            ForEach(lesson.keyPoints, id: \.self) { point in
                Label(point, systemImage: "checkmark.circle")
                    .font(.callout)
            }
            if !lesson.example.isEmpty {
                SyntaxHighlightedCodeView(
                    code: lesson.example,
                    language: language,
                    maxHeight: 260
                )
            }
            if !lesson.pitfalls.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("易错点")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    ForEach(lesson.pitfalls, id: \.self) { pitfall in
                        Label(pitfall, systemImage: "exclamationmark.circle")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(
                    AppDesign.ColorToken.warning.opacity(0.06),
                    in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                )
            }
        }
    }

    // MARK: - 自评复习

    /// FSRS 的四档评分。`dataStore.reviewLearningRecord` 早就接到了 `engine.reviewLearningItem`，
    /// 但全项目没有任何 UI 调它——排期只能被 AI 判卷驱动，用户没法自己说"这题我忘了"。
    private enum SelfReviewRating: Int, CaseIterable, Identifiable {
        case again = 1
        case hard = 2
        case good = 3
        case easy = 4

        var id: Int { rawValue }

        var title: String {
            switch self {
            case .again: "忘了"
            case .hard: "困难"
            case .good: "掌握"
            case .easy: "简单"
            }
        }

        var symbol: String {
            switch self {
            case .again: "arrow.counterclockwise"
            case .hard: "tortoise"
            case .good: "checkmark"
            case .easy: "hare"
            }
        }

        var tint: Color {
            switch self {
            case .again: AppDesign.ColorToken.warning
            case .hard: .orange
            case .good: .accentColor
            case .easy: AppDesign.ColorToken.success
            }
        }
    }

    private static let selfReviewDueFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "M月d日"
        return formatter
    }()

    private func selfReviewBar(_ record: LearningRecord) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("现在还记得吗")
                    .font(.system(size: 13, weight: .semibold))
                Text("评分直接决定下一次复习时间")
                    .font(AppDesign.Typography.micro)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 8)
                Text("下次 \(Self.selfReviewDueFormatter.string(from: record.dueAt))")
                    .font(AppDesign.Typography.micro.monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
            HStack(spacing: 8) {
                ForEach(SelfReviewRating.allCases) { rating in
                    Button {
                        Task { await applySelfReview(record, rating: rating) }
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: rating.symbol)
                                .font(.system(size: 11, weight: .semibold))
                            Text(rating.title)
                                .font(.system(size: 12.5, weight: .medium))
                        }
                        .foregroundStyle(rating.tint)
                        .frame(maxWidth: .infinity)
                        .frame(height: 30)
                        .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .background(rating.tint.opacity(0.10), in: Capsule())
                    .help("按 \(rating.title) 记一次复习")
                }
            }
            .disabled(isSelfReviewing)
            .opacity(isSelfReviewing ? 0.55 : 1)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .inlineGlass(cornerRadius: AppDesign.Radius.medium)
    }

    /// 去脑图里看这道题。讲解本身不用搬过去——脑图的卡片读的就是学习记录里
    /// 这一份学习包，重新生成一次两边一起变。
    private func showLessonInGraph() {
        guard let record = selectedRecord else { return }
        workspace.selectedLearningRecordID = record.id
        workspace.selectedSection = .knowledge
    }

    private func applySelfReview(_ record: LearningRecord, rating: SelfReviewRating) async {
        guard !isSelfReviewing else { return }
        isSelfReviewing = true
        learningError = ""
        defer { isSelfReviewing = false }
        do {
            try await dataStore.reviewLearningRecord(record.id, rating: rating.rawValue)
        } catch {
            learningError = error.localizedDescription
        }
    }

    private var practiceTypeRow: some View {
        HStack(spacing: 8) {
            Text("练习题型")
                .font(.caption)
                .foregroundStyle(.secondary)
            practiceTypePicker
                .frame(maxWidth: .infinity)
            Button {
                Task { await preparePackageIfNeeded(force: true) }
            } label: {
                Label(
                    selectedRecord?.activeStudyPackage == nil ? "生成讲解与检测" : "重新生成",
                    systemImage: "sparkles"
                )
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(Color.accentColor)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .glassCapsule()
            .disabled(isWorking)
            .help("按当前题型生成讲解与检测")
        }
    }

    private var generationPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("讲解与练习")
                .font(.headline)
            Text("选择练习题型后，点击右侧“生成讲解与检测”。")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private func exercise(_ exercise: LearningExercise, attemptCount: Int, record: LearningRecord) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(practiceLabel(exercise.type))
                    .font(.caption2.weight(.medium))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(Color.accentColor.opacity(0.12), in: Capsule())
                Text(exercise.title)
                    .font(.headline)
                Spacer()
                Text("第 \(attemptCount + 1) 次")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text(exercise.prompt)
                .font(.body.weight(.medium))
                .lineSpacing(4)
            if !exercise.instructions.isEmpty {
                Text(exercise.instructions)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            if !exercise.examples.isEmpty {
                exerciseExtras(
                    "示例",
                    values: exercise.examples,
                    language: Self.codeExerciseTypes.contains(exercise.type) ? exercise.language : nil
                )
            }
            if !exercise.constraints.isEmpty {
                exerciseExtras("约束", values: exercise.constraints, language: nil)
            }
            if exercise.type == "choice" {
                VStack(spacing: 6) {
                    ForEach(exercise.choices, id: \.self) { choice in
                        Button {
                            selectedChoice = choice
                            answer = choice
                        } label: {
                            HStack(spacing: 9) {
                                Image(systemName: selectedChoice == choice ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(selectedChoice == choice ? Color.accentColor : .secondary)
                                Text(choice).frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .padding(.horizontal, 10)
                            .frame(minHeight: 36)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .background(
                            selectedChoice == choice ? Color.accentColor.opacity(0.08) : .clear,
                            in: RoundedRectangle(cornerRadius: 7, style: .continuous)
                        )
                    }
                }
            } else {
                answerEditor(
                    isCode: Self.codeExerciseTypes.contains(exercise.type),
                    language: exercise.language
                )
            }

            HStack {
                Spacer()
                if isWorking {
                    HStack(spacing: 7) {
                        ProgressView().controlSize(.small)
                        Text("正在判分")
                            .font(AppDesign.Typography.body)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    let canSubmit = !answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    Button {
                        Task { await submitAttempt(record) }
                    } label: {
                        Label("提交检测", systemImage: "paperplane.fill")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(canSubmit ? Color.accentColor : .secondary)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .glassCapsule()
                    .opacity(canSubmit ? 1 : 0.45)
                    .allowsHitTesting(canSubmit)
                    .help("提交当前作答进行 AI 判分")
                }
            }
        }
    }

    private func practiceLabel(_ type: String) -> String {
        switch type {
        case "choice": "选择题"
        case "short_answer": "简答题"
        case "code_completion": "代码补全"
        case "coding": "编程题"
        default: "检测"
        }
    }

    @ViewBuilder
    private func exerciseExtras(_ title: String, values: [String], language: String?) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            if let language {
                // 代码题示例属于只读代码，不再伪装成一组等宽正文。
                SyntaxHighlightedCodeView(
                    code: values.joined(separator: "\n\n"),
                    language: language
                )
            } else {
                ForEach(values, id: \.self) { value in
                    Text(value)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineSpacing(3)
                        .textSelection(.enabled)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(language == nil ? 10 : 0)
        .background {
            if language == nil {
                Color(nsColor: .textBackgroundColor)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
        }
    }

    private var practiceTypePicker: some View {
        GlassSegmentedControl(
            options: [
                ("auto", "智能"),
                ("choice", "选择"),
                ("short_answer", "简答"),
                ("code_completion", "补全"),
                ("coding", "编程")
            ],
            selection: $practiceType
        )
        .disabled(isWorking)
    }

    /// 作答区跟着代码长：一屏放得下就整段显示，不要写死高度把结尾裁掉。
    /// 上限 760 是为了超长答案时提交按钮还留在视野内，届时编辑器内部自己滚。
    private var codeAnswerHeight: CGFloat {
        min(max(answerContentHeight + 16, 220), 760)
    }

    private func answerEditor(isCode: Bool, language: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("你的作答")
                    .font(.subheadline.weight(.semibold))
                if isCode {
                    Text(language.isEmpty ? "code" : language)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                    Button {
                        answerFormatRequest += 1
                    } label: {
                        Image(systemName: "textformat")
                    }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                    .help("格式化代码")
                }
                Spacer()
                Text("\(answer.count) 字")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.tertiary)
            }

            ZStack(alignment: .topLeading) {
                if isCode {
                    LeetCodeCodeEditor(
                        code: $answer,
                        language: language,
                        diagnostics: $answerDiagnostics,
                        loadStatus: $answerLoadStatus,
                        completionStatus: $answerCompletionStatus,
                        formatRequest: answerFormatRequest,
                        undoRequest: 0,
                        redoRequest: 0,
                        contentHeight: $answerContentHeight
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                } else {
                    TextEditor(text: $answer)
                        .font(.body)
                        .lineSpacing(3)
                        .scrollContentBackground(.hidden)
                        .floatingTextScrollIndicators()
                        .padding(10)

                    if answer.isEmpty {
                        Text("直接回答检测题；代码题请保留必要的方法签名…")
                            .font(.body)
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, 15)
                            .padding(.vertical, 16)
                            .allowsHitTesting(false)
                    }
                }
            }
            .frame(height: isCode ? codeAnswerHeight : 190)
            .animation(AppDesign.Motion.subtle, value: codeAnswerHeight)
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(AppDesign.ColorToken.separator)
            }
            .accessibilityLabel("复习回答")
        }
    }


    private func preparePackageIfNeeded(force: Bool = false) async {
        guard let record = selectedRecord, (record.activeStudyPackage == nil || force), !isWorking else { return }
        isWorking = true
        learningError = ""
        defer { isWorking = false }
        do {
            // 走公共入口：脑图那边也可能正在给同一道题生成讲解，
            // 两边合流到同一个任务上，不会重复调一次 AI。
            try await LearningPackageProvisioner.ensurePackage(
                for: record,
                dataStore: dataStore,
                requestedType: practiceType,
                force: force
            )
        } catch {
            learningError = error.localizedDescription
        }
    }

    private func submitAttempt(_ record: LearningRecord) async {
        guard let package = record.activeStudyPackage else { return }
        isWorking = true
        learningError = ""
        defer { isWorking = false }
        do {
            let judgment = try await ChatService(dataDirectory: dataStore.dataDirectory).judgeLearningAttempt(
                record: record,
                package: package,
                answer: answer,
                providerID: AITaskRoute.studyAssessment.providerID(in: dataStore.settings)
            )
            try await dataStore.recordLearningAttempt(
                recordID: record.id,
                packageID: package.id,
                answer: answer,
                judgment: judgment
            )
            answerDrafts[currentDraftKey] = answer
        } catch {
            learningError = error.localizedDescription
        }
    }

    private func attemptResult(_ attempt: LearningAttempt) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Text("最近检测")
                    .font(.headline)
                Spacer()
                Text("\(Int(attempt.score.rounded())) 分")
                    .font(.headline.monospacedDigit())
            }
            Text(attempt.feedback)
                .font(.callout)
            if !attempt.strengths.isEmpty {
                ForEach(attempt.strengths, id: \.self) { strength in
                    Label(strength, systemImage: "checkmark.circle")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            if !attempt.gaps.isEmpty {
                ForEach(attempt.gaps, id: \.self) { gap in
                    Label(gap, systemImage: "arrow.turn.down.right")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            if !attempt.nextStep.isEmpty {
                Label(attempt.nextStep, systemImage: "arrow.right.circle")
                    .font(.callout.weight(.medium))
            }
        }
        .padding(.leading, 12)
        .overlay(alignment: .leading) {
            Rectangle().fill(attempt.score >= 85 ? AppDesign.ColorToken.success : AppDesign.ColorToken.warning).frame(width: 2)
        }
    }

    /// 今日队列的说明条：练什么、还欠多少、为什么是这个数。
    @ViewBuilder
    private var queueSummary: some View {
        let plan = todayPlan
        if queueScope == .today {
            HStack(spacing: 6) {
                Text("今日 \(plan.queue.count) 项")
                    .font(AppDesign.Typography.micro.weight(.medium).monospacedDigit())
                Text(plan.deferred > 0 ? "· 还欠 \(plan.deferred) 项" : "· 已排完")
                    .font(AppDesign.Typography.micro.monospacedDigit())
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
                Text(plan.isWeeklyReviewDay ? "每周复习日" : "复习 \(plan.reviewQuota) · 新知识 \(plan.newQuota)")
                    .font(AppDesign.Typography.micro.monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            HStack(spacing: 6) {
                Text("\(dataStore.dueCount) 待复习")
                    .font(AppDesign.Typography.micro.monospacedDigit())
                Text("· \(dataStore.weakCount) 薄弱")
                    .font(AppDesign.Typography.micro.monospacedDigit())
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func reviewQueueRow(_ record: LearningRecord) -> some View {
        Button {
            withAnimation(AppDesign.Motion.selection) { selectedID = record.id }
        } label: {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 7) {
                    Circle()
                        .fill(masteryColor(record.masteryScore))
                        .frame(width: 7, height: 7)
                    Text(record.title)
                        .font(AppDesign.Typography.bodyEmphasis)
                        .lineLimit(1)
                }
                HStack(spacing: 6) {
                    Text(record.primaryKnowledge)
                        .lineLimit(1)
                    if queueScope == .today {
                        Text(LearningReviewSchedule.reason(for: record))
                            .foregroundStyle(record.reviewCount <= 0 ? Color.accentColor : reasonTint(record))
                    }
                    Spacer(minLength: 4)
                    Text("\(Int(record.masteryScore))")
                        .monospacedDigit()
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(selectedRecord?.id == record.id ? AppDesign.ColorToken.listSelection : .clear)
        }
        .contextMenu {
            Button("查看证据", systemImage: "doc.text.magnifyingglass") {
                workspace.selectedLearningRecordID = record.id
                workspace.presentTool(.evidence)
            }
            Divider()
            // 之前只能操作已经在回收站里的条目，活动知识点没有任何删除入口。
            Button("移到回收站", systemImage: "trash", role: .destructive) {
                Task { try? await dataStore.deleteLearningRecord(record.id) }
            }
        }
    }

    private func masteryColor(_ score: Double) -> Color {
        switch score {
        case ..<40: AppDesign.ColorToken.warning
        case ..<70: .accentColor
        default: AppDesign.ColorToken.success
        }
    }
}

private struct MasteryGauge: View {
    let score: Double

    var body: some View {
        VStack(alignment: .trailing, spacing: 3) {
            Text(score, format: .number.precision(.fractionLength(0)))
                .font(.title3.weight(.semibold).monospacedDigit())
            Text("掌握度")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("掌握度 \(Int(score))")
    }
}

struct GlassSegmentedControl: View {
    let options: [(value: String, label: String)]
    @Binding var selection: String

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.value) { option in
                let isSelected = option.value == selection
                Button {
                    selection = option.value
                } label: {
                    Text(option.label)
                        .font(.system(size: 12.5, weight: isSelected ? .semibold : .regular))
                        .foregroundStyle(isSelected ? .primary : .secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 5)
                        .background {
                            if isSelected {
                                Capsule().fill(Color.primary.opacity(0.08))
                            }
                        }
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .glassCapsule()
    }
}

extension View {
    @ViewBuilder
    func glassCapsule() -> some View {
        if #available(macOS 26.0, *) {
            glassEffect(.regular.interactive(), in: .capsule)
        } else {
            background(.regularMaterial, in: Capsule())
                .overlay { Capsule().strokeBorder(.primary.opacity(0.08)) }
        }
    }

    @ViewBuilder
    func glassCircle() -> some View {
        if #available(macOS 26.0, *) {
            glassEffect(.regular.interactive(), in: .circle)
        } else {
            background(.regularMaterial, in: Circle())
                .overlay { Circle().strokeBorder(.primary.opacity(0.08)) }
        }
    }
}
