import AppKit
import Foundation
import Observation
import SwiftUI

enum WorkspaceSection: String, CaseIterable, Identifiable, Hashable {
    case conversation
    case leetCode
    case plan
    case review
    case library
    case knowledge
    case insights
    case templates
    case trash

    var id: String { rawValue }

    var title: String {
        switch self {
        case .conversation: "新建会话"
        case .leetCode: "刷题"
        case .plan: "学习计划"
        case .review: "今日复习"
        case .library: "学习题库"
        case .knowledge: "知识图谱"
        case .insights: "学习洞察"
        case .templates: "算法模板"
        case .trash: "回收站"
        }
    }

    var systemImage: String {
        switch self {
        case .conversation: "square.and.pencil"
        case .leetCode: "curlybraces.square"
        case .plan: "calendar"
        case .review: "clock.arrow.circlepath"
        case .library: "books.vertical"
        case .knowledge: "point.3.connected.trianglepath.dotted"
        case .insights: "chart.xyaxis.line"
        case .templates: "doc.on.doc"
        case .trash: "trash"
        }
    }
}

enum ToolKind: String, CaseIterable, Identifiable, Hashable {
    case browser
    case video
    case preview
    case run
    case evidence
    case sources

    var id: String { rawValue }

    var title: String {
        switch self {
        case .browser: "浏览器"
        case .video: "视频"
        case .preview: "预览"
        case .run: "运行"
        case .evidence: "证据"
        case .sources: "来源"
        }
    }

    var systemImage: String {
        switch self {
        case .browser: "globe"
        case .video: "play.rectangle"
        case .preview: "doc.richtext"
        case .run: "terminal"
        case .evidence: "doc.text.magnifyingglass"
        case .sources: "point.3.connected.trianglepath.dotted"
        }
    }
}

enum ReasoningLevel: Int, CaseIterable, Identifiable {
    case off
    case low
    case high
    case maximum

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .off: "关闭"
        case .low: "低"
        case .high: "高"
        case .maximum: "最高"
        }
    }
}

struct WorkspaceLocation: Equatable {
    var section: WorkspaceSection
    var conversationID: String?
}

struct ContextItem: Identifiable, Hashable {
    let id: String
    let title: String
    let subtitle: String
    let systemImage: String
    let tool: ToolKind?
    var url: String? = nil
}

@MainActor
@Observable
final class WorkspaceState {
    var selectedSection: WorkspaceSection = .conversation {
        didSet {
            guard selectedSection != oldValue else { return }
            currentTaskID = selectedSection.rawValue
            toolSuppressedTaskID = nil
            refreshContextForSelection()
            recordLocation()
        }
    }

    var sidebarRequested = true {
        didSet { preferences.set(sidebarRequested, forKey: Keys.sidebarRequested) }
    }
    var toolRequested = true {
        didSet { preferences.set(toolRequested, forKey: Keys.toolRequested) }
    }
    var compactSidebar = false
    var compactTool = false
    var compactContext = false
    var contextRequested = true
    var isToolWorkspaceExpanded = false
    var activeTool: ToolKind = .browser
    private(set) var openToolTabs: [ToolKind] = [.browser]
    /// 标签条上的统一顺序（`TabStripItem.id`）。工具标签和网页标签在同一条上，
    /// 拖动可以互相穿插，所以顺序只有一份；这里只记住"谁在谁前面"，
    /// 谁还活着由两边各自的列表说了算。
    private(set) var tabStripOrder: [String] = []
    private(set) var selectedToolItems: [ToolKind: ContextItem] = [:]
    var reasoningLevel: ReasoningLevel = .high
    var draft = ""
    var hasPendingToolActivity = false
    var currentTaskID = "conversation"
    var selectedConversationID: String? {
        didSet { recordLocation() }
    }
    var selectedLearningRecordID: String?
    /// 外部（工具卡片、洞察页）想让刷题页打开哪道题。刷题页取用后自行清空。
    var pendingLeetCodeSlug: String?
    var presentedSources: [ContextItem] = []
    var isSettingsPresented = false
    var isUsagePresented = false
    var isSearchPalettePresented = false
    var activeQuestionID: String?
    var questionScrollTargetID: String?
    var questionScrollRequestVersion = 0
    var questionRailPulse = 0
    var conversationGeneration: ConversationGenerationSnapshot?
    /// 本进程已经主动呈现过哪一天的简报。只做会话级防抖；真正的跨启动去重
    /// 由简报消息的稳定 id 完成，因此不会往 UserDefaults 再藏一份业务状态。
    var presentedDailyBriefDay = ""
    var queuedConversationDrafts: [QueuedConversationDraft] = []
    var queuedConversationID: String?
    @ObservationIgnored var conversationGenerationTask: Task<Void, Never>?
    var studyPlanSuggestion: AIStudyPlanSuggestion?
    var isGeneratingStudyPlan = false
    var studyPlanError = ""
    @ObservationIgnored var studyPlanGenerationTask: Task<Void, Never>?
    private(set) var windowWidth: CGFloat = 1_700
    /// 窗口标题是否显示：带迟滞，避免在阈值附近拖动窗口时标题闪烁。
    private(set) var showsWindowTitle = true
    /// 窗口是否处于 macOS 原生全屏。全屏时系统会收起红绿灯。
    private(set) var isWindowFullScreen = false
    private(set) var sources: [ContextItem] = WorkspaceState.conversationSources

    private var toolSuppressedTaskID: String?
    private let preferences: UserDefaults
    @ObservationIgnored private var contextCache: [String: (revision: ConversationRevision, value: ConversationContextSnapshot)] = [:]
    @ObservationIgnored private var contextUsageCache: [String: (revision: ConversationRevision, value: ConversationContextBaseline)] = [:]
    @ObservationIgnored private var questionRailCache: [String: (revision: ConversationRevision, value: [QuestionRailItem])] = [:]

    // Codex 式浏览历史：记录（栏目, 会话）位置，支持工具栏后退/前进。
    private var locationHistory: [WorkspaceLocation] = [WorkspaceLocation(section: .conversation, conversationID: nil)]
    private var locationIndex = 0
    private var isReplayingLocation = false

    var canNavigateBack: Bool { locationIndex > 0 }
    var canNavigateForward: Bool { locationIndex < locationHistory.count - 1 }

    func navigateBack() {
        guard canNavigateBack else { return }
        locationIndex -= 1
        applyLocation(locationHistory[locationIndex])
    }

    func navigateForward() {
        guard canNavigateForward else { return }
        locationIndex += 1
        applyLocation(locationHistory[locationIndex])
    }

    private func applyLocation(_ location: WorkspaceLocation) {
        isReplayingLocation = true
        defer { isReplayingLocation = false }
        selectedConversationID = location.conversationID
        selectedSection = location.section
    }

    private func recordLocation() {
        guard !isReplayingLocation else { return }
        let location = WorkspaceLocation(section: selectedSection, conversationID: selectedConversationID)
        guard locationHistory[locationIndex] != location else { return }
        locationHistory.removeSubrange((locationIndex + 1)...)
        locationHistory.append(location)
        locationIndex = locationHistory.count - 1
    }

    var isSidebarPresented: Bool {
        get { sidebarRequested && !compactSidebar }
        set {
            sidebarRequested = newValue
            if newValue { compactSidebar = false }
        }
    }

    var isToolWorkspacePresented: Bool {
        get { toolRequested && !compactTool }
        set {
            toolRequested = newValue
            if newValue {
                compactTool = false
                compactContext = windowWidth < LayoutBreakpoints.fullWorkspace
                deferSidebarCompaction(windowWidth < LayoutBreakpoints.toolWithSidebar)
                toolSuppressedTaskID = nil
                hasPendingToolActivity = false
            } else {
                isToolWorkspaceExpanded = false
                toolSuppressedTaskID = currentTaskID
                compactSidebar = windowWidth < LayoutBreakpoints.sidebar
                compactContext = windowWidth < LayoutBreakpoints.context
            }
        }
    }

    var isToolWorkspaceFocused: Bool {
        isToolWorkspacePresented && isToolWorkspaceExpanded
    }

    var isContextPanelPresented: Bool {
        get { contextRequested && !compactContext }
        set {
            contextRequested = newValue
            if newValue {
                compactContext = false
            }
        }
    }

    init(preferences: UserDefaults = .standard) {
        self.preferences = preferences
        if preferences.object(forKey: Keys.sidebarRequested) != nil {
            sidebarRequested = preferences.bool(forKey: Keys.sidebarRequested)
        }
        if preferences.object(forKey: Keys.toolRequested) != nil {
            toolRequested = preferences.bool(forKey: Keys.toolRequested)
        }
    }

    func toggleSidebar() {
        // 只使用短时 easeInOut；避免弹簧让重型详情视图反复越界重排。
        withAnimation(AppDesign.Motion.panelTransition) {
            isSidebarPresented.toggle()
        }
    }

    func updateSidebarVisibilityFromContainer(_ isVisible: Bool) {
        // NavigationSplitView can report `.detailOnly` while rebuilding around
        // an overlay. That is container lifecycle state, not a user request to
        // close the first column. Explicit closes go through `toggleSidebar()`;
        // the container binding only acknowledges a visible sidebar.
        guard isVisible else { return }
        sidebarRequested = true
        compactSidebar = false
    }

    func updateToolVisibilityFromContainer(_ isVisible: Bool) {
        guard isVisible || !compactTool else { return }
        if isVisible {
            // This is a container lifecycle acknowledgement, not a second user
            // presentation. Re-entering the public setter here would recompute
            // adaptive columns and dismiss a context panel intentionally kept
            // visible while opening a source in the inspector.
            toolRequested = true
            compactTool = false
            toolSuppressedTaskID = nil
            hasPendingToolActivity = false
        } else {
            isToolWorkspacePresented = false
        }
    }

    func toggleContextPanel() {
        withPanelAnimation {
            isContextPanelPresented.toggle()
        }
    }

    func toggleToolWorkspace() {
        // 收拢一律瞬时完成，不做补间：这一列里挂着 WKWebView，
        // 列宽逐帧变化会让整个网页每帧重排一次，表现就是"收起时卡死"。
        // 展开时列宽同样在变，但内容是从无到有，补间收益也抵不过这份代价。
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            isToolWorkspacePresented.toggle()
        }
    }

    func focusToolWorkspace() {
        guard isToolWorkspacePresented else { return }
        // 这里会更换承载 WKWebView 的视图树，spring 期间旧、新容器会同时竞争页面。
        isToolWorkspaceExpanded = true
        compactTool = false
    }

    func restoreToolWorkspace() {
        let wasExpanded = isToolWorkspaceExpanded
        isToolWorkspaceExpanded = false
        guard wasExpanded else { return }
        compactTool = Self.compactFlag(
            current: false,
            width: windowWidth,
            breakpoint: LayoutBreakpoints.fullWorkspace
        )
        compactSidebar = Self.compactFlag(
            current: compactSidebar,
            width: windowWidth,
            breakpoint: LayoutBreakpoints.sidebar
        )
        compactContext = Self.compactFlag(
            current: compactContext,
            width: windowWidth,
            breakpoint: LayoutBreakpoints.context
        )
    }

    func dismissToolWorkspace() {
        guard isToolWorkspacePresented || toolRequested else { return }
        isToolWorkspacePresented = false
    }

    func presentTool(
        _ tool: ToolKind,
        automatically: Bool = false,
        preservingContextPanel: Bool = false
    ) {
        let contextPanelWasVisible = isContextPanelPresented
        activeTool = tool
        if !openToolTabs.contains(tool) {
            openToolTabs.append(tool)
        }
        if automatically, toolSuppressedTaskID == currentTaskID {
            hasPendingToolActivity = true
            return
        }
        toolRequested = true
        compactTool = false
        compactContext = preservingContextPanel && contextPanelWasVisible
            ? false
            : windowWidth < LayoutBreakpoints.fullWorkspace
        deferSidebarCompaction(windowWidth < LayoutBreakpoints.toolWithSidebar)
        hasPendingToolActivity = false
    }

    func selectToolTab(_ tool: ToolKind) {
        guard openToolTabs.contains(tool) else { return }
        activeTool = tool
    }

    func closeToolTab(_ tool: ToolKind) {
        guard tool != .browser,
              let index = openToolTabs.firstIndex(of: tool)
        else { return }
        openToolTabs.remove(at: index)
        selectedToolItems.removeValue(forKey: tool)
        guard activeTool == tool else { return }
        activeTool = openToolTabs.last ?? .browser
    }

    /// 拖动后的新顺序。只接受还开着的标签，漏掉的（比如不显示在条上的浏览器占位）补在后面。
    func reorderToolTabs(_ order: [ToolKind]) {
        var next = order.filter { openToolTabs.contains($0) }
        for tool in openToolTabs where !next.contains(tool) { next.append(tool) }
        guard next != openToolTabs else { return }
        openToolTabs = next
    }

    /// 记住整条标签栏的顺序。工具标签和网页标签共用它，所以拖动能跨类型穿插。
    func rememberTabStripOrder(_ ids: [String]) {
        guard ids != tabStripOrder else { return }
        tabStripOrder = ids
    }

    func presentSources(_ items: [ContextItem]) {
        var seen = Set<String>()
        presentedSources = items.filter { item in
            let identity = item.url.map { "url:\($0)" } ?? item.id
            return seen.insert(identity).inserted
        }
        presentTool(.sources)
    }

    /// 工具区呈现时若同帧收起侧栏，NavigationSplitView 的列变化会把
    /// inspector 的呈现打断（"秒收回"）。把侧栏收拢推迟到下一个 runloop。
    private func deferSidebarCompaction(_ shouldCompact: Bool) {
        guard shouldCompact else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, self.isToolWorkspacePresented else { return }
            if self.windowWidth < LayoutBreakpoints.toolWithSidebar {
                self.compactSidebar = true
            }
        }
    }

    func handleFullScreenChange(_ isFullScreen: Bool) {
        guard isWindowFullScreen != isFullScreen else { return }
        // 显式关掉动画：这一下改的是顶栏的排布口径（内缩、偏移、控件归属），
        // 让 SwiftUI 再叠一层自己的补间，就会在系统窗口动画之上多出一段
        // 不同步的滑动，看着像"跳"了两次。
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) { isWindowFullScreen = isFullScreen }
    }

    /// 最左一列列头的左内缩。窗口态要给红绿灯让位，控件才能和它同处一行；
    /// 全屏时系统收起红绿灯，再留 78pt 就是列头左边一块空洞。
    var headerLeadingInset: CGFloat {
        isWindowFullScreen ? AppDesign.Spacing.xs : AppDesign.Size.trafficLightInset
    }

    /// 点开一条上下文。网页一律新开标签并跳过去；
    /// 「来源」标签自己不会因此关掉，看完点回来清单还在。
    func openContextItem(_ item: ContextItem) {
        let url = item.url.flatMap(URL.init(string:))
        let preserveContextPanel = isContextPanelPresented
        switch item.tool {
        case .browser, .video:
            guard let url else { return }
            openURL(url, preservingContextPanel: preserveContextPanel)
        case .preview, .run, .evidence:
            guard let tool = item.tool else { return }
            selectedToolItems[tool] = item
            presentTool(tool)
        case .sources:
            presentTool(.sources)
        case nil:
            guard let url else { return }
            openURL(url, preservingContextPanel: preserveContextPanel)
        }
    }

    func openURL(
        _ url: URL,
        forceInApp: Bool = false,
        preservingContextPanel: Bool = false
    ) {
        let scheme = url.scheme?.lowercased() ?? ""
        guard ["http", "https"].contains(scheme) else {
            NSWorkspace.shared.open(url)
            return
        }
        if !forceInApp, BrowserPreferences.shared.linkTarget == .systemBrowser {
            NSWorkspace.shared.open(url)
            return
        }
        BrowserSession.shared.open(url, inNewTab: true)
        presentTool(.browser, preservingContextPanel: preservingContextPanel)
    }

    func handleWindowWidth(_ width: CGFloat) {
        windowWidth = width
        let newShowsTitle = WindowChromePolicy.showsTitle(current: showsWindowTitle, width: width)
        if newShowsTitle != showsWindowTitle {
            withAnimation(AppDesign.Motion.fade) { showsWindowTitle = newShowsTitle }
        }
        let newCompactTool = isToolWorkspaceExpanded
            ? false
            : Self.compactFlag(current: compactTool, width: width, breakpoint: LayoutBreakpoints.fullWorkspace)
        let newCompactSidebar = Self.compactFlag(current: compactSidebar, width: width, breakpoint: LayoutBreakpoints.sidebar)
        let newCompactContext = Self.compactFlag(current: compactContext, width: width, breakpoint: LayoutBreakpoints.context)
        guard newCompactTool != compactTool
            || newCompactSidebar != compactSidebar
            || newCompactContext != compactContext
        else { return }
        // 窗口拖拽本身已经是连续动画；在断点上再启动 spring 会与鼠标输入竞争并抖动。
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            compactTool = newCompactTool
            compactSidebar = newCompactSidebar
            compactContext = newCompactContext
        }
    }

    /// 迟滞区间：宽度跌破 breakpoint 才收起，但需回升到 breakpoint + 迟滞带以上才重新展开，
    /// 避免拖拽调整窗口时面板在临界点附近来回跳动。
    private static func compactFlag(current: Bool, width: CGFloat, breakpoint: CGFloat) -> Bool {
        current ? width < breakpoint + 44 : width < breakpoint
    }

    func updateQuestionNavigation(activeID: String, userIsScrolling: Bool) {
        let changed = activeQuestionID != activeID
        guard changed else { return }
        activeQuestionID = activeID
        if userIsScrolling { questionRailPulse &+= 1 }
    }

    func scrollToQuestion(_ id: String) {
        activeQuestionID = id
        questionScrollTargetID = id
        questionScrollRequestVersion &+= 1
        questionRailPulse &+= 1
    }

    @discardableResult
    func stopConversationGeneration() -> Bool {
        guard conversationGeneration?.phase == .generating else { return false }
        conversationGenerationTask?.cancel()
        return true
    }

    @discardableResult
    func stopStudyPlanGeneration() -> Bool {
        guard isGeneratingStudyPlan else { return false }
        studyPlanGenerationTask?.cancel()
        return true
    }

    func conversationContext(for conversation: ConversationSummary) -> ConversationContextSnapshot {
        let revision = conversation.revision
        if let cached = contextCache[conversation.id], cached.revision == revision {
            return cached.value
        }
        let value = ConversationContextDeriver.derive(messages: conversation.messages)
        contextCache[conversation.id] = (revision, value)
        return value
    }

    func contextUsage(
        for conversation: ConversationSummary?,
        draft: String,
        settings: LegacySettingsSnapshot
    ) -> ContextUsageSnapshot {
        guard let conversation else {
            return ConversationContextEstimator.estimate(messages: [], draft: draft, settings: settings)
        }
        let revision = conversation.revision
        let baseline: ConversationContextBaseline
        if let cached = contextUsageCache[conversation.id], cached.revision == revision {
            baseline = cached.value
        } else {
            baseline = ConversationContextEstimator.baseline(messages: conversation.messages)
            contextUsageCache[conversation.id] = (revision, baseline)
        }
        return ConversationContextEstimator.estimate(baseline: baseline, draft: draft, settings: settings)
    }

    func questionRailItems(for conversation: ConversationSummary) -> [QuestionRailItem] {
        let revision = conversation.revision
        if let cached = questionRailCache[conversation.id], cached.revision == revision {
            return cached.value
        }
        let value = QuestionRailDeriver.derive(messages: conversation.messages)
        questionRailCache[conversation.id] = (revision, value)
        return value
    }

    func presentSettings() {
        // 从工具聚焦态进入设置时，先回到稳定的分栏承载；否则设置页会被
        // 已聚焦的工具覆盖，用户看不到刚打开的页面。
        restoreToolWorkspace()
        isSettingsPresented = true
    }

    func dismissSettings() {
        // 设置页内也能再次聚焦工具。离开设置时统一恢复分栏，避免返回主界面后
        // 仍停留在只有浏览器的聚焦态，造成“返回没有反应”的错觉。
        restoreToolWorkspace()
        isSettingsPresented = false
    }

    private func refreshContextForSelection() {
        switch selectedSection {
        case .conversation:
            sources = Self.conversationSources
        case .leetCode:
            sources = Self.leetCodeSources
        case .plan:
            sources = []
        case .review:
            sources = Self.reviewSources
            compactContext = true
        case .library, .templates, .trash:
            sources = Self.reviewSources
        case .knowledge, .insights:
            sources = Self.knowledgeSources
        }
    }

    private func withPanelAnimation(_ changes: () -> Void) {
        withAnimation(AppDesign.Motion.panel, changes)
    }

    private enum Keys {
        static let sidebarRequested = "native.workspace.sidebarRequested"
        static let toolRequested = "native.workspace.toolRequested"
    }

    private enum LayoutBreakpoints {
        static let sidebar: CGFloat = 900
        static let context: CGFloat = 1_180
        static let toolWithSidebar: CGFloat = 1_280
        static let contextWithToolAndSidebar: CGFloat = 1_600
        static let fullWorkspace: CGFloat = 1_850
    }

    private static let conversationSources: [ContextItem] = []
    private static let leetCodeSources: [ContextItem] = []
    private static let reviewSources: [ContextItem] = []
    private static let knowledgeSources: [ContextItem] = []
}

/// 窗口 chrome 的显示判定，抽成纯函数便于单测（01 号文档 T-02 / T-10）。
enum WindowChromePolicy {
    /// 标题迟滞带：宽度跌破 1260 才隐藏，需回升到 1320 以上才重新显示。
    static let titleHideWidth: CGFloat = 1_260
    static let titleShowWidth: CGFloat = 1_320

    static func showsTitle(current: Bool, width: CGFloat) -> Bool {
        current ? width >= titleHideWidth : width >= titleShowWidth
    }

}
