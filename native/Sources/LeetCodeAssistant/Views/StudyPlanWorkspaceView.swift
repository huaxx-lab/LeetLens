import SwiftUI

struct StudyPlanWorkspaceView: View {
    @Bindable var workspace: WorkspaceState
    @Bindable var dataStore: LegacyDataStore
    @State private var selectedDate = Calendar.current.startOfDay(for: .now)
    @State private var visibleMonth = Calendar.current.dateInterval(of: .month, for: .now)?.start ?? .now
    @State private var editor: StudyTaskEditor?

    var body: some View {
        VStack(spacing: 0) {
            header
            summaryStrip
            // 不再用 HSplitView：它给每个 pane 画自己的不透明底，
            // 于是圆角玻璃卡外面又套出一个直角矩形，背景渐变也被挡住。
            HStack(alignment: .top, spacing: 14) {
                calendarPane
                    // 左列也要吃满高度，否则它按内容取理想高度，
                    // 底边就和右侧时间线差出一截（两根圆角矩形对不齐）。
                    .frame(minWidth: 344, maxWidth: 344, maxHeight: .infinity)
                timelinePane
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .padding(.horizontal, 18)
            .padding(.bottom, 18)
        }
        .background(AppDesign.ColorToken.canvas.ignoresSafeArea())
        .sheet(item: $editor) { editor in
            StudyTaskEditorView(
                editor: editor,
                learningRecords: dataStore.learningRecords,
                onSave: saveEditor,
                onCancel: { self.editor = nil }
            )
        }
        .sheet(item: $workspace.studyPlanSuggestion) { suggestion in
            AIStudyPlanPreviewView(
                suggestion: suggestion,
                records: dataStore.learningRecords,
                errorMessage: workspace.studyPlanError,
                onApply: { applySuggestion(suggestion) },
                onCancel: {
                    workspace.studyPlanSuggestion = nil
                    workspace.studyPlanError = ""
                }
            )
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text("学习计划")
                    .font(AppDesign.Typography.pageTitle)
                Text(selectedDate, format: .dateTime.year().month().day().weekday(.wide))
                    .font(AppDesign.Typography.aux)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            headerActions
        }
        .padding(.horizontal, 18)
        .frame(height: 72)
    }

    /// 三个动作统一成一组胶囊：两个玻璃次要动作 + 一个实心主动作，
    /// 不再是 bordered / borderless / borderedProminent 三种系统按钮混排。
    private var headerActions: some View {
        HStack(spacing: 8) {
            capsuleAction(
                "AI 安排",
                systemImage: "sparkles",
                isBusy: workspace.isGeneratingStudyPlan,
                help: dataStore.activeLearningRecords.isEmpty
                    ? "需要先从对话或做题沉淀学习项"
                    : "根据 FSRS 到期时间与掌握度生成未来 7 天计划"
            ) {
                generateAIPlan()
            }
            .disabled(workspace.isGeneratingStudyPlan || dataStore.activeLearningRecords.isEmpty)

            if workspace.isGeneratingStudyPlan {
                capsuleAction("停止", systemImage: "stop.fill", help: "停止生成") {
                    workspace.stopStudyPlanGeneration()
                }
            }

            capsuleAction("今天", systemImage: "calendar.badge.clock", help: "回到今天") {
                selectedDate = Calendar.current.startOfDay(for: .now)
                visibleMonth = Calendar.current.dateInterval(of: .month, for: selectedDate)?.start ?? selectedDate
            }

            Button {
                editor = .new(date: selectedDate, linkedRecordID: workspace.selectedLearningRecordID)
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "plus").font(AppDesign.Typography.iconCompact)
                    Text("新建任务").font(AppDesign.Typography.bodyEmphasis)
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 14)
                .frame(height: 32)
                .background(Color.accentColor, in: Capsule())
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .help("新建学习任务")
        }
    }

    private func capsuleAction(
        _ title: String,
        systemImage: String,
        isBusy: Bool = false,
        help: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if isBusy {
                    ProgressView()
                        .controlSize(.small)
                        .scaleEffect(0.7)
                        .frame(width: 13, height: 13)
                } else {
                    Image(systemName: systemImage).font(AppDesign.Typography.iconCompact)
                }
                Text(title).font(AppDesign.Typography.bodyEmphasis)
            }
            .padding(.horizontal, 13)
            .frame(height: 32)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .inlineGlass(cornerRadius: 16, interactive: true)
        .help(help)
    }

    private var summaryStrip: some View {
        // `.top` + `fixedSize(vertical:)`：让这一排取最高卡片的高度，
        // 其余卡片再撑满它——四张卡上下沿才真正齐平。
        HStack(alignment: .top, spacing: 12) {
            todayCard
            summaryMetric(
                "本周完成",
                value: "\(weekCompleted)",
                unit: "/\(weekTasks.count)",
                detail: weekTasks.isEmpty ? "本周还没有安排" : "已完成任务数",
                icon: "calendar",
                tint: .accentColor
            )
            summaryMetric(
                "待处理",
                value: "\(pendingCount)",
                unit: " 项",
                detail: "全部未完成计划",
                icon: "tray.full",
                tint: .teal
            )
            summaryMetric(
                "已逾期",
                value: "\(overdueCount)",
                unit: " 项",
                detail: overdueCount == 0 ? "进度正常" : "需要调整安排",
                icon: "exclamationmark.triangle",
                tint: overdueCount == 0 ? .secondary : .red
            )
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(.horizontal, 18)
        .padding(.bottom, 16)
    }

    private var todayCard: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle().stroke(Color.primary.opacity(0.08), lineWidth: 5)
                Circle()
                    .trim(from: 0, to: max(0.001, todayProgress))
                    .stroke(
                        AngularGradient(colors: [Color.accentColor.opacity(0.55), .accentColor], center: .center),
                        style: StrokeStyle(lineWidth: 5, lineCap: .round)
                    )
                    .rotationEffect(.degrees(-90))
                Text("\(Int((todayProgress * 100).rounded()))%")
                    .font(AppDesign.Typography.micro.monospacedDigit())
            }
            .frame(width: 44, height: 44)
            .animation(AppDesign.Motion.fade, value: todayProgress)

            VStack(alignment: .leading, spacing: 3) {
                Text("今日进度").font(AppDesign.Typography.bodyEmphasis)
                Text("\(todayCompleted) / \(todayTasks.count) 已完成")
                    .font(AppDesign.Typography.aux)
                    .foregroundStyle(.secondary)
                Text(todayTasks.isEmpty ? "今天还没有任务" : "计划 \(todayMinutes) 分钟")
                    .font(AppDesign.Typography.micro)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        // 全页统一 floating 半径：概览卡原来是 10、日历/时间线是 16，
        // 混在一屏里就是"圆角不规整"。
        .inlineGlass(cornerRadius: AppDesign.Radius.floating)
    }

    private func summaryMetric(
        _ title: String,
        value: String,
        unit: String,
        detail: String,
        icon: String,
        tint: Color
    ) -> some View {
        VStack(alignment: .leading, spacing: 7) {
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
            Text(detail)
                .font(AppDesign.Typography.micro)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .inlineGlass(cornerRadius: AppDesign.Radius.floating)
    }

    private var calendarPane: some View {
        VStack(spacing: 12) {
            VStack(spacing: 0) {
                HStack {
                    Text(visibleMonth, format: .dateTime.year().month(.wide))
                        .font(AppDesign.Typography.sectionTitle)
                    Spacer()
                    CompactIconButton(title: "上个月", systemImage: "chevron.left") { moveMonth(-1) }
                    CompactIconButton(title: "下个月", systemImage: "chevron.right") { moveMonth(1) }
                }
                .frame(height: 34)

                calendarGrid
                    .padding(.top, 6)

                priorityLegend
                    .padding(.top, 10)
            }
            .padding(16)
            .navigationGlass(cornerRadius: AppDesign.Radius.floating)

            selectedDayAgenda
                .frame(maxHeight: .infinity)
        }
    }

    private var selectedDayAgenda: some View {
        VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(selectedDate, format: .dateTime.month().day().weekday(.abbreviated))
                    .font(AppDesign.Typography.bodyEmphasis)
                Text(dayProgressText)
                    .font(AppDesign.Typography.micro)
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    editor = .new(date: selectedDate, linkedRecordID: workspace.selectedLearningRecordID)
                } label: {
                    Image(systemName: "plus")
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("添加当天任务")
            }
            .padding(.horizontal, 16)
            .frame(height: 48)

            if selectedTasks.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "calendar.badge.plus")
                        .font(.system(size: 19, weight: .light))
                        .foregroundStyle(.tertiary)
                    Text("当天没有安排")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button("添加任务") {
                        editor = .new(date: selectedDate, linkedRecordID: workspace.selectedLearningRecordID)
                    }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(selectedTasks) { task in
                            Button {
                                editor = .edit(task)
                            } label: {
                                HStack(spacing: 9) {
                                    Circle()
                                        .fill(task.isCompleted ? Color.secondary.opacity(0.35) : priorityColor(task.priority))
                                        .frame(width: 6, height: 6)
                                    Text(task.scheduledAt, format: .dateTime.hour().minute())
                                        .font(.caption.monospacedDigit())
                                        .foregroundStyle(.secondary)
                                        .frame(width: 42, alignment: .leading)
                                    Text(task.title)
                                        .font(.callout)
                                        .strikethrough(task.isCompleted)
                                        .lineLimit(1)
                                    Spacer(minLength: 0)
                                    Image(systemName: "chevron.right")
                                        .font(.caption2.weight(.semibold))
                                        .foregroundStyle(.tertiary)
                                }
                                .padding(.horizontal, 16)
                                .frame(height: 42)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .floatingScrollIndicators()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationGlass(cornerRadius: AppDesign.Radius.floating)
    }

    private var calendarGrid: some View {
        VStack(spacing: 5) {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 7), spacing: 4) {
                ForEach(weekdayTitles, id: \.self) { title in
                    Text(title)
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 24)
                }
                ForEach(calendarDays) { day in
                    if let date = day.date {
                        calendarDay(date)
                    } else {
                        Color.clear.frame(height: 42)
                    }
                }
            }
        }
    }

    private func calendarDay(_ date: Date) -> some View {
        let tasks = tasks(on: date)
        let isSelected = Calendar.current.isDate(date, inSameDayAs: selectedDate)
        let isToday = Calendar.current.isDateInToday(date)
        let isOutsideMonth = !Calendar.current.isDate(date, equalTo: visibleMonth, toGranularity: .month)
        return Button {
            selectedDate = Calendar.current.startOfDay(for: date)
        } label: {
            VStack(spacing: 4) {
                Text(date, format: .dateTime.day())
                    .font(AppDesign.Typography.aux.weight(isSelected || isToday ? .semibold : .regular).monospacedDigit())
                    .foregroundStyle(isSelected ? Color.accentColor : isOutsideMonth ? Color.secondary.opacity(0.5) : Color.primary)
                // 圆点只到 3 个，再多用一根小横杠表示"还有"，避免一排点糊成一团。
                HStack(spacing: 2) {
                    ForEach(Array(tasks.prefix(3))) { task in
                        Circle()
                            .fill(task.isCompleted ? Color.secondary.opacity(0.32) : priorityColor(task.priority))
                            .frame(width: 4, height: 4)
                    }
                    if tasks.count > 3 {
                        Capsule()
                            .fill(Color.secondary.opacity(0.45))
                            .frame(width: 7, height: 3)
                    }
                }
                .frame(height: 4)
            }
            .frame(maxWidth: .infinity, minHeight: 42)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(isSelected ? Color.accentColor.opacity(0.14) : .clear)
        }
        .overlay {
            if isToday {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(Color.accentColor.opacity(isSelected ? 0.85 : 0.4), lineWidth: isSelected ? 1.5 : 1)
            }
        }
        .accessibilityLabel("\(date.formatted(date: .long, time: .omitted))，\(tasks.count) 个任务")
    }

    private var priorityLegend: some View {
        HStack(spacing: 14) {
            ForEach(StudyTaskPriority.allCases) { priority in
                HStack(spacing: 5) {
                    Circle().fill(priorityColor(priority)).frame(width: 6, height: 6)
                    Text(priority.title).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
        }
    }

    private var timelinePane: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("每日安排").font(AppDesign.Typography.sectionTitle)
                    Text(dayProgressText)
                        .font(AppDesign.Typography.aux)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("添加", systemImage: "plus") {
                    editor = .new(date: selectedDate, linkedRecordID: workspace.selectedLearningRecordID)
                }
                .buttonStyle(.borderless)
            }
            .padding(.horizontal, 18)
            .frame(height: 56)

            Divider()

            if selectedTasks.isEmpty {
                ContentUnavailableView(
                    "当天没有任务",
                    systemImage: "calendar.badge.plus",
                    description: Text("新任务会按时间进入这里，也可以关联学习题库中的知识项。")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(selectedTasks) { task in
                            timelineRow(task)
                            if task.id != selectedTasks.last?.id { Divider().padding(.leading, 104) }
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 10)
                }
                .floatingScrollIndicators()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationGlass(cornerRadius: AppDesign.Radius.floating)
    }

    private func timelineRow(_ task: StudyPlanTask) -> some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(alignment: .trailing, spacing: 3) {
                Text(task.scheduledAt, format: .dateTime.hour().minute())
                    .font(.callout.monospacedDigit())
                Text("\(task.durationMinutes) 分钟")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .frame(width: 66, alignment: .trailing)

            Button {
                try? dataStore.toggleStudyTask(task.id)
            } label: {
                Image(systemName: task.isCompleted ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 17))
                    .foregroundStyle(task.isCompleted ? AppDesign.ColorToken.success : priorityColor(task.priority))
            }
            .buttonStyle(.plain)
            .help(task.isCompleted ? "标记为未完成" : "标记为完成")

            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 8) {
                    Text(task.title)
                        .font(.system(size: 14, weight: .medium))
                        .strikethrough(task.isCompleted)
                    Text(task.priority.title)
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(priorityColor(task.priority))
                }
                if !task.notes.isEmpty {
                    Text(task.notes)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                if let record = linkedRecord(for: task) {
                    Button {
                        workspace.selectedLearningRecordID = record.id
                        workspace.selectedSection = .library
                    } label: {
                        Label(record.title, systemImage: "books.vertical")
                            .font(.caption)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Menu {
                Button("编辑", systemImage: "pencil") { editor = .edit(task) }
                Button("删除", systemImage: "trash", role: .destructive) { try? dataStore.deleteStudyTask(task.id) }
            } label: {
                Image(systemName: "ellipsis").frame(width: 28, height: 28)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            // borderlessButton 的 Menu 会**贪心占宽**：不锁死宽度它就和左边的正文
            // 平分剩余空间，于是正文只剩一半、右边空出一大片，"…" 也停在中间。
            .frame(width: 28)
            .help("任务操作")
        }
        .padding(.vertical, 16)
        .contentShape(Rectangle())
    }

    private var weekdayTitles: [String] { ["一", "二", "三", "四", "五", "六", "日"] }

    private var calendarDays: [PlanCalendarDay] {
        let calendar = Calendar.current
        guard let interval = calendar.dateInterval(of: .month, for: visibleMonth),
              let range = calendar.range(of: .day, in: .month, for: visibleMonth)
        else { return [] }
        let weekday = calendar.component(.weekday, from: interval.start)
        let leading = (weekday + 5) % 7
        var result = (0..<leading).map { PlanCalendarDay(id: "blank-\($0)", date: nil) }
        result += range.compactMap { day in
            guard let date = calendar.date(byAdding: .day, value: day - 1, to: interval.start) else { return nil }
            return PlanCalendarDay(id: date.formatted(.iso8601.year().month().day()), date: date)
        }
        return result
    }

    private var selectedTasks: [StudyPlanTask] { tasks(on: selectedDate).sorted { $0.scheduledAt < $1.scheduledAt } }
    private var todayTasks: [StudyPlanTask] { tasks(on: .now) }
    private var todayCompleted: Int { todayTasks.filter(\.isCompleted).count }
    private var todayMinutes: Int { todayTasks.reduce(0) { $0 + $1.durationMinutes } }
    private var todayProgress: Double {
        guard !todayTasks.isEmpty else { return 0 }
        return Double(todayCompleted) / Double(todayTasks.count)
    }
    private var pendingCount: Int { dataStore.studyPlanTasks.filter { !$0.isCompleted }.count }
    private var overdueCount: Int { dataStore.studyPlanTasks.filter { !$0.isCompleted && $0.scheduledAt < .now }.count }
    private var weekTasks: [StudyPlanTask] {
        guard let interval = Calendar.current.dateInterval(of: .weekOfYear, for: .now) else { return [] }
        return dataStore.studyPlanTasks.filter { interval.contains($0.scheduledAt) }
    }
    private var weekCompleted: Int { weekTasks.filter(\.isCompleted).count }
    private var dayProgressText: String {
        let completed = selectedTasks.filter(\.isCompleted).count
        let minutes = selectedTasks.reduce(0) { $0 + $1.durationMinutes }
        return "\(completed)/\(selectedTasks.count) 完成 · 计划 \(minutes) 分钟"
    }

    private func tasks(on date: Date) -> [StudyPlanTask] {
        dataStore.studyPlanTasks.filter { Calendar.current.isDate($0.scheduledAt, inSameDayAs: date) }
    }

    private func linkedRecord(for task: StudyPlanTask) -> LearningRecord? {
        guard let id = task.learningRecordID else { return nil }
        return dataStore.learningRecords.first { $0.id == id }
    }

    private func moveMonth(_ offset: Int) {
        guard let month = Calendar.current.date(byAdding: .month, value: offset, to: visibleMonth) else { return }
        visibleMonth = month
    }

    private func priorityColor(_ priority: StudyTaskPriority) -> Color {
        switch priority {
        case .normal: .accentColor
        case .important: AppDesign.ColorToken.warning
        case .urgent: .red
        }
    }

    private func saveEditor(_ editor: StudyTaskEditor) {
        do {
            if var task = editor.task {
                task.title = editor.draft.title
                task.notes = editor.draft.notes
                task.scheduledAt = editor.draft.scheduledAt
                task.durationMinutes = editor.draft.durationMinutes
                task.priority = editor.draft.priority
                task.learningRecordID = editor.draft.learningRecordID
                try dataStore.updateStudyTask(task)
            } else {
                try dataStore.createStudyTask(editor.draft)
            }
            selectedDate = Calendar.current.startOfDay(for: editor.draft.scheduledAt)
            visibleMonth = Calendar.current.dateInterval(of: .month, for: selectedDate)?.start ?? selectedDate
            self.editor = nil
        } catch {
            NSSound.beep()
        }
    }

    private func generateAIPlan() {
        guard !workspace.isGeneratingStudyPlan else { return }
        guard !dataStore.activeLearningRecords.isEmpty else {
            workspace.studyPlanError = "当前没有可安排的学习项"
            return
        }
        workspace.isGeneratingStudyPlan = true
        workspace.studyPlanError = ""
        let service = ChatService(dataDirectory: dataStore.dataDirectory)
        let providerID = AITaskRoute.studyPlan.providerID(in: dataStore.settings)
        workspace.studyPlanGenerationTask = Task { @MainActor in
            defer {
                workspace.isGeneratingStudyPlan = false
                workspace.studyPlanGenerationTask = nil
            }
            do {
                workspace.studyPlanSuggestion = try await service.generateStudyPlan(
                    records: dataStore.activeLearningRecords,
                    existingTasks: dataStore.studyPlanTasks,
                    settings: dataStore.learningSettings,
                    providerID: providerID
                )
            } catch is CancellationError {
                workspace.studyPlanError = "已停止生成学习计划"
            } catch {
                workspace.studyPlanError = error.localizedDescription
            }
        }
    }

    /// 应用建议时**不删除任何历史任务**，也绝不碰已完成的任务
    /// （排期阶段就把 `isCompleted` 的过滤掉了，见 `StudyPlanScheduler.schedule`）。
    /// 逾期的未完成项走"改期"：复用原任务、只改时间与强度；其余是新增。
    /// 于是重复点"AI 安排"既不会清空之前的记录，也不会排出两条一样的任务。
    private func applySuggestion(_ suggestion: AIStudyPlanSuggestion) {
        do {
            let tasksByID = Dictionary(uniqueKeysWithValues: dataStore.studyPlanTasks.map { ($0.id, $0) })
            var fresh: [StudyPlanDraft] = []
            for placement in suggestion.placements {
                guard
                    let taskID = placement.reschedulingTaskID,
                    var existing = tasksByID[taskID],
                    !existing.isCompleted
                else {
                    fresh.append(placement.draft)
                    continue
                }
                // 标题保持原样：用户可能手动改过（"复习单调栈（重点）"），
                // 被 AI 的措辞覆盖掉就是无声的数据丢失。时间、时长、优先级和理由才是这次要更新的。
                existing.notes = placement.draft.notes
                existing.scheduledAt = placement.draft.scheduledAt
                existing.durationMinutes = placement.draft.durationMinutes
                existing.priority = placement.draft.priority
                try dataStore.updateStudyTask(existing)
            }
            try dataStore.createStudyTasks(fresh)
            // 计划一定是从今天开始的，直接停在今天，不再跳到"第一条任务那天"。
            selectedDate = Calendar.current.startOfDay(for: .now)
            visibleMonth = Calendar.current.dateInterval(of: .month, for: selectedDate)?.start ?? selectedDate
            workspace.studyPlanSuggestion = nil
            workspace.studyPlanError = ""
        } catch {
            workspace.studyPlanError = error.localizedDescription
        }
    }
}

private struct PlanCalendarDay: Identifiable {
    let id: String
    let date: Date?
}

private struct StudyTaskEditor: Identifiable {
    let id = UUID()
    let task: StudyPlanTask?
    var draft: StudyPlanDraft

    static func new(date: Date, linkedRecordID: String?) -> Self {
        let calendar = Calendar.current
        let hour = max(8, calendar.component(.hour, from: .now))
        let scheduled = calendar.date(bySettingHour: hour, minute: 0, second: 0, of: date) ?? date
        return Self(task: nil, draft: StudyPlanDraft(scheduledAt: scheduled, learningRecordID: linkedRecordID))
    }

    static func edit(_ task: StudyPlanTask) -> Self {
        Self(task: task, draft: StudyPlanDraft(
            title: task.title,
            notes: task.notes,
            scheduledAt: task.scheduledAt,
            durationMinutes: task.durationMinutes,
            priority: task.priority,
            learningRecordID: task.learningRecordID
        ))
    }
}

private struct StudyTaskEditorView: View {
    @State private var editor: StudyTaskEditor
    let learningRecords: [LearningRecord]
    let onSave: (StudyTaskEditor) -> Void
    let onCancel: () -> Void

    init(
        editor: StudyTaskEditor,
        learningRecords: [LearningRecord],
        onSave: @escaping (StudyTaskEditor) -> Void,
        onCancel: @escaping () -> Void
    ) {
        _editor = State(initialValue: editor)
        self.learningRecords = learningRecords
        self.onSave = onSave
        self.onCancel = onCancel
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(editor.task == nil ? "新建学习任务" : "编辑学习任务")
                    .font(.headline)
                Spacer()
                Button("取消", action: onCancel).buttonStyle(.borderless)
                Button("保存") { onSave(editor) }
                    .buttonStyle(.borderedProminent)
                    .disabled(editor.draft.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .controlSize(.small)
            .padding(.horizontal, 18)
            .frame(height: 54)
            Divider()
            Form {
                TextField("任务", text: $editor.draft.title)
                TextField("备注", text: $editor.draft.notes, axis: .vertical)
                    .lineLimit(2...5)
                    .floatingTextScrollIndicators()
                DatePicker("安排时间", selection: $editor.draft.scheduledAt)
                Stepper("预计 \(editor.draft.durationMinutes) 分钟", value: $editor.draft.durationMinutes, in: 5...480, step: 5)
                Picker("优先级", selection: $editor.draft.priority) {
                    ForEach(StudyTaskPriority.allCases) { Text($0.title).tag($0) }
                }
                Picker("关联学习项", selection: $editor.draft.learningRecordID) {
                    Text("不关联").tag(String?.none)
                    ForEach(learningRecords) { record in Text(record.title).tag(Optional(record.id)) }
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
            .floatingScrollIndicators()
            .padding(10)
        }
        .frame(width: 500, height: 420)
        .background(AppDesign.ColorToken.canvas)
    }
}

private struct AIStudyPlanPreviewView: View {
    let suggestion: AIStudyPlanSuggestion
    let records: [LearningRecord]
    let errorMessage: String
    let onApply: () -> Void
    let onCancel: () -> Void

    private var recordsByID: [String: LearningRecord] {
        Dictionary(uniqueKeysWithValues: records.map { ($0.id, $0) })
    }

    private struct DayGroup: Identifiable {
        let id: Date
        let placements: [StudyPlanScheduler.Placement]
        var minutes: Int { placements.reduce(0) { $0 + $1.draft.durationMinutes } }
    }

    /// 按天分组，用户一眼能看出"今天排了几项、哪天空着"。
    private var dayGroups: [DayGroup] {
        let calendar = Calendar.current
        return Dictionary(grouping: suggestion.placements) { calendar.startOfDay(for: $0.draft.scheduledAt) }
            .map { DayGroup(id: $0.key, placements: $0.value.sorted { $0.draft.scheduledAt < $1.draft.scheduledAt }) }
            .sorted { $0.id < $1.id }
    }

    private var applyTitle: String {
        let rescheduled = suggestion.rescheduledCount
        let fresh = suggestion.placements.count - rescheduled
        if rescheduled == 0 { return "添加 \(fresh) 项" }
        if fresh == 0 { return "改期 \(rescheduled) 项" }
        return "添加 \(fresh) 项 · 改期 \(rescheduled) 项"
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "sparkles")
                    .foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text("AI 学习计划预览")
                        .font(.headline)
                    Text("从今天起按你设置的每日配额排；已有安排不会被删除")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("取消", action: onCancel)
                    .buttonStyle(.borderless)
                Button(applyTitle, systemImage: "calendar.badge.plus", action: onApply)
                    .buttonStyle(.borderedProminent)
            }
            .controlSize(.small)
            .padding(.horizontal, 20)
            .frame(height: 62)

            Divider()

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                    Text(suggestion.summary)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 16)

                    if !errorMessage.isEmpty {
                        Label(errorMessage, systemImage: "exclamationmark.triangle")
                            .font(.callout)
                            .foregroundStyle(AppDesign.ColorToken.warning)
                            .padding(.horizontal, 20)
                            .padding(.bottom, 12)
                    }

                    ForEach(dayGroups) { group in
                        Section {
                            ForEach(group.placements) { placement in
                                AIStudyPlanPreviewRow(
                                    task: placement.draft,
                                    isReschedule: placement.reschedulingTaskID != nil,
                                    record: placement.draft.learningRecordID.flatMap { recordsByID[$0] }
                                )
                                if placement.id != group.placements.last?.id {
                                    Divider().padding(.leading, 74)
                                }
                            }
                        } header: {
                            dayHeader(group)
                        }
                    }

                    if !suggestion.alreadyScheduled.isEmpty {
                        footnote(
                            icon: "checkmark.circle",
                            title: "已在计划中，这次跳过 \(suggestion.alreadyScheduled.count) 项",
                            detail: suggestion.alreadyScheduled.joined(separator: "、")
                        )
                    }
                    if !suggestion.deferred.isEmpty {
                        footnote(
                            icon: "arrow.uturn.forward",
                            title: "本周配额已满，顺延 \(suggestion.deferred.count) 项",
                            detail: suggestion.deferred.joined(separator: "、")
                        )
                    }
                }
            }
            .floatingScrollIndicators()
        }
        .frame(width: 620, height: 560)
        .background(AppDesign.ColorToken.canvas)
    }

    private func dayHeader(_ group: DayGroup) -> some View {
        HStack(spacing: 8) {
            Text(group.id, format: .dateTime.month().day().weekday(.abbreviated))
                .font(.caption.weight(.semibold))
            if Calendar.current.isDateInToday(group.id) {
                Text("今天")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(Color.accentColor, in: Capsule())
            }
            Spacer()
            Text("\(group.placements.count) 项 · \(group.minutes) 分钟")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 20)
        .frame(height: 30)
        .background(.regularMaterial)
    }

    private func footnote(icon: String, title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Label(title, systemImage: icon)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
            Text(detail)
                .font(.caption)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }
}

private struct AIStudyPlanPreviewRow: View {
    let task: StudyPlanDraft
    var isReschedule = false
    let record: LearningRecord?

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(alignment: .trailing, spacing: 2) {
                Text(task.scheduledAt, format: .dateTime.hour().minute())
                    .font(.caption.monospacedDigit().weight(.medium))
                Text("\(task.durationMinutes) 分钟")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
            .frame(width: 48, alignment: .trailing)

            Circle()
                .fill(priorityColor)
                .frame(width: 7, height: 7)
                .padding(.top, 6)

            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 8) {
                    Text(task.title)
                        .font(.system(size: 14, weight: .medium))
                    if isReschedule {
                        Text("改期")
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Color.primary.opacity(0.07), in: Capsule())
                    }
                }
                if !task.notes.isEmpty {
                    Text(task.notes)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let record {
                    Text("掌握 \(Int(record.masteryScore.rounded())) · 置信度 \(Int((record.confidence * 100).rounded()))% · FSRS \(record.dueAt.formatted(date: .abbreviated, time: .shortened))")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 13)
        .accessibilityElement(children: .combine)
    }

    private var priorityColor: Color {
        switch task.priority {
        case .normal: .accentColor
        case .important: AppDesign.ColorToken.warning
        case .urgent: .red
        }
    }
}
