import AppKit
import SwiftUI
import UniformTypeIdentifiers
import WebKit

struct SettingsView: View {
    @Environment(\.colorScheme) private var colorScheme
    @State private var selection: SettingsSection = .general
    @Bindable var workspace: WorkspaceState
    @Bindable var dataStore: LegacyDataStore
    let onDismiss: () -> Void
    let openInBrowser: (URL) -> Void
    @State private var searchText = ""

    private var visibleGroups: [SettingsSectionGroup] {
        guard !searchText.isEmpty else { return SettingsSectionGroup.all }
        return SettingsSectionGroup.all.compactMap { group in
            let sections = group.sections.filter {
                $0.title.localizedCaseInsensitiveContains(searchText)
            }
            return sections.isEmpty ? nil : SettingsSectionGroup(title: group.title, sections: sections)
        }
    }

    var body: some View {
        NavigationSplitView {
            VStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 8) {
                        Button(action: onDismiss) {
                            Label("返回应用", systemImage: "chevron.left")
                                .font(.system(size: 15))
                                .frame(height: 32)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)

                        Spacer()

                        Button { dataStore.reload() } label: {
                            Image(systemName: "arrow.clockwise")
                                .font(.system(size: 15))
                                .frame(width: 32, height: 32)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .help("重新读取原项目配置")
                    }

                    HStack(spacing: 8) {
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 14))
                            .foregroundStyle(.secondary)
                        TextField("搜索设置…", text: $searchText)
                            .font(.system(size: 14))
                            .textFieldStyle(.plain)
                    }
                    .padding(.horizontal, 12)
                    .frame(height: 40)
                    .glassCapsule()
                }
                .padding(14)

                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 3) {
                        ForEach(visibleGroups) { group in
                            Text(group.title)
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(.secondary)
                                .padding(.leading, 12)
                                .padding(.top, 18)
                                .padding(.bottom, 6)

                            ForEach(group.sections) { section in
                                sectionRow(section)
                            }
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.bottom, 14)
                }
                .floatingScrollIndicators()
            }
            .navigationSplitViewColumnWidth(min: 252, ideal: 278, max: 304)
            .background(AppDesign.ColorToken.sidebarSurface)
        } detail: {
            Group {
                if workspace.isToolWorkspaceFocused {
                    ToolWorkspaceView(workspace: workspace, dataStore: dataStore)
                        .accessibilityElement(children: .contain)
                } else {
                    VStack(spacing: 0) {
                        header
                        settingsPage
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(AppDesign.ColorToken.canvas)
        }
        .navigationSplitViewStyle(.balanced)
    }

    private var header: some View {
        HStack {
            Spacer(minLength: 0)
            VStack(alignment: .leading, spacing: 4) {
                Text(selection.title)
                    .font(AppDesign.Typography.display)
                Text(selection.subtitle)
                    .font(AppDesign.Typography.body)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: 740, alignment: .leading)
            Spacer(minLength: 0)
        }
        .padding(.top, 30)
        .padding(.bottom, 12)
    }

    private func sectionRow(_ section: SettingsSection) -> some View {
        Button {
            withAnimation(AppDesign.Motion.selection) { selection = section }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: section.systemImage)
                    .font(.system(size: 16))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(selection == section ? Color.accentColor : Color.secondary)
                    .frame(width: 24)
                Text(section.title)
                    .font(.system(size: 14, weight: selection == section ? .medium : .regular))
                Spacer()
            }
            .padding(.horizontal, 10)
            .frame(height: 36)
            .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
            .background(
                selection == section ? AppDesign.ColorToken.inlineFill : .clear,
                in: RoundedRectangle(cornerRadius: 9, style: .continuous)
            )
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selection == section ? .isSelected : [])
    }

    @ViewBuilder
    private var settingsPage: some View {
        switch selection {
        case .general: GeneralSettingsPage(dataStore: dataStore)
        case .browser: BrowserSettingsPage(workspace: workspace)
        case .providers: ProviderSettingsPage(dataStore: dataStore, openInBrowser: openInBrowser)
        case .context: ContextSettingsPage(dataStore: dataStore)
        case .data: DataCacheSettingsPage()
        case .video: VideoSettingsPage(dataStore: dataStore, openInBrowser: openInBrowser)
        case .learning: LearningSettingsPage(dataStore: dataStore)
        case .accounts: AccountSettingsPage(dataStore: dataStore)
        case .profile: ProfileSettingsPage(dataStore: dataStore)
        case .appearance: AppearanceSettingsPage(dataStore: dataStore)
        }
    }
}

private enum SettingsSection: String, CaseIterable, Identifiable {
    case general
    case browser
    case providers
    case context
    case data
    case video
    case learning
    case accounts
    case profile
    case appearance

    var id: String { rawValue }
    var title: String {
        switch self {
        case .general: "常规"
        case .browser: "浏览器"
        case .providers: "模型供应商"
        case .context: "上下文"
        case .data: "数据与缓存"
        case .video: "B站视频"
        case .learning: "学习与复习"
        case .accounts: "账户连接"
        case .profile: "个人资料"
        case .appearance: "外观"
        }
    }
    var systemImage: String {
        switch self {
        case .general: "gearshape"
        case .browser: "globe"
        case .providers: "cpu"
        case .context: "circle.dotted.circle"
        case .data: "externaldrive.connected.to.line.below"
        case .video: "play.rectangle"
        case .learning: "graduationcap"
        case .accounts: "person.crop.circle"
        case .profile: "person.text.rectangle"
        case .appearance: "circle.lefthalf.filled"
        }
    }
    var subtitle: String {
        switch self {
        case .general: "管理窗口、工作区与默认行为"
        case .browser: "管理内置浏览器、会话、历史与下载"
        case .providers: "配置 AI 供应商、模型与任务路由"
        case .context: "调整上下文窗口、压缩阈值与保留策略"
        case .data: "管理 Redis 热缓存与 PostgreSQL 向量存储"
        case .video: "设置 B 站视频匹配、播放与缓存"
        case .learning: "调整复习计划、代码语言与学习数据"
        case .accounts: "管理 LeetCode 与视频服务连接"
        case .profile: "查看真实账户、AI 用量与学习活动"
        case .appearance: "调整外观、动效与 Liquid Glass 层级"
        }
    }
}

private struct SettingsSectionGroup: Identifiable {
    let title: String
    let sections: [SettingsSection]

    var id: String { title }

    static let all: [SettingsSectionGroup] = [
        SettingsSectionGroup(title: "通用", sections: [.general, .appearance, .browser]),
        SettingsSectionGroup(title: "模型与上下文", sections: [.providers, .context]),
        SettingsSectionGroup(title: "数据", sections: [.data]),
        SettingsSectionGroup(title: "学习", sections: [.video, .learning]),
        SettingsSectionGroup(title: "账户", sections: [.profile, .accounts])
    ]
}

// MARK: - Codex 式设置组件

private struct SettingsScroll<Content: View>: View {
    var maxWidth: CGFloat = 740
    @ViewBuilder let content: Content

    var body: some View {
        ScrollView {
            HStack {
                Spacer(minLength: 0)
                VStack(alignment: .leading, spacing: 20) { content }
                    .frame(maxWidth: maxWidth, alignment: .leading)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 28)
            .padding(.top, 16)
            .padding(.bottom, 48)
        }
        .floatingScrollIndicators()
    }
}

private struct SettingsCard<Content: View>: View {
    let title: String
    var systemImage: String? = nil
    var tint: Color = .accentColor
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 7) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(tint)
                        .frame(width: 22, height: 22)
                        .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                }
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .padding(.leading, 4)

            VStack(spacing: 0) { content }
                .background(
                    Color.primary.opacity(0.03),
                    in: RoundedRectangle(cornerRadius: 11, style: .continuous)
                )
                .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.06))
                }
        }
    }
}

private struct SettingsRow<Control: View>: View {
    let title: String
    let subtitle: String?
    let systemImage: String?
    let iconTint: Color?
    @ViewBuilder let control: Control

    init(
        _ title: String,
        subtitle: String? = nil,
        systemImage: String? = nil,
        iconTint: Color? = nil,
        @ViewBuilder control: () -> Control
    ) {
        self.title = title
        self.subtitle = subtitle
        self.systemImage = systemImage
        self.iconTint = iconTint
        self.control = control()
    }

    var body: some View {
        HStack(spacing: 14) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(AppDesign.Typography.icon)
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(iconTint ?? .secondary)
                    .frame(width: AppDesign.Size.iconSlot)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(AppDesign.Typography.rowTitle)
                if let subtitle {
                    Text(subtitle)
                        .font(AppDesign.Typography.body)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 16)
            control
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }
}

private extension SettingsRow where Control == EmptyView {
    init(_ title: String, subtitle: String? = nil, systemImage: String? = nil) {
        self.init(title, subtitle: subtitle, systemImage: systemImage) { EmptyView() }
    }
}

private struct SettingsToggleRow: View {
    let title: String
    var subtitle: String? = nil
    @Binding var isOn: Bool

    init(_ title: String, subtitle: String? = nil, isOn: Binding<Bool>) {
        self.title = title
        self.subtitle = subtitle
        _isOn = isOn
    }

    var body: some View {
        SettingsRow(title, subtitle: subtitle) {
            Toggle(title, isOn: $isOn).labelsHidden()
        }
    }
}

private struct SettingsSliderRow<Control: View>: View {
    let title: String
    let valueText: String
    @ViewBuilder let control: Control

    init(_ title: String, valueText: String, @ViewBuilder control: () -> Control) {
        self.title = title
        self.valueText = valueText
        self.control = control()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(title)
                    .font(.system(size: 15, weight: .medium))
                Spacer()
                Text(valueText)
                    .font(.system(size: 14))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            control
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 13)
    }
}

private struct CardDivider: View {
    var body: some View {
        Divider().padding(.leading, 16)
    }
}

// MARK: - 常规

private struct GeneralSettingsPage: View {
    @Bindable var dataStore: LegacyDataStore
    @State private var alwaysOnTop: Bool
    @State private var saveStatus = ""

    init(dataStore: LegacyDataStore) {
        self.dataStore = dataStore
        _alwaysOnTop = State(initialValue: dataStore.settings.alwaysOnTop)
    }

    var body: some View {
        SettingsScroll {
            SettingsCard(title: "窗口") {
                SettingsToggleRow("始终置于最前方", subtitle: "窗口始终悬浮在其他应用之上", isOn: $alwaysOnTop)
            }

            if !saveStatus.isEmpty {
                Text(saveStatus)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .onChange(of: alwaysOnTop) { _, value in
            do {
                try dataStore.saveGeneral(alwaysOnTop: value)
                NSApp.mainWindow?.level = value ? .floating : .normal
                saveStatus = "已保存"
            } catch {
                saveStatus = "保存失败：\(error.localizedDescription)"
            }
        }
    }
}

// MARK: - 浏览器

private struct BrowserSettingsPage: View {
    @Bindable var workspace: WorkspaceState
    @ObservedObject private var session = BrowserSession.shared
    @State private var linkTarget: BrowserLinkTarget
    @State private var restoresSession: Bool
    @State private var asksWhereToSaveDownloads: Bool
    @State private var downloadDirectory: URL
    @State private var showsHistory = false
    @State private var confirmsClearingData = false
    @State private var isClearingData = false
    @State private var status = ""

    init(workspace: WorkspaceState) {
        self.workspace = workspace
        let preferences = BrowserPreferences.shared
        _linkTarget = State(initialValue: preferences.linkTarget)
        _restoresSession = State(initialValue: preferences.restoresSession)
        _asksWhereToSaveDownloads = State(initialValue: preferences.asksWhereToSaveDownloads)
        _downloadDirectory = State(initialValue: preferences.downloadDirectory)
    }

    var body: some View {
        SettingsScroll {
            SettingsCard(title: "常规", systemImage: "globe") {
                SettingsRow("网页链接打开位置", subtitle: "对话、题解和来源中的链接") {
                    Menu {
                        ForEach(BrowserLinkTarget.allCases) { target in
                            Button {
                                linkTarget = target
                            } label: {
                                if linkTarget == target {
                                    Label(target.title, systemImage: "checkmark")
                                } else {
                                    Text(target.title)
                                }
                            }
                        }
                    } label: {
                        SettingsMenuLabel(text: linkTarget.title)
                            .frame(width: 170)
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                }
                CardDivider()
                SettingsToggleRow(
                    "恢复上次标签会话",
                    subtitle: "重启后恢复标签、地址和当前页",
                    isOn: $restoresSession
                )
                CardDivider()
                SettingsRow("浏览历史", subtitle: "查看、重新打开或删除已访问页面") {
                    Button("管理") { showsHistory = true }
                        .buttonStyle(SettingsPillButtonStyle())
                }
                CardDivider()
                SettingsRow("浏览数据", subtitle: "清除历史、Cookie、网站数据、缓存和标签会话") {
                    Button(isClearingData ? "正在清除…" : "清除…", role: .destructive) {
                        confirmsClearingData = true
                    }
                    .buttonStyle(SettingsPillButtonStyle(tint: .red))
                    .disabled(isClearingData)
                }
            }

            SettingsCard(title: "下载", systemImage: "arrow.down.circle", tint: .blue) {
                SettingsRow("保存位置", subtitle: downloadDirectory.path(percentEncoded: false)) {
                    Button("更改…") { chooseDownloadDirectory() }
                        .buttonStyle(SettingsPillButtonStyle())
                }
                CardDivider()
                SettingsToggleRow(
                    "下载前询问保存位置",
                    subtitle: "关闭后直接保存到上方文件夹",
                    isOn: $asksWhereToSaveDownloads
                )
            }

            if let downloadStatus = session.downloadStatus {
                Label(downloadStatus, systemImage: "arrow.down.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if !status.isEmpty {
                Text(status).font(.caption).foregroundStyle(.secondary)
            }
        }
        .onChange(of: linkTarget) { _, value in BrowserPreferences.shared.linkTarget = value }
        .onChange(of: restoresSession) { _, value in
            BrowserPreferences.shared.restoresSession = value
            session.setRestoresSession(value)
        }
        .onChange(of: asksWhereToSaveDownloads) { _, value in
            BrowserPreferences.shared.asksWhereToSaveDownloads = value
        }
        .sheet(isPresented: $showsHistory) {
            BrowserHistorySheet(workspace: workspace)
        }
        .confirmationDialog("清除所有浏览数据？", isPresented: $confirmsClearingData, titleVisibility: .visible) {
            Button("清除历史、Cookie 与缓存", role: .destructive) {
                Task {
                    isClearingData = true
                    await session.clearBrowsingData()
                    isClearingData = false
                    status = "浏览数据已清除"
                }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("所有网站会退出登录，已打开的标签和浏览历史也会被移除。")
        }
    }

    private func chooseDownloadDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = downloadDirectory
        guard panel.runModal() == .OK, let url = panel.url else { return }
        downloadDirectory = url
        BrowserPreferences.shared.downloadDirectory = url
    }
}

private struct BrowserHistorySheet: View {
    @Bindable var workspace: WorkspaceState
    @ObservedObject private var session = BrowserSession.shared
    @Environment(\.dismiss) private var dismiss
    @State private var searchText = ""

    private var entries: [BrowserHistoryEntry] {
        guard !searchText.isEmpty else { return session.history }
        return session.history.filter {
            $0.title.localizedCaseInsensitiveContains(searchText)
                || $0.url.absoluteString.localizedCaseInsensitiveContains(searchText)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("浏览历史").font(.title2.weight(.semibold))
                    Text("最多保留 500 条，点击可在内置浏览器重新打开")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("清空", role: .destructive) { session.clearHistory() }
                    .disabled(session.history.isEmpty)
                Button { dismiss() } label: { Image(systemName: "xmark").frame(width: 28, height: 28) }
                    .buttonStyle(.plain)
            }
            .padding(20)

            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("搜索历史…", text: $searchText).textFieldStyle(.plain)
            }
            .padding(.horizontal, 12)
            .frame(height: 38)
            .background(AppDesign.ColorToken.inlineFill, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .padding(.horizontal, 20)
            .padding(.bottom, 12)

            Divider()

            ZStack {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(entries) { entry in
                            HStack(spacing: 8) {
                                Button {
                                    workspace.openURL(entry.url, forceInApp: true)
                                    dismiss()
                                } label: {
                                    HStack(spacing: 12) {
                                    Image(systemName: "globe").foregroundStyle(.secondary).frame(width: 24)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(entry.title).font(.system(size: 14, weight: .medium)).lineLimit(1)
                                        Text(entry.url.absoluteString).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                    }
                                    Spacer()
                                    Text(entry.visitedAt, style: .relative).font(.caption).foregroundStyle(.tertiary)
                                    }
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                Button(role: .destructive) { session.removeHistoryEntry(entry.id) } label: {
                                    Image(systemName: "trash").frame(width: 32, height: 32)
                                }
                                .buttonStyle(.plain)
                                .help("删除这条记录")
                            }
                            .padding(.horizontal, 20)
                            .frame(height: 58)
                            Divider().padding(.leading, 56)
                        }
                    }
                }
                .floatingScrollIndicators()
                .opacity(entries.isEmpty ? 0 : 1)
                .allowsHitTesting(!entries.isEmpty)

                if entries.isEmpty {
                    ContentUnavailableView("暂无浏览历史", systemImage: "clock.arrow.circlepath")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .frame(width: 720, height: 620, alignment: .top)
    }
}

// MARK: - 个人资料

private struct ProfileSettingsPage: View {
    @Bindable var dataStore: LegacyDataStore
    @State private var usage = AIUsageSnapshot.empty
    @State private var metric = ProfileMetric.tokens
    @State private var range = ProfileActivityRange.year
    @State private var selectedDay: Date?
    @State private var hoveredDay: Date?
    @State private var activity = ProfileActivityModel.empty
    @State private var gridWidth: CGFloat = 0

    /// 格子尺寸按可用宽度反算，而不是每个档位写死一个值——
    /// 写死的话 90 天只能占左边一小条，右边全是空的。
    private var cellSize: CGFloat {
        let columns = max(1, activity.columns.count)
        let spacing = range.spacing
        // 20 是左侧星期标签列 + 它和网格之间的间距。
        let available = max(0, gridWidth - 20)
        let raw = (available - CGFloat(columns - 1) * spacing) / CGFloat(columns)
        return min(36, max(9, raw.rounded(.down)))
    }

    struct ProfileMonthMark: Identifiable, Equatable {
        var id: Int { column }
        let column: Int
        let title: String
    }

    /// 热力图要用的一切，一次算完。以前这些全是计算属性，
    /// 一次布局要重算好几遍（`activityByDay` 更是每个格子重建一次字典），
    /// 滚动直接掉帧。
    struct ProfileActivityModel: Equatable {
        var columns: [[Date?]] = []
        var monthMarks: [ProfileMonthMark] = []
        var counts: [Date: Int] = [:]
        var total = 0
        var activeDays = 0
        var currentStreak = 0
        var longestStreak = 0

        static let empty = ProfileActivityModel()

        static func make(activity: [LeetCodeActivityDay], days: Int) -> ProfileActivityModel {
            var model = ProfileActivityModel()
            let calendar = Calendar.current
            model.counts = Dictionary(
                activity.map { (calendar.startOfDay(for: $0.date), max($0.acceptedCount, $0.submissionCount)) },
                uniquingKeysWith: { first, _ in first }
            )

            let today = calendar.startOfDay(for: .now)
            guard let start = calendar.date(byAdding: .day, value: -(days - 1), to: today) else { return model }
            let weekdayOffset = calendar.component(.weekday, from: start) - 1
            guard let gridStart = calendar.date(byAdding: .day, value: -weekdayOffset, to: start) else { return model }
            let span = (calendar.dateComponents([.day], from: gridStart, to: today).day ?? 0) + 1
            let columnCount = Int(ceil(Double(span) / 7))

            var lastMonth = -1
            var run = 0
            for column in 0..<columnCount {
                var days: [Date?] = []
                for row in 0..<7 {
                    guard let day = calendar.date(byAdding: .day, value: column * 7 + row, to: gridStart),
                          day >= start, day <= today
                    else {
                        days.append(nil)
                        continue
                    }
                    days.append(day)
                    let count = model.counts[day] ?? 0
                    model.total += count
                    if count > 0 {
                        model.activeDays += 1
                        run += 1
                        model.longestStreak = max(model.longestStreak, run)
                    } else {
                        run = 0
                    }
                    if lastMonth < 0 || calendar.component(.month, from: day) != lastMonth {
                        let month = calendar.component(.month, from: day)
                        if month != lastMonth {
                            lastMonth = month
                            if model.monthMarks.last?.column != column {
                                model.monthMarks.append(ProfileMonthMark(column: column, title: "\(month) 月"))
                            }
                        }
                    }
                }
                model.columns.append(days)
            }

            // 当前连续：从今天（今天还没提交就从昨天）往回数。
            var cursor = today
            if (model.counts[cursor] ?? 0) == 0 {
                guard let yesterday = calendar.date(byAdding: .day, value: -1, to: cursor),
                      (model.counts[yesterday] ?? 0) > 0
                else { return model }
                cursor = yesterday
            }
            while (model.counts[cursor] ?? 0) > 0 {
                model.currentStreak += 1
                guard let previous = calendar.date(byAdding: .day, value: -1, to: cursor) else { break }
                cursor = previous
            }
            return model
        }
    }

    /// 四张指标卡不只是数字：选中哪张，下面就摊开哪一维的明细。
    /// 以前四个数字并排一放就完了，账本里的输入/输出/缓存/推理/工具调用全都看不到。
    private enum ProfileMetric: String, CaseIterable, Identifiable {
        case tokens, requests, conversations, submissions

        var id: String { rawValue }

        var title: String {
            switch self {
            case .tokens: "累计 Token"
            case .requests: "模型请求"
            case .conversations: "对话"
            case .submissions: "通过提交"
            }
        }

        var systemImage: String {
            switch self {
            case .tokens: "number"
            case .requests: "arrow.up.arrow.down"
            case .conversations: "bubble.left.and.bubble.right"
            case .submissions: "checkmark.seal"
            }
        }
    }

    private enum ProfileActivityRange: String, CaseIterable, Identifiable {
        case quarter, half, year

        var id: String { rawValue }

        var title: String {
            switch self {
            case .quarter: "90 天"
            case .half: "半年"
            case .year: "一年"
            }
        }

        var days: Int {
            switch self {
            case .quarter: 91
            case .half: 182
            case .year: 364
            }
        }

        var spacing: CGFloat {
            switch self {
            case .quarter: 5
            case .half: 4
            case .year: 3
            }
        }
    }

    private var displayName: String {
        let candidates = [dataStore.leetCodeProfile.displayName, dataStore.bilibiliName, NSFullUserName(), NSUserName()]
        return candidates.first { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } ?? "本机用户"
    }

    private var accountLabel: String {
        if !dataStore.leetCodeProfile.username.isEmpty { return "@\(dataStore.leetCodeProfile.username)" }
        if !dataStore.bilibiliUserID.isEmpty { return "B 站 UID \(dataStore.bilibiliUserID)" }
        return "本机资料"
    }

    private var activeModel: String {
        let provider = dataStore.providers.first { $0.id == dataStore.settings.activeProviderID }
        return provider?.model.isEmpty == false ? provider!.model : (provider?.name ?? "尚未配置模型")
    }

    private func submissions(on day: Date) -> [LeetCodeSubmission] {
        let calendar = Calendar.current
        return dataStore.leetCodeSubmissions
            .filter { calendar.isDate($0.submittedAt, inSameDayAs: day) }
            .sorted { $0.submittedAt > $1.submittedAt }
    }

    private var topTasks: [(AITaskRoute, AIUsageCounters)] {
        AITaskRoute.allCases.compactMap { route in
            usage.byTask[route.rawValue].map { (route, $0) }
        }
        .filter { $0.1.requestCount > 0 }
        .sorted { $0.1.requestCount > $1.1.requestCount }
        .prefix(5)
        .map { $0 }
    }

    var body: some View {
        SettingsScroll(maxWidth: 980) {
            VStack(spacing: 12) {
                profileAvatar
                    .frame(width: 82, height: 82)
                    .clipShape(Circle())
                Text(displayName).font(.system(size: 26, weight: .semibold))
                HStack(spacing: 7) {
                    Text(accountLabel).foregroundStyle(.secondary)
                    Text("·").foregroundStyle(.tertiary)
                    Text(activeModel)
                        .lineLimit(1)
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(AppDesign.ColorToken.inlineFill, in: Capsule())
                }
                .font(.caption)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)

            SettingsCard(title: "AI 用量", systemImage: "chart.bar.xaxis") {
                VStack(spacing: 0) {
                    HStack(spacing: 0) {
                        ForEach(ProfileMetric.allCases) { item in
                            metricTile(item)
                            if item != ProfileMetric.allCases.last {
                                Divider().frame(height: 52)
                            }
                        }
                    }
                    CardDivider()
                    metricDetail
                        .padding(.horizontal, 18)
                        .padding(.vertical, 16)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }

            SettingsCard(title: "学习活动", systemImage: "calendar") {
                VStack(alignment: .leading, spacing: 14) {
                    activityHeader
                    activityGrid
                    activityFooter
                    if let selectedDay {
                        CardDivider()
                        dayDetail(selectedDay)
                    }
                }
                .padding(18)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            if !topTasks.isEmpty {
                SettingsCard(title: "最常用的 AI 能力", systemImage: "sparkles", tint: .orange) {
                    ForEach(Array(topTasks.enumerated()), id: \.element.0.id) { index, item in
                        SettingsRow(item.0.title, subtitle: item.0.subtitle, systemImage: item.0.systemImage) {
                            Text("\(item.1.requestCount) 次")
                                .font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                        }
                        if index < topTasks.count - 1 { CardDivider() }
                    }
                }
            }
        }
        .task { await refreshUsage() }
        // 只有范围或活动数据真的变了才重算。用轻量指纹当 id，
        // 免得每次 body 求值都去比整个数组。
        .task(id: "\(range.rawValue)|\(dataStore.leetCodeActivity.count)|\(dataStore.leetCodeActivity.last?.submissionCount ?? 0)") {
            let snapshot = dataStore.leetCodeActivity
            let days = range.days
            activity = await Task.detached(priority: .userInitiated) {
                ProfileActivityModel.make(activity: snapshot, days: days)
            }.value
        }
        .onReceive(NotificationCenter.default.publisher(for: .aiUsageLedgerDidChange)) { notification in
            guard notification.object as? String == dataStore.dataDirectory.standardizedFileURL.path else { return }
            Task { await refreshUsage() }
        }
    }

    @ViewBuilder
    private var profileAvatar: some View {
        if let data = dataStore.leetCodeProfile.avatarData, let image = NSImage(data: data) {
            Image(nsImage: image).resizable().scaledToFill()
        } else if let url = dataStore.leetCodeProfile.avatarURL ?? dataStore.bilibiliAvatarURL {
            AsyncImage(url: url) { phase in
                if let image = phase.image { image.resizable().scaledToFill() }
                else { avatarFallback }
            }
        } else {
            avatarFallback
        }
    }

    private var avatarFallback: some View {
        ZStack {
            Circle().fill(Color.accentColor.opacity(0.14))
            Text(String(displayName.prefix(1)).uppercased())
                .font(.system(size: 30, weight: .medium)).foregroundStyle(Color.accentColor)
        }
    }

    // MARK: - AI 用量

    private func metricValue(_ item: ProfileMetric) -> String {
        switch item {
        case .tokens: usage.totals.totalTokens.formatted()
        case .requests: usage.totals.requestCount.formatted()
        case .conversations: dataStore.conversations.count.formatted()
        case .submissions: dataStore.leetCodeSubmissions.count { $0.accepted }.formatted()
        }
    }

    private func metricTile(_ item: ProfileMetric) -> some View {
        Button {
            metric = item
        } label: {
            VStack(spacing: 5) {
                Text(metricValue(item))
                    .font(.system(size: 25, weight: .semibold).monospacedDigit())
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                HStack(spacing: 4) {
                    Image(systemName: item.systemImage)
                        .font(.system(size: 10, weight: .semibold))
                    Text(item.title)
                        .font(.caption)
                }
                .foregroundStyle(metric == item ? Color.accentColor : .secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(metric == item ? Color.accentColor.opacity(0.07) : .clear)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(metric == item ? Color.accentColor : .clear)
                .frame(height: 2)
        }
    }

    @ViewBuilder
    private var metricDetail: some View {
        let totals = usage.totals
        switch metric {
        case .tokens:
            VStack(alignment: .leading, spacing: 12) {
                proportionBar([
                    ("输入", totals.promptTokens, Color.accentColor.opacity(0.55)),
                    ("输出", totals.completionTokens, Color.accentColor),
                    ("推理", totals.reasoningTokens, .purple)
                ])
                statGrid([
                    ("输入 Token", totals.promptTokens.formatted()),
                    ("输出 Token", totals.completionTokens.formatted()),
                    ("推理 Token", totals.reasoningTokens.formatted()),
                    ("缓存命中", totals.cacheSupported ? totals.cachedTokens.formatted() : "供应商不支持")
                ])
            }
        case .requests:
            VStack(alignment: .leading, spacing: 12) {
                proportionBar([
                    ("成功", totals.succeededRequests, AppDesign.ColorToken.success),
                    ("失败", totals.failedRequests, AppDesign.ColorToken.warning)
                ])
                statGrid([
                    ("成功", totals.succeededRequests.formatted()),
                    ("失败", totals.failedRequests.formatted()),
                    ("精确计量", totals.exactRequests.formatted()),
                    ("估算计量", totals.estimatedRequests.formatted())
                ])
                if totals.toolCalls > 0 {
                    statGrid([("工具调用", totals.toolCalls.formatted())]
                        + totals.toolUsage
                            .sorted { $0.value > $1.value }
                            .prefix(3)
                            .map { ($0.key, $0.value.formatted()) })
                }
            }
        case .conversations:
            statGrid([
                ("会话总数", dataStore.conversations.count.formatted()),
                ("已归档摘要", dataStore.conversations.count { !$0.aiSummary.isEmpty }.formatted()),
                ("已置顶", dataStore.conversations.count(where: \.isPinned).formatted()),
                ("消息总数", dataStore.conversations.reduce(0) { $0 + $1.messageCount }.formatted())
            ])
        case .submissions:
            let all = dataStore.leetCodeSubmissions
            let accepted = all.count { $0.accepted }
            statGrid([
                ("通过", accepted.formatted()),
                ("总提交", all.count.formatted()),
                ("通过率", all.isEmpty ? "—" : "\(Int((Double(accepted) / Double(all.count) * 100).rounded()))%"),
                ("覆盖题目", Set(all.map(\.titleSlug)).count.formatted())
            ])
        }
    }

    /// 占比条：只画有值的段，全 0 时退化成一条底色，不留空洞。
    ///
    /// 用 `Canvas` 而不是 `GeometryReader`：GeometryReader 放在 ScrollView 里
    /// 每次滚动都会触发一轮布局失效，是这一页掉帧的另一半原因。
    private func proportionBar(_ parts: [(String, Int, Color)]) -> some View {
        let total = parts.reduce(0) { $0 + max($1.1, 0) }
        let segments = parts.filter { $0.1 > 0 }
        return VStack(alignment: .leading, spacing: 7) {
            Canvas(opaque: false, rendersAsynchronously: false) { context, size in
                let radius = size.height / 2
                guard total > 0 else {
                    context.fill(
                        Path(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: radius),
                        with: .color(.primary.opacity(0.06))
                    )
                    return
                }
                var x: CGFloat = 0
                for part in segments {
                    let width = max(3, size.width * Double(part.1) / Double(total))
                    let rect = CGRect(x: x, y: 0, width: width, height: size.height)
                    context.fill(Path(roundedRect: rect, cornerRadius: radius), with: .color(part.2))
                    x += width + 2
                    if x >= size.width { break }
                }
            }
            .frame(height: 8)
            HStack(spacing: 12) {
                ForEach(segments, id: \.0) { part in
                    HStack(spacing: 5) {
                        Circle().fill(part.2).frame(width: 6, height: 6)
                        Text(part.0).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private func statGrid(_ items: [(String, String)]) -> some View {
        LazyVGrid(
            columns: Array(repeating: GridItem(.flexible(), alignment: .leading), count: 4),
            alignment: .leading,
            spacing: 10
        ) {
            ForEach(items, id: \.0) { item in
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.1)
                        .font(.system(size: 15, weight: .medium).monospacedDigit())
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                    Text(item.0).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
        }
    }

    // MARK: - 学习活动

    private var activityHeader: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text("\(activity.total) 次提交")
                .font(.system(size: 15, weight: .semibold).monospacedDigit())
            Text("· 活跃 \(activity.activeDays) 天 · 当前连续 \(activity.currentStreak) 天 · 最长 \(activity.longestStreak) 天")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Picker("", selection: $range) {
                ForEach(ProfileActivityRange.allCases) { item in
                    Text(item.title).tag(item)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 190)
        }
    }

    /// 整张热力图画在一个 `Canvas` 里。
    ///
    /// 之前是 364 个独立 `Button`，每个还挂了 `.onHover` 和 `.help()`——
    /// AppKit 要维护 364 个 tracking area，滚动时每帧都要重算，页面就卡死了；
    /// 加上 `activityByDay` 当时是计算属性，每取一个格子就重建一遍整张字典。
    /// 现在数据一次性算好放进 `activity`，视图收敛成一个绘制层。
    private var activityGrid: some View {
        let cell = cellSize
        let spacing = range.spacing
        let step = cell + spacing
        let width = max(0, CGFloat(activity.columns.count) * step - spacing)
        let height = 7 * step - spacing
        return HStack(alignment: .top, spacing: 6) {
            VStack(spacing: spacing) {
                ForEach(0..<7, id: \.self) { row in
                    Text(["", "一", "", "三", "", "五", ""][row])
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                        .frame(width: 14, height: cell, alignment: .trailing)
                }
            }
            .padding(.top, 15)

            VStack(alignment: .leading, spacing: 3) {
                ZStack(alignment: .topLeading) {
                    Color.clear.frame(height: 12)
                    ForEach(activity.monthMarks) { mark in
                        Text(mark.title)
                            .font(.system(size: 9))
                            .foregroundStyle(.tertiary)
                            .fixedSize()
                            .offset(x: CGFloat(mark.column) * step)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .clipped()

                Canvas(opaque: false, rendersAsynchronously: false) { context, _ in
                    let radius: CGFloat = cell > 20 ? 6 : 3
                    for (columnIndex, column) in activity.columns.enumerated() {
                        for row in 0..<7 {
                            guard let day = column[row] else { continue }
                            let rect = CGRect(
                                x: CGFloat(columnIndex) * step,
                                y: CGFloat(row) * step,
                                width: cell,
                                height: cell
                            )
                            let count = activity.counts[day] ?? 0
                            let path = Path(roundedRect: rect, cornerRadius: radius, style: .continuous)
                            context.fill(path, with: .color(activityColor(count)))
                            if day == selectedDay {
                                context.stroke(path, with: .color(.primary), lineWidth: 1.5)
                            } else if day == hoveredDay {
                                context.stroke(path, with: .color(.primary.opacity(0.35)), lineWidth: 1)
                            }
                            // 90 天视图格子够大，直接把日期写进去，不用靠悬停猜。
                            if cell > 20 {
                                let text = Text("\(Calendar.current.component(.day, from: day))")
                                    .font(.system(size: 9, weight: .medium).monospacedDigit())
                                    .foregroundStyle(count >= 4 ? Color.white.opacity(0.9) : Color.secondary)
                                context.draw(text, at: CGPoint(x: rect.midX, y: rect.midY))
                            }
                        }
                    }
                }
                .frame(width: width, height: height)
                .contentShape(Rectangle())
                // 一个 hover 区域代替 364 个：命中测试自己按格子算。
                .onContinuousHover { phase in
                    switch phase {
                    case .active(let location):
                        hoveredDay = day(at: location, step: step, cell: cell)
                    case .ended:
                        hoveredDay = nil
                    }
                }
                .gesture(
                    SpatialTapGesture().onEnded { value in
                        guard let day = day(at: value.location, step: step, cell: cell) else { return }
                        // 再点一次收起，避免详情面板卡在下面赶不走。
                        selectedDay = (selectedDay == day) ? nil : day
                    }
                )
                .accessibilityElement()
                .accessibilityLabel(
                    "学习活动热力图，\(range.title)内共 \(activity.total) 次提交，活跃 \(activity.activeDays) 天"
                )
            }
        }
        // onGeometryChange 只在尺寸真的变了才回调，不像 GeometryReader
        // 会在滚动时反复触发布局。
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width in
            if abs(width - gridWidth) > 0.5 { gridWidth = width }
        }
    }

    /// 画布坐标 → 具体哪一天。落在格子间距上就算没命中，避免手抖选错日期。
    private func day(at location: CGPoint, step: CGFloat, cell: CGFloat) -> Date? {
        guard location.x >= 0, location.y >= 0 else { return nil }
        let column = Int(location.x / step)
        let row = Int(location.y / step)
        guard row < 7, column < activity.columns.count else { return nil }
        guard location.x - CGFloat(column) * step <= cell,
              location.y - CGFloat(row) * step <= cell
        else { return nil }
        return activity.columns[column][row]
    }

    private var activityFooter: some View {
        HStack(spacing: 8) {
            // 悬停信息挪到这里显示。Canvas 里没法给单个格子挂 tooltip，
            // 而且常驻一行比等 tooltip 弹出来更快看到。
            if let hoveredDay {
                Text("\(hoveredDay.formatted(date: .abbreviated, time: .omitted))：\(activity.counts[hoveredDay] ?? 0) 次提交")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            } else {
                Text(dataStore.leetCodeActivity.isEmpty ? "连接 LeetCode 后显示真实提交活动" : "点击某一天查看当天提交")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Text("少").font(.system(size: 9)).foregroundStyle(.tertiary)
            ForEach([0, 1, 2, 5, 9], id: \.self) { level in
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .fill(activityColor(level))
                    .frame(width: 11, height: 11)
            }
            Text("多").font(.system(size: 9)).foregroundStyle(.tertiary)
        }
    }

    @ViewBuilder
    private func dayDetail(_ day: Date) -> some View {
        let items = submissions(on: day)
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 8) {
                Text(day.formatted(.dateTime.year().month(.wide).day().weekday(.wide)))
                    .font(.system(size: 13, weight: .semibold))
                Text("\(items.count) 次提交 · 通过 \(items.count { $0.accepted })")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                Spacer(minLength: 8)
                Button { selectedDay = nil } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 22, height: 22)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
            }
            if items.isEmpty {
                Text("这一天没有提交记录")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(items.prefix(12)) { item in
                    HStack(spacing: 9) {
                        Circle()
                            .fill(item.accepted ? AppDesign.ColorToken.success : AppDesign.ColorToken.warning)
                            .frame(width: 6, height: 6)
                        Text(item.title)
                            .font(.callout)
                            .lineLimit(1)
                        Text(item.status)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        Spacer(minLength: 8)
                        Text(item.language)
                            .font(.caption.monospaced())
                            .foregroundStyle(.tertiary)
                        Text(item.submittedAt.formatted(date: .omitted, time: .shortened))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.tertiary)
                    }
                }
                if items.count > 12 {
                    Text("还有 \(items.count - 12) 条…")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }

    private func activityColor(_ count: Int) -> Color {
        switch count {
        case 0: Color.primary.opacity(0.055)
        case 1: Color.accentColor.opacity(0.25)
        case 2...3: Color.accentColor.opacity(0.48)
        case 4...6: Color.accentColor.opacity(0.72)
        default: Color.accentColor
        }
    }

    @MainActor
    private func refreshUsage() async {
        usage = await AIUsageLedger.shared.snapshot(dataDirectory: dataStore.dataDirectory)
    }
}

// MARK: - 模型供应商

private struct ProviderSettingsPage: View {
    let dataStore: LegacyDataStore
    let openInBrowser: (URL) -> Void
    @State private var model: ProviderSettingsModel

    init(dataStore: LegacyDataStore, openInBrowser: @escaping (URL) -> Void) {
        self.dataStore = dataStore
        self.openInBrowser = openInBrowser
        _model = State(initialValue: ProviderSettingsModel(dataStore: dataStore))
    }

    var body: some View {
        SettingsScroll {
            VStack(alignment: .leading, spacing: 10) {
                SettingsCard(title: "已配置") {
                    ForEach(Array(dataStore.providers.enumerated()), id: \.element.id) { index, provider in
                        if index > 0 { CardDivider() }
                        providerRow(provider)
                    }
                }

                HStack(spacing: 8) {
                    Button { model.addProvider() } label: { Label("添加供应商", systemImage: "plus") }
                        .buttonStyle(SettingsPillButtonStyle())
                        .help("添加 OpenAI 兼容供应商")
                    Button {
                        if let id = model.selectedProvider?.id { model.requestDelete(id) }
                    } label: { Label("删除", systemImage: "minus") }
                        .buttonStyle(SettingsPillButtonStyle(tint: .red))
                        // 判反过：内置三家才有 assetName，自定义的是 nil。
                        // 原来的写法是"能删内置、删不掉自己加的"。
                        .disabled(!model.canRename)
                        .help("删除自定义供应商")
                    Spacer()
                }
                .padding(.leading, 4)
                .padding(.top, 2)
            }

            if let provider = model.selectedProvider {
                detailSection(provider)
            } else {
                ContentUnavailableView("没有模型供应商", systemImage: "cpu")
            }

            VStack(alignment: .leading, spacing: 8) {
                SettingsCard(title: "任务模型路由") {
                    ForEach(Array(AITaskRoute.allCases.enumerated()), id: \.element.id) { index, route in
                        routeRow(route)
                        if index < AITaskRoute.allCases.count - 1 {
                            CardDivider()
                        }
                    }
                }
                Text("路由是全局策略：未单独指定的任务跟随默认供应商。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 4)
            }

        }
        .onChange(of: dataStore.lastReloadedAt) { _, _ in
            model.storeDidChange()
        }
        .onDisappear { model.teardown() }
        .confirmationDialog(
            "删除供应商",
            isPresented: Binding(
                get: { model.pendingDeleteID != nil },
                set: { if !$0 { model.pendingDeleteID = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("删除「\(model.pendingDeleteProvider?.name ?? "")」", role: .destructive) {
                model.confirmDelete()
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("将移除该供应商的配置与本机保存的 API Key，此操作不可撤销。")
        }
    }

    private func statusColor(_ status: ProviderSettingsModel.Status) -> Color {
        switch status.kind {
        case .success: AppDesign.ColorToken.success
        case .error: AppDesign.ColorToken.warning
        case .info: .secondary
        }
    }

    private func providerRow(_ provider: ProviderRecord) -> some View {
        let isActive = provider.id == dataStore.settings.activeProviderID
        let isSelected = model.selectedProvider?.id == provider.id
        return Button {
            model.select(provider.id)
        } label: {
            HStack(spacing: 12) {
                ProviderMark(assetName: provider.assetName, size: 26)
                VStack(alignment: .leading, spacing: 2) {
                    Text(provider.name)
                        .font(.system(size: 15, weight: .medium))
                    Text(provider.model.isEmpty ? "未设置模型" : provider.model)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                Circle()
                    .fill(provider.isConfigured ? AppDesign.ColorToken.success : Color.secondary)
                    .frame(width: 7, height: 7)
                Text("默认")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(AppDesign.ColorToken.success)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(AppDesign.ColorToken.success.opacity(0.12), in: Capsule())
                    .opacity(isActive ? 1 : 0)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
            .background(
                isSelected ? Color.primary.opacity(0.06) : .clear,
                in: RoundedRectangle(cornerRadius: 9, style: .continuous)
            )
            .padding(.horizontal, 6)
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("设为默认", systemImage: "star") { model.activate(provider.id) }
                .disabled(isActive)
            if provider.assetName == nil {
                Divider()
                Button("删除供应商", systemImage: "trash", role: .destructive) {
                    model.requestDelete(provider.id)
                }
            }
        }
    }

    private func detailSection(_ provider: ProviderRecord) -> some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 14) {
                ProviderMark(assetName: provider.assetName, size: 30)
                    .frame(width: 52, height: 52)
                    .background(
                        AppDesign.ColorToken.inlineFill,
                        in: RoundedRectangle(cornerRadius: 12, style: .continuous)
                    )
                    .overlay {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .strokeBorder(Color.primary.opacity(0.06))
                    }
                VStack(alignment: .leading, spacing: 3) {
                    Text(provider.name)
                        .font(AppDesign.Typography.pageTitle)
                    Label(
                        provider.isConfigured ? "API Key 已配置" : "需要配置 API Key",
                        systemImage: provider.isConfigured ? "checkmark.circle.fill" : "exclamationmark.circle"
                    )
                    .font(AppDesign.Typography.body)
                    .foregroundStyle(provider.isConfigured ? AppDesign.ColorToken.success : AppDesign.ColorToken.warning)
                }
                Spacer()
                Button("设为默认") { model.activate(provider.id) }
                    .buttonStyle(SettingsPillButtonStyle())
                    .disabled(provider.id == dataStore.settings.activeProviderID)
            }
            .padding(.horizontal, 4)

            SettingsCard(title: "连接") {
                if model.canRename {
                    // 自定义供应商可以自己命名；内置三家的名字与图标资源绑定，不给改。
                    SettingsRow("名称", subtitle: "显示在供应商列表与模型菜单里") {
                        TextField("自定义供应商", text: $model.nameDraft)
                            .settingsInputSurface()
                            .frame(width: 340)
                    }
                    CardDivider()
                }
                SettingsRow("API 地址", subtitle: model.apiBaseIssue) {
                    TextField("https://api.example.com", text: $model.apiBaseDraft)
                        .settingsInputSurface()
                        .frame(width: 340)
                }
                CardDivider()
                SettingsRow("API Key") {
                    VStack(alignment: .trailing, spacing: 8) {
                        SecureField(provider.isConfigured ? "已安全保存，留空表示不修改" : "输入 API Key", text: $model.apiKeyDraft)
                            .settingsInputSurface()
                            .frame(width: 340)
                        if let links = quickLinks {
                            HStack(spacing: 8) {
                                ForEach(links) { link in
                                    Button {
                                        if let url = URL(string: link.urlString) {
                                            openInBrowser(url)
                                        }
                                    } label: {
                                        Label(link.title, systemImage: link.systemImage)
                                    }
                                    .buttonStyle(ProviderLinkCapsuleStyle())
                                    .help(link.urlString)
                                }
                            }
                        }
                    }
                }
                CardDivider()
                SettingsRow("响应模式") {
                    SettingsMenuPicker(selection: $model.responseMode, options: ["自动", "Chat Completions", "Responses"])
                        .frame(width: 200)
                }
            }

            SettingsCard(title: "默认模型") {
                SettingsRow("模型") {
                    HStack(spacing: 8) {
                        // 永远可手输：拉到模型列表后就换成只读 Picker 的话，
                        // 代理网关、私有部署、刚发布还没进 /v1/models 的模型就再也填不进去了
                        // （原项目那边是个 combobox，占位符写的就是"搜索或输入模型"）。
                        SettingsModelCombo(
                            selection: $model.modelDraft,
                            options: model.availableModels
                        )
                        Button { model.fetchModels() } label: {
                            if model.isFetchingModels {
                                ProgressView()
                                    .controlSize(.small)
                                    .frame(width: 30, height: 30)
                            } else {
                                Image(systemName: "arrow.clockwise")
                                    .font(.system(size: 13, weight: .medium))
                                    .frame(width: 30, height: 30)
                            }
                        }
                        .buttonStyle(.plain)
                        .glassCircle()
                        .disabled(model.isFetchingModels || (!provider.isConfigured && model.apiKeyDraft.isEmpty))
                        .help("获取供应商全部模型")
                    }
                    .frame(width: 340)
                }
                if !model.availableModels.isEmpty {
                    CardDivider()
                    SettingsRow("可用模型", subtitle: "从供应商实时获取") {
                        Text("\(model.availableModels.count) 个")
                            .font(.system(size: 13).monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
                CardDivider()
                SettingsRow("推理能力") {
                    Label("支持按任务覆盖", systemImage: "point.3.connected.trianglepath.dotted")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                }
            }

            HStack(spacing: 10) {
                Button("测试连接", systemImage: "bolt.horizontal.circle") { model.testConnection() }
                    .buttonStyle(SettingsPillButtonStyle())
                    .disabled(model.isTestingConnection || (!provider.isConfigured && model.apiKeyDraft.isEmpty))
                if model.isTestingConnection { ProgressView().controlSize(.small) }
                if let status = model.status {
                    Text(status.text)
                        .font(AppDesign.Typography.aux)
                        .foregroundStyle(statusColor(status))
                        .lineLimit(2)
                }
                Spacer()
            }
        }
    }

    private func routeRow(_ route: AITaskRoute) -> some View {
        HStack(spacing: 14) {
            Image(systemName: route.systemImage)
                .font(.system(size: 15))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.secondary)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(route.title)
                    .font(.system(size: 15, weight: .medium))
                Text(route.subtitle)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(width: 245, alignment: .leading)
            Spacer(minLength: 16)
            Menu {
                Button("跟随默认") { model.saveRoute(route.rawValue, providerID: nil) }
                Divider()
                ForEach(dataStore.providers.filter(\.isConfigured)) { provider in
                    Button(provider.name) { model.saveRoute(route.rawValue, providerID: provider.id) }
                }
            } label: {
                SettingsMenuLabel(text: routeName(for: route.rawValue))
                    .frame(width: 190)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var quickLinks: [ProviderQuickLink]? {
        guard let provider = model.selectedProvider else { return nil }
        let haystack = "\(provider.name) \(model.apiBaseDraft)".lowercased()
        if haystack.contains("deepseek") { return ProviderQuickLink.deepSeek }
        if haystack.contains("opencode") { return ProviderQuickLink.openCode }
        return nil
    }

    private func routeName(for key: String) -> String {
        guard let id = dataStore.settings.taskRoutes[key], !id.isEmpty else { return "跟随默认" }
        return dataStore.providers.first { $0.id == id && $0.isConfigured }?.name ?? "跟随默认"
    }
}

// MARK: - 上下文

private struct ContextSettingsPage: View {
    @Bindable var dataStore: LegacyDataStore
    @State private var window: Double
    @State private var reserved: Double
    @State private var compression: Double
    @State private var postCompression: Double
    @State private var recentMessages: Double
    @State private var maxImages: Double
    @State private var saveStatus = ""
    @State private var memoryFacts: [ConversationMemoryFact] = []

    init(dataStore: LegacyDataStore) {
        self.dataStore = dataStore
        let snapshot = dataStore.settings
        _window = State(initialValue: snapshot.contextWindowTokens)
        _reserved = State(initialValue: snapshot.reservedOutputTokens)
        _compression = State(initialValue: snapshot.compressionThreshold)
        _postCompression = State(initialValue: snapshot.postCompressionRatio)
        _recentMessages = State(initialValue: snapshot.recentMessages)
        _maxImages = State(initialValue: snapshot.maxImages)
    }

    var body: some View {
        SettingsScroll {
            HStack {
                Button("应用 1M 推荐值", systemImage: "wand.and.stars") {
                    window = 1_048_576
                    reserved = 32_768
                    compression = 0.90
                    postCompression = 0.75
                    recentMessages = 16
                    maxImages = 6
                    saveStatus = "已应用推荐值，点击保存生效"
                }
                .buttonStyle(SettingsPillButtonStyle())
                Spacer()
                if !saveStatus.isEmpty {
                    Text(saveStatus).font(.caption).foregroundStyle(.secondary)
                }
            }

            SettingsCard(title: "Token 预算", systemImage: "chart.bar.fill", tint: .blue) {
                SettingsSliderRow("上下文窗口", valueText: tokenCapacity(window)) {
                    Slider(value: $window, in: 32_768...1_048_576, step: 32_768).tint(.blue)
                }
                CardDivider()
                SettingsSliderRow("预留输出", valueText: tokenCapacity(reserved)) {
                    Slider(value: $reserved, in: 4_096...131_072, step: 4_096).tint(.cyan)
                }
            }

            SettingsCard(title: "压缩策略", systemImage: "arrow.down.right.and.arrow.up.left", tint: .orange) {
                SettingsSliderRow("触发阈值", valueText: compression.formatted(.percent)) {
                    Slider(value: $compression, in: 0.80...0.98, step: 0.01).tint(.orange)
                }
                CardDivider()
                SettingsSliderRow("压缩后占比", valueText: postCompression.formatted(.percent)) {
                    Slider(value: $postCompression, in: 0.60...0.90, step: 0.01).tint(.purple)
                }
            }

            SettingsCard(title: "保留内容", systemImage: "bookmark.fill", tint: .green) {
                SettingsSliderRow("最近消息", valueText: "\(Int(recentMessages)) 条") {
                    Slider(value: $recentMessages, in: 4...30, step: 1).tint(.green)
                }
                CardDivider()
                SettingsSliderRow("最多图片", valueText: "\(Int(maxImages)) 张") {
                    Slider(value: $maxImages, in: 0...12, step: 1).tint(.pink)
                }
            }

            SettingsCard(title: "跨对话记忆", systemImage: "brain", tint: .indigo) {
                VStack(alignment: .leading, spacing: 10) {
                    Text("模型每轮常驻拿到「长期事实」与会话目录；只有当你提到「上次」「我的」，或用到旧会话标题里的词时，才会额外跑一次全量检索。")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("长期事实由「跨对话记忆整合」这条任务路由在后台离线生成，可在上面的模型路由里单独指定模型。存储在 memory-facts.json，可直接编辑。")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(14)

                CardDivider()

                if memoryFacts.isEmpty {
                    Text("还没有沉淀出长期事实。多聊几轮、生成过会话摘要之后会自动整合。")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(14)
                } else {
                    ForEach(Array(memoryFacts.enumerated()), id: \.element.id) { index, fact in
                        HStack(spacing: 10) {
                            Text(fact.kindTitle)
                                .font(.caption2.weight(.medium))
                                .padding(.horizontal, 7)
                                .padding(.vertical, 2)
                                .background(Color.indigo.opacity(0.12), in: Capsule())
                            Text(fact.text)
                                .font(.callout)
                                .fixedSize(horizontal: false, vertical: true)
                            Spacer(minLength: 8)
                            // 记错了删不掉，比记错本身更伤信任。
                            Button {
                                Task { await removeFact(fact.id) }
                            } label: {
                                Image(systemName: "trash")
                                    .font(.system(size: 11))
                                    .foregroundStyle(.secondary)
                                    .frame(width: 24, height: 24)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .help("删除这条记忆")
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 9)
                        if index < memoryFacts.count - 1 { CardDivider() }
                    }
                }
            }

            HStack {
                if !memoryFacts.isEmpty {
                    Button("清空长期记忆", systemImage: "trash") {
                        Task { await clearFacts() }
                    }
                    .buttonStyle(SettingsPillButtonStyle())
                    .foregroundStyle(AppDesign.ColorToken.warning)
                }
                Spacer()
                Button("保存上下文策略") { savePolicy() }
                    .buttonStyle(.borderedProminent)
                    .buttonBorderShape(.capsule)
                    .controlSize(.large)
            }
        }
        .task { await reloadFacts() }
    }

    private func reloadFacts() async {
        memoryFacts = await ConversationMemoryFactStore.shared.facts(dataDirectory: dataStore.dataDirectory)
    }

    private func removeFact(_ id: String) async {
        await ConversationMemoryFactStore.shared.remove(id: id, dataDirectory: dataStore.dataDirectory)
        await reloadFacts()
    }

    private func clearFacts() async {
        await ConversationMemoryFactStore.shared.removeAll(dataDirectory: dataStore.dataDirectory)
        await reloadFacts()
    }

    private func savePolicy() {
        do {
            try dataStore.saveContextPolicy(
                window: window,
                reserved: min(reserved, window - 4_096),
                compression: compression,
                postCompression: min(postCompression, compression),
                recentMessages: recentMessages,
                maxImages: maxImages
            )
            saveStatus = "已保存"
        } catch {
            saveStatus = "保存失败：\(error.localizedDescription)"
        }
    }

    private func tokenCapacity(_ value: Double) -> String {
        value >= 1_048_576 ? "1M" : "\(Int(value / 1_024))K"
    }
}

// MARK: - B站视频

private struct VideoSettingsPage: View {
    @Bindable var dataStore: LegacyDataStore
    let openInBrowser: (URL) -> Void
    @State private var operationStatus = ""
    @State private var isHistoryExpanded = false

    var body: some View {
        SettingsScroll {
            SettingsCard(title: "播放历史") {
                Button {
                    withAnimation(AppDesign.Motion.selection) {
                        isHistoryExpanded.toggle()
                    }
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "clock.arrow.circlepath")
                            .font(.system(size: 16, weight: .medium))
                            .symbolRenderingMode(.hierarchical)
                            .foregroundStyle(.secondary)
                            .frame(width: 24)
                        VStack(alignment: .leading, spacing: 3) {
                            Text("本地播放历史")
                                .font(.system(size: 14, weight: .medium))
                            Text(dataStore.videoHistoryCount == 0
                                 ? "尚无记录"
                                 : "\(dataStore.videoHistoryCount) 条·点击视频在右侧浏览器播放")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.tertiary)
                            .rotationEffect(.degrees(isHistoryExpanded ? 90 : 0))
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 14)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(dataStore.videoHistory.isEmpty)

                if isHistoryExpanded, !dataStore.videoHistory.isEmpty {
                    CardDivider()
                    ForEach(dataStore.videoHistory.prefix(30)) { item in
                        Button {
                            guard let url = item.playbackURL else { return }
                            openInBrowser(url)
                        } label: {
                            HStack(spacing: 16) {
                                AsyncImage(url: item.coverURL) { image in
                                    image.resizable().scaledToFill()
                                } placeholder: {
                                    Color.primary.opacity(0.04)
                                }
                                .frame(width: 128, height: 72)
                                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

                                VStack(alignment: .leading, spacing: 3) {
                                    Text(item.title)
                                        .font(AppDesign.Typography.rowTitle)
                                        .lineLimit(2)
                                        .fixedSize(horizontal: false, vertical: true)
                                    Text(videoProgress(item))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Image(systemName: "rectangle.righthalf.inset.filled.arrow.right")
                                    .font(.system(size: 13))
                                    .symbolRenderingMode(.hierarchical)
                                    .foregroundStyle(.tertiary)
                                    .frame(width: 28, height: 28)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .frame(minHeight: 96)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 10)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .background(.primary.opacity(0.001), in: RoundedRectangle(cornerRadius: 7))
                    }
                }
                CardDivider()
                SettingsRow("清空本地记录", subtitle: operationStatus.isEmpty ? nil : operationStatus) {
                    Button("清空", role: .destructive) { clearHistory() }
                        .buttonStyle(SettingsPillButtonStyle(tint: .red))
                        .disabled(dataStore.videoHistoryCount == 0)
                }
            }
        }
    }

    private func videoProgress(_ item: VideoHistoryEntry) -> String {
        let watched = item.duration > 0 ? min(100, Int(item.progress * 100)) : 0
        let date = item.lastOpenedAt == .distantPast
            ? "时间未知"
            : item.lastOpenedAt.formatted(date: .abbreviated, time: .shortened)
        return "已看 \(watched)% · 打开 \(item.openCount) 次 · \(date)"
    }

    private func clearHistory() {
        do {
            try dataStore.clearVideoHistory()
            operationStatus = "已清空本地播放历史"
        } catch {
            operationStatus = "清空失败：\(error.localizedDescription)"
        }
    }
}

// MARK: - 学习与复习

private struct LearningSettingsPage: View {
    @Bindable var dataStore: LegacyDataStore
    @State private var dailyNew = 3.0
    @State private var weekdayReview = 4.0
    @State private var weeklyReview = 12.0
    @State private var language = "Java"

    var body: some View {
        SettingsScroll {
            SettingsCard(title: "复习计划") {
                stepperRow("每日新知识", value: $dailyNew, range: 0...20)
                CardDivider()
                stepperRow("工作日复习", value: $weekdayReview, range: 0...30)
                CardDivider()
                stepperRow("每周复习", value: $weeklyReview, range: 0...50)
            }

            SettingsCard(title: "代码偏好") {
                SettingsRow("默认语言", subtitle: "代码题解与模板使用的编程语言") {
                    GlassSegmentedControl(
                        options: [("Java", "Java"), ("C++", "C++"), ("Python", "Python")],
                        selection: $language
                    )
                    .frame(width: 210)
                }
            }

            SettingsCard(title: "数据") {
                SettingsRow("知识点") {
                    Text("\(dataStore.learningRecords.count)")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                CardDivider()
                SettingsRow("待复习") {
                    Text("\(dataStore.dueCount)")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                CardDivider()
                SettingsRow("学习数据", subtitle: "导出全部学习记录与复习证据") {
                    Button("导出…") { exportLearningData() }
                        .buttonStyle(SettingsPillButtonStyle())
                }
            }
        }
    }

    private func stepperRow(_ title: String, value: Binding<Double>, range: ClosedRange<Double>) -> some View {
        SettingsRow(title) {
            HStack(spacing: 10) {
                Text("\(Int(value.wrappedValue)) 项")
                    .font(.system(size: 13, weight: .medium))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                HStack(spacing: 0) {
                    Button {
                        value.wrappedValue = max(range.lowerBound, value.wrappedValue - 1)
                    } label: {
                        Image(systemName: "minus")
                            .frame(width: 26, height: 24)
                    }
                    .disabled(value.wrappedValue <= range.lowerBound)
                    Rectangle()
                        .fill(Color.primary.opacity(0.08))
                        .frame(width: 1, height: 14)
                    Button {
                        value.wrappedValue = min(range.upperBound, value.wrappedValue + 1)
                    } label: {
                        Image(systemName: "plus")
                            .frame(width: 26, height: 24)
                    }
                    .disabled(value.wrappedValue >= range.upperBound)
                }
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .buttonStyle(.plain)
                .glassCapsule()
            }
        }
    }

    private func exportLearningData() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "leetcode-learning-export.json"
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try dataStore.learningExportData().write(to: url, options: .atomic)
        } catch {
            NSAlert(error: error).runModal()
        }
    }
}

// MARK: - 账户连接

private struct AccountSettingsPage: View {
    @Bindable var dataStore: LegacyDataStore
    @State private var status = ""
    @State private var loginProvider: EmbeddedLoginProvider?
    @State private var websiteSessions: [WebsiteSessionSite: Bool] = [:]
    @State private var clearingSite: WebsiteSessionSite?

    var body: some View {
        SettingsScroll {
            SettingsCard(title: "LeetCode 中国站") {
                SettingsRow(
                    dataStore.leetCodeSignedIn ? dataStore.leetCodeUsername : "尚未登录",
                    subtitle: dataStore.leetCodeSignedIn ? "已同步 \(dataStore.leetCodeQuestions.count) 道题与 \(dataStore.leetCodeSubmissions.count) 条提交" : "在软件内使用微信扫码登录，会话只保存在本机",
                    systemImage: "curlybraces.square"
                ) {
                    sessionControls(.leetcode, primaryTitle: dataStore.leetCodeSignedIn ? "重新登录与同步" : "微信扫码登录…")
                }
            }

            SettingsCard(title: "哔哩哔哩") {
                SettingsRow(
                    dataStore.bilibiliSignedIn ? "已连接 B 站" : "尚未登录",
                    subtitle: dataStore.bilibiliSignedIn
                        ? (dataStore.bilibiliUserID.isEmpty ? "官方 Web 会话" : "UID \(dataStore.bilibiliUserID) · 官方 Web 会话")
                        : "使用 B 站客户端扫码登录，提升视频检索与播放权限",
                    systemImage: "play.rectangle"
                ) {
                    sessionControls(.bilibili, primaryTitle: dataStore.bilibiliSignedIn ? "检查状态" : "扫码登录…")
                }
            }
            if !status.isEmpty {
                Text(status).font(.caption).foregroundStyle(.secondary)
            }
        }
        .sheet(item: $loginProvider) { provider in
            EmbeddedAccountLoginView(
                provider: provider,
                leetcodePlanSlug: activeLeetCodeLoginPlanSlug
            ) { result in
                do {
                    switch result {
                    case .leetcode(let account, let submissions, let studyPlan):
                        try dataStore.applyLeetCodeWebSync(
                            account: account,
                            submissions: submissions,
                            studyPlan: studyPlan
                        )
                        status = "LeetCode 登录成功，用户资料、题库与最近提交已同步"
                    case .bilibili(let userID, let name, let avatar):
                        try dataStore.applyBilibiliWebLogin(userID: userID, name: name, avatar: avatar)
                        status = "B 站登录成功"
                    }
                    Task { websiteSessions = await WebsiteSessionStore.authenticationStates() }
                } catch {
                    status = error.localizedDescription
                }
            }
            .frame(minWidth: 820, idealWidth: 960, minHeight: 620, idealHeight: 720)
        }
        .task { websiteSessions = await WebsiteSessionStore.authenticationStates() }
    }

    private var activeLeetCodeLoginPlanSlug: String {
        let value = dataStore.activeLeetCodePlanID
        return value.isEmpty || value == "auto-tracked" ? "top-100-liked" : value
    }

    @ViewBuilder
    private func sessionControls(_ site: WebsiteSessionSite, primaryTitle: String) -> some View {
        let active = websiteSessions[site] == true
        Text(active ? "会话有效" : "未检测到会话")
            .font(AppDesign.Typography.micro)
            .foregroundStyle(active ? Color.green : Color.secondary)
            .frame(width: 84)
            .padding(.vertical, 2)
            .background((active ? Color.green : Color.primary).opacity(active ? 0.12 : 0.06), in: Capsule())
        if active {
            Button("清除会话", role: .destructive) {
                Task { await clearWebsiteSession(site) }
            }
            .buttonStyle(SettingsPillButtonStyle(tint: .red))
            .frame(width: 80)
            .disabled(clearingSite != nil)
        }
        Button(primaryTitle) { loginProvider = site == .leetcode ? .leetcode : .bilibili }
            .buttonStyle(SettingsPillButtonStyle())
            .frame(width: 128)
    }

    private func clearWebsiteSession(_ site: WebsiteSessionSite) async {
        clearingSite = site
        await WebsiteSessionStore.clear(site)
        websiteSessions = await WebsiteSessionStore.authenticationStates()
        clearingSite = nil
        status = "\(site.title) 的 Cookie 与站点会话已清除"
    }
}

private enum EmbeddedLoginProvider: String, Identifiable {
    case leetcode
    case bilibili

    var id: String { rawValue }
    var title: String { self == .leetcode ? "登录 LeetCode 中国站" : "登录哔哩哔哩" }
    var url: URL {
        URL(string: self == .leetcode ? "https://leetcode.cn/accounts/login/" : "https://passport.bilibili.com/login")!
    }
}

private enum EmbeddedLoginResult {
    case leetcode(account: [String: Any], submissions: [[String: Any]], studyPlan: [String: Any]?)
    case bilibili(userID: String, name: String = "", avatar: String = "")
}

private struct EmbeddedLoginIdentity {
    let name: String
    let account: String
    let avatar: URL?
}

private struct EmbeddedAccountLoginView: View {
    let provider: EmbeddedLoginProvider
    let leetcodePlanSlug: String
    let onSuccess: (EmbeddedLoginResult) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var status = "请在官方页面完成登录"
    @State private var checkRevision = 0
    @State private var identity: EmbeddedLoginIdentity?

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Text(provider.title).font(.headline)
                Text(status).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                Spacer()
                if identity == nil {
                    Button("检查登录状态", systemImage: "arrow.clockwise") { checkRevision &+= 1 }
                } else {
                    Button("完成", systemImage: "checkmark") { dismiss() }
                        .buttonStyle(.borderedProminent)
                }
                Button { dismiss() } label: { Image(systemName: "xmark") }
                    .buttonStyle(.plain).help("关闭")
            }
            .padding(.horizontal, 14).frame(height: 46)
            Divider()
            if let identity {
                VStack(spacing: 14) {
                    loginAvatar(identity)
                    Text(identity.name)
                        .font(.title2.weight(.semibold))
                    Text(identity.account)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Label("账号已连接", systemImage: "checkmark.circle.fill")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.green)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                EmbeddedLoginWebView(
                    provider: provider,
                    leetcodePlanSlug: leetcodePlanSlug,
                    checkRevision: checkRevision,
                    status: $status
                ) { result in
                    onSuccess(result)
                    status = "登录信息已保存"
                    dismiss()
                }
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
    }

    @ViewBuilder
    private func loginAvatar(_ identity: EmbeddedLoginIdentity) -> some View {
        if let avatar = identity.avatar {
            AsyncImage(url: avatar) { image in
                image.resizable().scaledToFill()
            } placeholder: {
                ProgressView()
            }
            .frame(width: 82, height: 82)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        } else {
            Image(systemName: "person.crop.square")
                .font(.system(size: 64))
                .foregroundStyle(.secondary)
        }
    }

    private func identity(for result: EmbeddedLoginResult) -> EmbeddedLoginIdentity {
        switch result {
        case let .leetcode(account, _, _):
            let username = account["username"] as? String ?? ""
            return EmbeddedLoginIdentity(
                name: account["realName"] as? String ?? username,
                account: username.isEmpty ? "LeetCode 中国站" : "@\(username)",
                avatar: URL(string: account["avatar"] as? String ?? "")
            )
        case let .bilibili(userID, name, avatar):
            return EmbeddedLoginIdentity(
                name: name.isEmpty ? "哔哩哔哩用户" : name,
                account: "UID \(userID)",
                avatar: URL(string: avatar)
            )
        }
    }
}

private struct EmbeddedLoginWebView: NSViewRepresentable {
    let provider: EmbeddedLoginProvider
    let leetcodePlanSlug: String
    let checkRevision: Int
    @Binding var status: String
    let onSuccess: (EmbeddedLoginResult) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        WebViewPresentation.applyFloatingScrollbars(in: configuration)
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        // 微信 / QQ / GitHub 登录都是 window.open 开弹窗，没有 uiDelegate 就是点了没反应。
        webView.uiDelegate = context.coordinator.popups
        context.coordinator.lastRevision = checkRevision
        webView.load(URLRequest(url: provider.url))
        context.coordinator.startPolling(in: webView)
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        context.coordinator.parent = self
        guard context.coordinator.lastRevision != checkRevision else { return }
        context.coordinator.lastRevision = checkRevision
        context.coordinator.checkLogin(in: webView)
    }

    static func dismantleNSView(_ webView: WKWebView, coordinator: Coordinator) {
        coordinator.stopPolling()
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        var parent: EmbeddedLoginWebView
        var lastRevision = 0
        let popups = WebViewPopupBridge()
        private var isChecking = false
        private var pollTimer: Timer?

        init(parent: EmbeddedLoginWebView) { self.parent = parent }

        func startPolling(in webView: WKWebView) {
            stopPolling()
            pollTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self, weak webView] _ in
                Task { @MainActor [weak self, weak webView] in
                    guard let self, let webView else { return }
                    self.checkLogin(in: webView)
                }
            }
        }

        func stopPolling() {
            pollTimer?.invalidate()
            pollTimer = nil
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            checkLogin(in: webView)
        }

        func checkLogin(in webView: WKWebView) {
            guard !isChecking else { return }
            isChecking = true
            switch parent.provider {
            case .leetcode:
                checkLeetCode(in: webView)
            case .bilibili:
                checkBilibili(in: webView)
            }
        }

        private func checkLeetCode(in webView: WKWebView) {
            webView.configuration.websiteDataStore.httpCookieStore.getAllCookies { [weak self, weak webView] cookies in
                guard let self, let webView else { return }
                let hasSession = cookies.contains { $0.name == "LEETCODE_SESSION" && $0.domain.contains("leetcode.cn") && !$0.value.isEmpty }
                let hasCSRF = cookies.contains { $0.name == "csrftoken" && $0.domain.contains("leetcode.cn") && !$0.value.isEmpty }
                guard hasSession, hasCSRF else {
                    DispatchQueue.main.async {
                        self.isChecking = false
                        self.parent.status = "请在官方页面选择微信扫码，并在手机上确认"
                    }
                    return
                }
                self.fetchLeetCodeSnapshot(in: webView)
            }
        }

        private func fetchLeetCodeSnapshot(in webView: WKWebView) {
            let script = """
            const gql = async (query, variables = {}) => {
              const response = await fetch('/graphql/', {method:'POST',credentials:'include',headers:{'Content-Type':'application/json'},body:JSON.stringify({query,variables})});
              return await response.json();
            };
            const auth = await gql(`query globalData { userStatus { isSignedIn username realName avatar userSlug isPremium } }`);
            const account = auth?.data?.userStatus || {};
            let submissions = [];
            if (account.isSignedIn) {
              const recent = await gql(`query submissionList($offset:Int!,$limit:Int!){submissionList(offset:$offset,limit:$limit){submissions{id statusDisplay lang timestamp title runtime memory url}}}`, {offset:0,limit:100});
              submissions = recent?.data?.submissionList?.submissions || [];
            }
            const planResult = account.isSignedIn
              ? await gql(`query studyPlanDetail($slug:String!){studyPlanV2Detail(planSlug:$slug){name slug description planSubGroups{slug name questions{titleSlug title translatedTitle questionFrontendId difficulty status paidOnly topicTags{name nameTranslated slug}}}}}`, {slug: planSlug})
              : {};
            return JSON.stringify({account, submissions, studyPlan: planResult?.data?.studyPlanV2Detail || null});
            """
            Task { @MainActor [weak self, weak webView] in
                guard let self, let webView else { return }
                defer { self.isChecking = false }
                guard let raw = try? await webView.callAsyncJavaScript(
                    script,
                    arguments: ["planSlug": self.parent.leetcodePlanSlug],
                    in: nil,
                    contentWorld: .page
                ),
                let value = raw as? String,
                let data = value.data(using: .utf8),
                let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                let account = json["account"] as? [String: Any],
                (account["isSignedIn"] as? Bool) == true
                else {
                    self.parent.status = "尚未检测到登录，可完成扫码后再次检查"
                    return
                }
                self.parent.status = "登录成功，正在同步"
                self.stopPolling()
                self.parent.onSuccess(.leetcode(
                    account: account,
                    submissions: json["submissions"] as? [[String: Any]] ?? [],
                    studyPlan: json["studyPlan"] as? [String: Any]
                ))
            }
        }

        private func checkBilibili(in webView: WKWebView) {
            webView.configuration.websiteDataStore.httpCookieStore.getAllCookies { [weak self, weak webView] cookies in
                guard let self else { return }
                let userID = cookies.first { $0.name == "DedeUserID" && $0.domain.contains("bilibili.com") }?.value ?? ""
                let hasSession = cookies.contains { $0.name == "SESSDATA" && $0.domain.contains("bilibili.com") }
                guard hasSession, !userID.isEmpty else {
                    DispatchQueue.main.async {
                        self.isChecking = false
                        self.parent.status = "请使用 B 站客户端扫码，确认后再次检查"
                    }
                    return
                }
                Task { @MainActor [weak self, weak webView] in
                    guard let self else { return }
                    defer { self.isChecking = false }
                    let script = """
                    const response = await fetch('https://api.bilibili.com/x/web-interface/nav', {credentials:'include'});
                    const payload = await response.json();
                    return JSON.stringify(payload?.data || {});
                    """
                    var name = ""
                    var avatar = ""
                    if let webView,
                       let raw = try? await webView.callAsyncJavaScript(script, arguments: [:], in: nil, contentWorld: .page) as? String,
                       let data = raw.data(using: .utf8),
                       let profile = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                        name = profile["uname"] as? String ?? ""
                        avatar = profile["face"] as? String ?? ""
                    }
                    self.parent.status = "登录成功"
                    self.parent.onSuccess(.bilibili(userID: userID, name: name, avatar: avatar))
                }
            }
        }
    }
}

// MARK: - 数据与缓存

private struct DataCacheSettingsPage: View {
    @State private var redis: RedisSettingsDraft
    @State private var vectorDatabase: VectorDatabaseSettingsDraft
    @State private var redisStatus = ""
    @State private var vectorStatus = ""
    @State private var saveStatus = ""
    @State private var testingRedis = false
    @State private var testingVector = false
    @State private var saving = false

    init() {
        _redis = State(initialValue: InfrastructureConfigurationStore.loadRedis())
        _vectorDatabase = State(initialValue: InfrastructureConfigurationStore.loadVectorDatabase())
    }

    var body: some View {
        SettingsScroll {
            SettingsCard(title: "Redis 热缓存", systemImage: "bolt.horizontal.circle", tint: .orange) {
                SettingsToggleRow(
                    "启用 Redis",
                    subtitle: "提交详情、题目分析、跨进程锁与用量计数",
                    isOn: $redis.enabled
                )
                if redis.enabled {
                    CardDivider()
                    SettingsRow("服务器") {
                        HStack(spacing: 8) {
                            TextField("127.0.0.1", text: $redis.host)
                                .settingsInputSurface()
                                .frame(width: 246)
                            TextField("6379", text: $redis.port)
                                .settingsInputSurface()
                                .frame(width: 86)
                        }
                    }
                    CardDivider()
                    SettingsRow("密码", subtitle: "无密码实例可留空") {
                        SecureField("可选", text: $redis.password)
                            .settingsInputSurface()
                            .frame(width: 340)
                    }
                    CardDivider()
                    SettingsRow("键前缀", subtitle: "与其他应用共享 Redis 时用于隔离键空间") {
                        TextField("lca:", text: $redis.keyPrefix)
                            .settingsInputSurface()
                            .frame(width: 220)
                    }
                    CardDivider()
                    SettingsRow("连接超时") {
                        HStack(spacing: 7) {
                            TextField("2", text: $redis.timeoutSeconds)
                                .settingsInputSurface()
                                .frame(width: 72)
                            Text("秒").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }

            connectionActions(
                status: redisStatus,
                isRunning: testingRedis,
                disabled: !redis.enabled
            ) {
                Task { await testRedisConnection() }
            }

            SettingsCard(title: "PostgreSQL + pgvector", systemImage: "point.3.connected.trianglepath.dotted", tint: .blue) {
                SettingsToggleRow(
                    "启用向量数据库",
                    subtitle: "会话语义向量的共享持久层，本地副本仍可离线使用",
                    isOn: $vectorDatabase.enabled
                )
                if vectorDatabase.enabled {
                    CardDivider()
                    SettingsRow("服务器") {
                        HStack(spacing: 8) {
                            TextField("127.0.0.1", text: $vectorDatabase.host)
                                .settingsInputSurface()
                                .frame(width: 246)
                            TextField("5432", text: $vectorDatabase.port)
                                .settingsInputSurface()
                                .frame(width: 86)
                        }
                    }
                    CardDivider()
                    SettingsRow("数据库") {
                        TextField("leetcode_rag", text: $vectorDatabase.database)
                            .settingsInputSurface()
                            .frame(width: 220)
                    }
                    CardDivider()
                    SettingsRow("用户名") {
                        TextField("leetcode", text: $vectorDatabase.user)
                            .settingsInputSurface()
                            .frame(width: 220)
                    }
                    CardDivider()
                    SettingsRow("密码") {
                        SecureField("数据库密码", text: $vectorDatabase.password)
                            .settingsInputSurface()
                            .frame(width: 340)
                    }
                    CardDivider()
                    SettingsRow("向量表", subtitle: "需要 vector 扩展；首次连接会自动建表") {
                        TextField("leetcode_rag_vectors", text: $vectorDatabase.table)
                            .settingsInputSurface()
                            .frame(width: 260)
                    }
                    CardDivider()
                    SettingsRow("连接超时") {
                        HStack(spacing: 7) {
                            TextField("5", text: $vectorDatabase.timeoutSeconds)
                                .settingsInputSurface()
                                .frame(width: 72)
                            Text("秒").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }

            // 测试与保存并排一行：左「测试连接」右「保存并应用」，
            // 原来上下两条动作行把页面拉得又长又散。
            HStack(spacing: 10) {
                Button {
                    Task { await testVectorConnection() }
                } label: {
                    Label(testingVector ? "正在测试" : "测试连接", systemImage: "network")
                }
                .buttonStyle(SettingsPillButtonStyle())
                .disabled(!vectorDatabase.enabled || testingVector)

                if !vectorStatus.isEmpty {
                    Text(vectorStatus)
                        .font(.caption)
                        .foregroundStyle(vectorStatus.contains("成功") ? AppDesign.ColorToken.success : AppDesign.ColorToken.warning)
                        .lineLimit(2)
                }

                Spacer(minLength: 12)

                if !saveStatus.isEmpty {
                    Text(saveStatus)
                        .font(.caption)
                        .foregroundStyle(saveStatus.hasPrefix("保存失败") ? AppDesign.ColorToken.warning : .secondary)
                }
                Button {
                    Task { await saveAndApply() }
                } label: {
                    Label(saving ? "正在应用" : "保存并应用", systemImage: "checkmark.circle")
                }
                .buttonStyle(SettingsPillButtonStyle())
                .disabled(saving)
            }
            .padding(.horizontal, 4)
            .padding(.top, -12)

            if InfrastructureConfigurationStore.hasEnvironmentOverrides {
                Label("当前进程存在环境变量覆盖；本次保存会立即应用，重新启动后仍以环境变量为准。", systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 4)
            }
        }
    }

    private func connectionActions(
        status: String,
        isRunning: Bool,
        disabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 10) {
            Button(action: action) {
                Label(isRunning ? "正在测试" : "测试连接", systemImage: "network")
            }
            .buttonStyle(SettingsPillButtonStyle())
            .disabled(disabled || isRunning)
            if !status.isEmpty {
                Text(status)
                    .font(.caption)
                    .foregroundStyle(status.contains("成功") ? AppDesign.ColorToken.success : AppDesign.ColorToken.warning)
            }
            Spacer()
        }
        .padding(.horizontal, 4)
        .padding(.top, -12)
    }

    private func testRedisConnection() async {
        testingRedis = true
        defer { testingRedis = false }
        do {
            guard let configuration = try redis.configuration() else {
                throw InfrastructureConfigurationError.disabled("Redis")
            }
            let probe = RedisClient(configuration: configuration)
            redisStatus = await probe.ping() ? "连接成功" : "连接失败，请检查地址、密码与网络"
        } catch {
            redisStatus = error.localizedDescription
        }
    }

    private func testVectorConnection() async {
        testingVector = true
        defer { testingVector = false }
        do {
            guard let configuration = try vectorDatabase.configuration() else {
                throw InfrastructureConfigurationError.disabled("PostgreSQL / pgvector")
            }
            let probe = PostgresVectorStore(configuration: configuration)
            try await probe.testConnection()
            vectorStatus = "连接成功，pgvector 与向量表可用"
        } catch {
            vectorStatus = error.localizedDescription
        }
    }

    private func saveAndApply() async {
        saving = true
        defer { saving = false }
        do {
            let redisConfiguration = try redis.configuration()
            let vectorConfiguration = try vectorDatabase.configuration()
            try InfrastructureConfigurationStore.save(redis: redis, vectorDatabase: vectorDatabase)
            await RedisClient.shared.reconfigure(redisConfiguration)
            await PostgresVectorStore.shared.reconfigure(vectorConfiguration)
            saveStatus = "已保存并在当前会话生效"
        } catch {
            saveStatus = "保存失败：\(error.localizedDescription)"
        }
    }
}

// MARK: - 外观

private struct AppearanceSettingsPage: View {
    @Bindable var dataStore: LegacyDataStore
    @State private var appearance = "system"
    @State private var emphasizeMotion = true
    @State private var status = ""

    var body: some View {
        SettingsScroll {
            SettingsCard(title: "主题") {
                SettingsRow("外观", subtitle: "跟随系统或固定使用浅色 / 深色") {
                    GlassSegmentedControl(
                        options: [("system", "跟随系统"), ("light", "浅色"), ("dark", "深色")],
                        selection: $appearance
                    )
                    .frame(width: 230)
                }
                CardDivider()
                SettingsToggleRow("使用流畅的面板与符号动效", isOn: $emphasizeMotion)
            }

            if !status.isEmpty {
                Text(status).font(.caption).foregroundStyle(.secondary)
            }

            SettingsCard(title: "Liquid Glass") {
                SettingsRow(
                    "玻璃效果",
                    subtitle: "玻璃效果用于输入框、上下文浮层和临时检查器；阅读内容保持清晰的实体表面。"
                )
            }
        }
        .onAppear {
            appearance = dataStore.settings.appearance
            emphasizeMotion = dataStore.settings.emphasizeMotion
        }
        .onChange(of: appearance) { _, _ in save() }
        .onChange(of: emphasizeMotion) { _, _ in save() }
    }

    private func save() {
        do {
            try dataStore.saveAppearance(appearance, emphasizeMotion: emphasizeMotion)
            status = "已应用"
        } catch {
            status = "保存失败：\(error.localizedDescription)"
        }
    }
}

// MARK: - 共享样式

private extension View {
    func settingsFieldChrome(cornerRadius: CGFloat = 9) -> some View {
        background(
            Color.primary.opacity(0.045),
            in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.07))
        }
    }

    func settingsInputSurface() -> some View {
        textFieldStyle(.plain)
            .font(.system(size: 13))
            .padding(.horizontal, 12)
            .frame(height: 32)
            .settingsFieldChrome()
    }
}

private struct SettingsMenuLabel: View {
    let text: String

    var body: some View {
        HStack(spacing: 6) {
            Text(text)
                .lineLimit(1)
            Spacer(minLength: 4)
            Image(systemName: "chevron.up.chevron.down")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.tertiary)
        }
        .font(.system(size: 13))
        .foregroundStyle(.primary)
        .padding(.horizontal, 12)
        .frame(height: 32)
        .settingsFieldChrome()
        .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
    }
}

/// 模型输入：文本框永远可编辑，右侧挂一个"已获取模型"的下拉当建议。
/// 拉取失败、模型不在 /v1/models 里、或者用的是自定义网关时，仍然填得进去。
private struct SettingsModelCombo: View {
    @Binding var selection: String
    let options: [String]

    /// 已输入内容作为前缀过滤；空输入时给全量。
    private var suggestions: [String] {
        let keyword = selection.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !keyword.isEmpty else { return options }
        let matched = options.filter { $0.lowercased().contains(keyword) }
        return matched.isEmpty ? options : matched
    }

    var body: some View {
        HStack(spacing: 0) {
            TextField("搜索或输入模型", text: $selection)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .padding(.leading, 12)
                .frame(maxWidth: .infinity)

            if !options.isEmpty {
                Menu {
                    ForEach(suggestions, id: \.self) { option in
                        Button {
                            selection = option
                        } label: {
                            if option == selection {
                                Label(option, systemImage: "checkmark")
                            } else {
                                Text(option)
                            }
                        }
                    }
                } label: {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 28, height: 30)
                        .contentShape(Rectangle())
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                // borderlessButton 的 Menu 不锁宽就会把输入框挤没。
                .frame(width: 28)
                .help("从已获取的模型中选择")
            }
        }
        .frame(height: 32)
        .settingsFieldChrome()
    }
}

private struct SettingsMenuPicker: View {
    @Binding var selection: String
    let options: [String]

    var body: some View {
        Menu {
            ForEach(options, id: \.self) { option in
                Button {
                    selection = option
                } label: {
                    if option == selection {
                        Label(option, systemImage: "checkmark")
                    } else {
                        Text(option)
                    }
                }
            }
        } label: {
            SettingsMenuLabel(text: selection)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
    }
}

private struct SettingsPillButtonStyle: ButtonStyle {
    var tint: Color? = nil

    init(tint: Color? = nil) {
        self.tint = tint
    }

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(tint ?? Color.primary)
            .padding(.horizontal, 14)
            .frame(height: 30)
            .glassCapsule()
            .opacity(configuration.isPressed ? 0.55 : 1)
            .contentShape(Capsule())
    }
}

private struct ProviderQuickLink: Identifiable {
    let id: String
    let title: String
    let systemImage: String
    let urlString: String

    static let deepSeek: [ProviderQuickLink] = [
        ProviderQuickLink(
            id: "deepseek-keys",
            title: "获取 API Key",
            systemImage: "key.fill",
            urlString: "https://platform.deepseek.com/api_keys"
        ),
        ProviderQuickLink(
            id: "deepseek-balance",
            title: "充值与余额",
            systemImage: "creditcard.fill",
            urlString: "https://platform.deepseek.com/account/balance"
        )
    ]

    static let openCode: [ProviderQuickLink] = [
        ProviderQuickLink(
            id: "opencode-go-auth",
            title: "获取 API Key",
            systemImage: "key.fill",
            urlString: "https://opencode.ai/auth"
        ),
        ProviderQuickLink(
            id: "opencode-go-plan",
            title: "套餐与用量",
            systemImage: "creditcard.fill",
            urlString: "https://opencode.ai/zen"
        )
    ]
}

private struct ProviderLinkCapsuleStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(Color.accentColor)
            .padding(.horizontal, 11)
            .frame(height: 26)
            .glassCapsule()
            .opacity(configuration.isPressed ? 0.55 : 1)
            .contentShape(Capsule())
    }
}
