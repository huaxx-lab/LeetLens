import AppKit
import SwiftUI

struct RootWorkspaceView: View {
    @State private var workspace = WorkspaceState()
    @State private var dataStore = LegacyDataStore()
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        @Bindable var workspace = workspace

        workspaceNavigation
        .onReceive(NotificationCenter.default.publisher(for: .openInAppSettings)) { _ in
            workspace.presentSettings()
        }
        // 数据加载不再是首窗的前置条件：窗口先出现，再补齐数据与索引。
        .task {
            await dataStore.hydrate()
            applyWindowLevel(dataStore.settings.alwaysOnTop)
            if let debugURL = ProcessInfo.processInfo.environment["LEETCODE_DEBUG_BROWSER_URL"],
               let url = URL(string: debugURL),
               !debugURL.isEmpty {
                workspace.openURL(url, forceInApp: true)
            }
        }
        .onChange(of: dataStore.settings.alwaysOnTop) { _, value in
            applyWindowLevel(value)
        }
        // 提交分析队列的所有权属于 App，不属于刷题页。挂在页面上时，
        // 导航离开会取消 worker，而取消曾被记成分析失败并耗尽重试预算。
        .task {
            while !Task.isCancelled {
                let processed = await dataStore.processNextLeetCodeAnalysis()
                if !processed { try? await Task.sleep(for: .seconds(5)) }
            }
        }
        // 账号级增量同步：启动后延迟一次，之后每 10 分钟轮询；回前台立即补一次。
        .task {
            try? await Task.sleep(for: .seconds(3))
            while !Task.isCancelled {
                await dataStore.syncLeetCodeAccountActivity()
                try? await Task.sleep(for: .seconds(600))
            }
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else {
                // 用量账本现在按批 checkpoint，离开前台时补一次落盘，避免丢计数。
                Task { await AIUsageLedger.shared.flush(dataDirectory: dataStore.dataDirectory) }
                return
            }
            Task { await dataStore.syncLeetCodeAccountActivity() }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
            Task { await AIUsageLedger.shared.flush(dataDirectory: dataStore.dataDirectory) }
        }
        .sheet(isPresented: $workspace.isUsagePresented) {
            UsageStatisticsView(workspace: workspace, dataStore: dataStore)
        }
        .overlay {
            if workspace.isSearchPalettePresented {
                SearchPaletteView(workspace: workspace, dataStore: dataStore) {
                    workspace.isSearchPalettePresented = false
                }
                .transition(.opacity.combined(with: .scale(scale: 0.98)))
                .zIndex(50)
            }
        }
        .animation(AppDesign.Motion.subtle, value: workspace.isSearchPalettePresented)
        .onGeometryChange(for: CGFloat.self) { proxy in
            proxy.size.width
        } action: { width in
            workspace.scheduleHandleWindowWidth(width)
        }
        // 窗口不挂 NSToolbar。两个原因：
        // 1) unified 工具栏会画自己的系统材质（实测 230,231,232 灰），`.toolbarBackground` 压不住，
        //    于是中间列/第三列顶部永远横着一条灰带；
        // 2) `.primaryAction` 在这套工具栏里不会靠右，只能往 NSToolbar 里插 `flexibleSpace`，
        //    而 SwiftUI 每次重建工具栏都会把它清掉——补插总慢一拍，右侧控件就先在左边画一帧
        //    再跳回右缘，看起来就是胶囊来回横跳。
        // 改为各列在自己顶部排控件：位置由 SwiftUI 布局决定，既不横跳也没有灰带。
        // NavigationSplitView 会自带一枚侧栏开关工具栏项，只要有项就有工具栏、就有灰带，
        // 所以先摘掉它，侧栏开关由各列头部自己提供。
        // （不能用 `.toolbarVisibility(.hidden)`：实测它会把红绿灯一起藏掉，
        //   而工具栏的高度照留，顶上就空出一条 68pt 白带。）
        .toolbar(removing: .sidebarToggle)
        .background {
            WindowChromeConfiguration(dataStore: dataStore) { isFullScreen in
                workspace.handleFullScreenChange(isFullScreen)
            }
        }
        // 用 will* 而不是 did*：did* 在系统那段窗口动画**跑完之后**才发，
        // 顶栏布局（上移一个标题栏、左内缩 78pt、两处 offset）会在画面已经稳定
        // 之后突然整体跳一下。will* 在动画开始时就发，这一跳就藏在系统动画里。
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.willEnterFullScreenNotification)) { _ in
            workspace.handleFullScreenChange(true)
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.willExitFullScreenNotification)) { _ in
            workspace.handleFullScreenChange(false)
        }
        // 内容一路画到窗口顶端，列头才能和红绿灯同处一行（窗口态下标题栏那 28pt
        // 否则会把列头整个挤到第二行）。
        .ignoresSafeArea(.container, edges: .top)
        .preferredColorScheme(preferredColorScheme)
        .tint(.accentColor)
        .background(Color(nsColor: .textBackgroundColor).ignoresSafeArea())
    }

    private var preferredColorScheme: ColorScheme? {
        switch dataStore.settings.appearance {
        case "light": .light
        case "dark": .dark
        default: nil
        }
    }

    private var hasEmptyConversationContent: Bool {
        guard workspace.selectedSection == .conversation,
              !workspace.isSettingsPresented
        else { return false }

        let messages = workspace.selectedConversationID.flatMap { conversationID in
            dataStore.conversations.first { $0.id == conversationID }?.messages
        } ?? []
        let hasVisibleGeneration = workspace.conversationGeneration?.conversationID == workspace.selectedConversationID
        return messages.isEmpty && !hasVisibleGeneration
    }

    private func applyWindowLevel(_ alwaysOnTop: Bool) {
        (NSApp.mainWindow ?? NSApp.keyWindow)?.level = alwaysOnTop ? .floating : .normal
    }

    private var workspaceNavigation: some View {
        WorkspaceColumnShell(
            sidebarVisible: !workspace.isSettingsPresented && workspace.isSidebarPresented,
            inspectorVisible: workspace.isToolWorkspacePresented,
            inspectorExpanded: workspace.isToolWorkspaceFocused,
            sidebarWidth: workspace.sidebarColumnWidth,
            inspectorWidth: workspace.inspectorColumnWidth,
            onSidebarWidth: { workspace.setSidebarColumnWidth($0) },
            onInspectorWidth: { workspace.setInspectorColumnWidth($0) },
            sidebar: {
                GlobalSidebarView(workspace: workspace, dataStore: dataStore)
            },
            detail: {
                if workspace.isSettingsPresented {
                    SettingsView(
                        workspace: workspace,
                        dataStore: dataStore,
                        onDismiss: { workspace.dismissSettings() },
                        openInBrowser: { url in
                            workspace.openURL(url)
                        }
                    )
                } else {
                    detailColumn
                }
            },
            inspector: {
                ToolWorkspaceView(workspace: workspace, dataStore: dataStore)
                    .background(AppDesign.ColorToken.canvas.ignoresSafeArea())
            }
        )
        // 背景铺进标题栏；列头自己用 windowTitlebarInset 让出顶边，不和红绿灯挤一行。
        .ignoresSafeArea(.container, edges: .top)
    }

    /// 中间列：列头（导航 + 标题 + 右侧操作）压在最上，内容在下，第三列挂在整列右侧。
    private var detailColumn: some View {
        VStack(spacing: 0) {
            DetailColumnHeader(
                workspace: workspace,
                dataStore: dataStore,
                showsNavigationChrome: !hasEmptyConversationContent,
                title: workspaceTitle,
                conversation: selectedConversation
            )
            PrimaryWorkspaceView(workspace: workspace, dataStore: dataStore)
        }
        .background(AppDesign.ColorToken.canvas)
    }

    private var workspaceTitle: String {
        guard
            workspace.selectedSection == .conversation,
            let id = workspace.selectedConversationID,
            let conversation = dataStore.conversations.first(where: { $0.id == id })
        else { return workspace.selectedSection.title }
        return conversation.title
    }

    private var selectedConversation: ConversationSummary? {
        guard workspace.selectedSection == .conversation,
              let id = workspace.selectedConversationID
        else { return nil }
        return dataStore.conversations.first { $0.id == id }
    }
}

/// 中间列的列头：原来挂在 NSToolbar 上的导航控件、窗口标题与右侧操作组，
/// 现在由这一行自己排版——位置完全由 SwiftUI 决定，不再依赖往工具栏里插弹性空档。
private struct DetailColumnHeader: View {
    @Bindable var workspace: WorkspaceState
    @Bindable var dataStore: LegacyDataStore
    let showsNavigationChrome: Bool
    let title: String
    let conversation: ConversationSummary?
    @State private var columnWidth: CGFloat = 0
    @State private var navigationWidth: CGFloat = 0

    var body: some View {
        HStack(spacing: AppDesign.Spacing.xxs) {
            navigationCluster
                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { navigationWidth = $0 }

            Color.clear
                .frame(width: titleLeadingGap, height: 1)

            if showsNavigationChrome {
                titleChrome
            }

            Spacer(minLength: AppDesign.Spacing.xs)

            TrailingWindowChrome(workspace: workspace, dataStore: dataStore)
        }
        .padding(.leading, headerLeadingPadding)
        .padding(.trailing, AppDesign.Spacing.xs)
        .frame(height: AppDesign.Size.columnHeader)
        .padding(.top, ToolHeaderLayoutPolicy.topInset(isFullScreen: workspace.isWindowFullScreen))
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { columnWidth = $0 }
    }

    private var headerLeadingPadding: CGFloat {
        workspace.isSidebarPresented ? AppDesign.Spacing.xs : workspace.headerLeadingInset
    }

    private var titleLeadingGap: CGFloat {
        ConversationColumnLayout.titleGapAfterNavigation(
            columnWidth: columnWidth,
            trailingInset: contentTrailingInset,
            headerLeadingPadding: headerLeadingPadding,
            navigationWidth: navigationWidth,
            railInset: questionRailContentInset
        )
    }

    /// 标题和正文共用一条左缘：正文给刻度条让了位，标题也得跟着让。
    private var questionRailContentInset: CGFloat {
        let questions = conversation.map { workspace.questionRailItems(for: $0) } ?? []
        return QuestionRailPresentationPolicy.isVisible(
            section: workspace.selectedSection,
            questionCount: questions.count,
            columnWidth: columnWidth
        ) ? QuestionRailPresentationPolicy.contentInset : 0
    }

    private var contentTrailingInset: CGFloat {
        guard workspace.selectedSection == .conversation, workspace.isContextPanelPresented else { return 0 }
        let panelWidth = min(
            max(workspace.windowWidth * 0.18, AppDesign.Size.contextPanelMinimum),
            AppDesign.Size.contextPanelMaximum
        )
        return ContextPanelOverlayPolicy.contentTrailingInset(isVisible: true, panelWidth: panelWidth)
    }

    @ViewBuilder
    private var navigationCluster: some View {
        HStack(spacing: AppDesign.Spacing.xxs) {
            if !workspace.isSidebarPresented {
                headerButton("sidebar.left", help: "显示侧栏") {
                    workspace.toggleSidebar()
                }
            }

            if showsNavigationChrome {
                if !(workspace.isWindowFullScreen && workspace.isSidebarPresented) {
                    historyChrome
                }
                newConversationButton
            }
        }
    }

    @ViewBuilder
    private var historyChrome: some View {
        headerButton("chevron.left", help: "后退", disabled: !workspace.canNavigateBack) {
            withAnimation(AppDesign.Motion.selection) { workspace.navigateBack() }
        }
        .keyboardShortcut("[", modifiers: .command)

        headerButton("chevron.right", help: "前进", disabled: !workspace.canNavigateForward) {
            withAnimation(AppDesign.Motion.selection) { workspace.navigateForward() }
        }
        .keyboardShortcut("]", modifiers: .command)
    }

    private var newConversationButton: some View {
        headerButton("square.and.pencil", help: "新建会话") {
            withAnimation(AppDesign.Motion.selection) {
                workspace.selectedConversationID = nil
                workspace.selectedSection = .conversation
            }
        }
    }

    private var titleChrome: some View {
        HStack(spacing: AppDesign.Spacing.xxs) {
            if workspace.showsWindowTitle {
                Text(title)
                    .font(AppDesign.Typography.rowTitleEmphasis)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    // 不再给短标题套固定的 190/300pt 宽框；文本按实际长度占位，
                    // 后面的省略号自然紧随标题，空间不足时标题优先收缩并截断。
                    .layoutPriority(-1)
                    .transition(.opacity)
            }

            Menu {
                if let conversation {
                    Button(
                        conversation.isPinned ? "取消置顶" : "置顶聊天",
                        systemImage: conversation.isPinned ? "pin.slash" : "pin"
                    ) {
                        try? dataStore.setConversationPinned(conversation.id, pinned: !conversation.isPinned)
                    }
                    Button("重命名聊天", systemImage: "pencil") {
                        renameConversation(conversation)
                    }
                    Divider()
                    Menu("复制", systemImage: "doc.on.doc") {
                        Button("复制对话全文", systemImage: "doc.on.clipboard") {
                            copyTranscript(conversation)
                        }
                        Button("复制为新会话", systemImage: "plus.square.on.square") {
                            if let id = try? dataStore.duplicateConversation(conversation.id) {
                                workspace.selectedConversationID = id
                            }
                        }
                    }
                    Button("添加计划任务", systemImage: "clock") {
                        addConversationToPlan(conversation)
                    }
                    Divider()
                    Button("删除聊天", systemImage: "trash", role: .destructive) {
                        deleteConversation(conversation)
                    }
                } else {
                    Button("新建会话", systemImage: "square.and.pencil") {
                        workspace.selectedConversationID = nil
                        workspace.selectedSection = .conversation
                    }
                    Button("设置", systemImage: "gearshape") {
                        workspace.presentSettings()
                    }
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(AppDesign.Typography.auxEmphasis)
                    .foregroundStyle(.secondary)
                    .frame(width: AppDesign.Size.toolbarControl, height: AppDesign.Size.toolbarControl)
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }

    private func headerButton(
        _ systemName: String,
        help: String,
        disabled: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(AppDesign.Typography.icon)
                .symbolRenderingMode(.hierarchical)
                .frame(width: AppDesign.Size.toolbarControl, height: AppDesign.Size.toolbarControl)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .foregroundStyle(disabled ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.primary))
        .help(help)
    }

    private func renameConversation(_ conversation: ConversationSummary) {
        let field = NSTextField(string: conversation.title)
        field.placeholderString = "聊天标题"
        field.frame = NSRect(x: 0, y: 0, width: 320, height: 24)
        let alert = NSAlert()
        alert.messageText = "重命名聊天"
        alert.informativeText = "标题会立即同步到最近会话。"
        alert.accessoryView = field
        alert.addButton(withTitle: "重命名")
        alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        try? dataStore.renameConversation(conversation.id, title: field.stringValue)
    }

    private func copyTranscript(_ conversation: ConversationSummary) {
        let text = conversation.messages.map { message in
            let speaker = message.role == "user" ? "用户" : "AI"
            return "\(speaker)：\(message.content)"
        }.joined(separator: "\n\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private func addConversationToPlan(_ conversation: ConversationSummary) {
        let calendar = Calendar.current
        let hour = calendar.component(.hour, from: .now)
        let scheduledAt: Date
        if hour < 21 {
            scheduledAt = calendar.date(byAdding: .hour, value: 1, to: .now) ?? .now
        } else {
            let tomorrow = calendar.date(byAdding: .day, value: 1, to: .now) ?? .now
            scheduledAt = calendar.date(bySettingHour: 9, minute: 0, second: 0, of: tomorrow) ?? tomorrow
        }
        try? dataStore.createStudyTask(StudyPlanDraft(
            title: "继续：\(conversation.title)",
            notes: conversation.summary,
            scheduledAt: scheduledAt,
            durationMinutes: 30,
            priority: .normal,
            learningRecordID: nil
        ))
    }

    private func deleteConversation(_ conversation: ConversationSummary) {
        let alert = NSAlert()
        alert.messageText = "删除“\(conversation.title)”？"
        alert.informativeText = "该操作会永久移除这段对话。"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "删除")
        alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        try? dataStore.deleteConversation(conversation.id)
        workspace.selectedConversationID = nil
    }
}

/// 只做窗口层面的设置：透明标题栏 + 内容延伸到顶端 + 置顶开关。
/// 这里不再碰 NSToolbar——窗口根本不挂工具栏，控件都在各列自己的头部。
private struct WindowChromeConfiguration: NSViewRepresentable {
    let dataStore: LegacyDataStore
    let onFullScreenChange: (Bool) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSView {
        let coordinator = context.coordinator
        return WindowAttachmentView { [weak coordinator] window in
            coordinator?.attach(to: window)
        }
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.alwaysOnTop = dataStore.settings.alwaysOnTop
        context.coordinator.onFullScreenChange = onFullScreenChange
        context.coordinator.attach(to: nsView.window)
        context.coordinator.apply()
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.detach()
    }

    @MainActor
    final class Coordinator: NSObject {
        weak var window: NSWindow?
        var alwaysOnTop = false
        var onFullScreenChange: ((Bool) -> Void)?

        private var toolbarObservation: NSKeyValueObservation?
        private var isRemovingToolbar = false
        /// 全屏期间不许动 toolbar，见 `removeToolbar`。用通知而不是只读 styleMask：
        /// 进入全屏的过程中 AppKit 会先装 toolbar、后置上 `.fullScreen` 位，
        /// 只看 styleMask 会在那一帧漏判，照样把它拆掉。
        private var isFullScreen = false
        private var fullScreenObservers: [NSObjectProtocol] = []
        /// 红绿灯要和列头同一条中线，系统不给接口，只能盯着 frame 补写。
        private let trafficLights = WindowTrafficLightPositioner()

        func attach(to newWindow: NSWindow?) {
            guard window !== newWindow else { return }
            toolbarObservation?.invalidate()
            toolbarObservation = nil
            fullScreenObservers.forEach(NotificationCenter.default.removeObserver)
            fullScreenObservers = []
            window = newWindow
            guard let newWindow else { return }

            isFullScreen = newWindow.styleMask.contains(.fullScreen)
            for (name, value) in [
                (NSWindow.willEnterFullScreenNotification, true),
                (NSWindow.willExitFullScreenNotification, false)
            ] {
                let observer = NotificationCenter.default.addObserver(
                    forName: name,
                    object: newWindow,
                    queue: .main
                ) { [weak self] _ in
                    MainActor.assumeIsolated {
                        guard let self else { return }
                        self.isFullScreen = value
                        // 退出全屏时 AppKit 留下的那条 toolbar 要立刻收走，
                        // 否则窗口顶上会多出一条空工具栏。
                        if !value, let window = self.window { self.removeToolbar(from: window) }
                    }
                }
                fullScreenObservers.append(observer)
            }

            // SwiftUI 会在搜索、Inspector 与聚焦视图重建时再次安装空 NSToolbar。
            // 只监听属性变化并立即移除，不再使用轮询 Timer，也不改任何列布局。
            toolbarObservation = newWindow.observe(\.toolbar, options: [.new]) { [weak self] window, change in
                guard change.newValue != nil else { return }
                if Thread.isMainThread {
                    // toolbar 的 KVO 在 AppKit 主线程同步发出；当场移除，避免先画一帧
                    // 自动 sidebar/expand 图标再消失（搜索框获取焦点时最明显）。
                    MainActor.assumeIsolated {
                        guard let self, self.window === window else { return }
                        self.removeToolbar(from: window)
                    }
                } else {
                    Task { @MainActor [weak self, weak window] in
                        guard let self, let window, self.window === window else { return }
                        self.removeToolbar(from: window)
                    }
                }
            }
            apply()
            // NavigationSplitView 在首轮 AppKit 布局结束时才会安装自己的 toolbar。
            // 同一轮主队列再校正一次，避免它恰好发生在 KVO 建立之前而漏掉。
            Task { @MainActor [weak self, weak newWindow] in
                guard let self, let newWindow, self.window === newWindow else { return }
                self.removeToolbar(from: newWindow)
            }
        }

        /// **每一处写入都必须先比对再赋值**。`apply()` 由 `updateNSView` 驱动，
        /// SwiftUI 每次重绘都会走一遍；全屏下把鼠标顶到屏幕上沿会让系统菜单栏滑出、
        /// 窗口跟着改高度，于是整段动画期间这里被连续调用几十次。无条件写
        /// `styleMask` / `backgroundColor` 会反复让 NSThemeFrame 失效，而红绿灯的
        /// 点击是一次 `trackMouse` 模态循环——按下去的那一刻循环被打断，
        /// 按钮就只剩"画得出来、悬停有反馈、点了没反应"。
        func apply() {
            guard let window else { return }
            AppKitScrollNormalizer.normalize(window: window)
            trafficLights.attach(to: window)
            trafficLights.apply()
            let level: NSWindow.Level = alwaysOnTop ? .floating : .normal
            if window.level != level { window.level = level }
            if !window.styleMask.contains(.fullSizeContentView) {
                window.styleMask.insert(.fullSizeContentView)
            }
            if !window.titlebarAppearsTransparent { window.titlebarAppearsTransparent = true }
            if window.titleVisibility != .hidden { window.titleVisibility = .hidden }
            if window.backgroundColor != .textBackgroundColor {
                window.backgroundColor = .textBackgroundColor
            }
            removeToolbar(from: window)
            // 不要在这里读 styleMask：全屏过渡期间它翻转的时机在动画中段，
            // 会把 will* 通知刚settle 好的状态又推回去，画面来回抖一次。
            onFullScreenChange?(isFullScreen)
        }

        func detach() {
            toolbarObservation?.invalidate()
            toolbarObservation = nil
            fullScreenObservers.forEach(NotificationCenter.default.removeObserver)
            fullScreenObservers = []
            trafficLights.detach()
            window = nil
        }

        /// 窗口不挂工具栏（控件都在各列自己的头部），但 SwiftUI 每次重建视图
        /// 都会塞一条空的进来，所以这里一发现就摘掉。全屏也要摘：留着的话
        /// `NavigationSplitView` 自带的侧栏切换按钮会冒出来，和我们列头里那颗撞车。
        ///
        /// （曾经怀疑「全屏摘 toolbar 导致红绿灯点不动」，已证伪。）
        private func removeToolbar(from window: NSWindow) {
            guard !isRemovingToolbar, window.toolbar != nil else { return }
            isRemovingToolbar = true
            window.toolbar = nil
            isRemovingToolbar = false
        }
    }
}

/// `NSViewRepresentable.updateNSView` 不保证在视图真正进入窗口后再调用；
/// 用 AppKit 生命周期回调把窗口交给 Coordinator，避免首次启动漏配 chrome。
private final class WindowAttachmentView: NSView {
    private let onWindowChange: (NSWindow?) -> Void

    init(onWindowChange: @escaping (NSWindow?) -> Void) {
        self.onWindowChange = onWindowChange
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        onWindowChange(window)
    }
}

private struct TrailingWindowChrome: View {
    @Bindable var workspace: WorkspaceState
    @Bindable var dataStore: LegacyDataStore

    private var hasConversationContext: Bool {
        guard let id = workspace.selectedConversationID,
              let conversation = dataStore.conversations.first(where: { $0.id == id })
        else { return !workspace.sources.isEmpty }
        return !workspace.conversationContext(for: conversation).isEmpty
            || !workspace.sources.isEmpty
    }

    /// 对齐 Codex 的两段式：内容列尾部一枚控件贴在中间列右缘（第三列打开时正好在分栏线左侧），
    /// 第三列自己的控件占满第三列宽度——标签胶囊在它的左缘、展开/收起在窗口最右。
    var body: some View {
        // 第三列打开时，中间列这边只留上下文开关；标签胶囊与展开/收起
        // 归第三列自己的头部（`ToolWorkspaceView`），不再靠等宽区块去"盖住"它。
        HStack(spacing: AppDesign.Spacing.xxs) {
            if workspace.isToolWorkspacePresented {
                contextPanelButton
            } else {
                chromeButtons
                    .padding(.horizontal, 4)
                    .padding(.vertical, 2)
                    .background { Color.clear.titlebarControlGroup() }
            }
        }
        .opacity(workspace.isSettingsPresented && !workspace.isToolWorkspacePresented ? 0 : 1)
        .allowsHitTesting(!workspace.isSettingsPresented || workspace.isToolWorkspacePresented)
    }

    /// 任务上下文开关。第三列打开时它单独留在中间列右缘（对齐 Codex）。
    private var contextPanelButton: some View {
        Button {
            workspace.toggleContextPanel()
        } label: {
            titlebarIcon(
                workspace.isContextPanelPresented && hasConversationContext
                    ? "list.bullet.rectangle.fill"
                    : "list.bullet.rectangle",
                isSelected: workspace.isContextPanelPresented && hasConversationContext
            )
        }
        .buttonStyle(.plain)
        .disabled(workspace.selectedSection != .conversation || !hasConversationContext)
        .help(workspace.isContextPanelPresented ? "收起任务上下文" : "显示任务上下文")
    }

    private var chromeButtons: some View {
        HStack(spacing: 2) {
            ShareLink(item: "LeetLens · 学习记录") {
                titlebarIcon("square.and.arrow.up")
            }
            .buttonStyle(.plain)
            .help("分享学习记录")

            contextPanelButton

            Button {
                workspace.toggleToolWorkspace()
            } label: {
                titlebarIcon("sidebar.right", isSelected: workspace.isToolWorkspacePresented) {
                    if workspace.hasPendingToolActivity {
                        Circle()
                            .fill(AppDesign.ColorToken.warning)
                            .frame(width: 6, height: 6)
                            .overlay(Circle().stroke(.background, lineWidth: 1))
                            .offset(x: 3, y: -2)
                    }
                }
            }
            .buttonStyle(.plain)
            .help(workspace.isToolWorkspacePresented ? "收起工具工作区" : "展开工具工作区")
            .keyboardShortcut("b", modifiers: [.command, .shift])
        }
    }

    private func titlebarIcon<Badge: View>(
        _ systemName: String,
        isSelected: Bool = false,
        @ViewBuilder badge: () -> Badge
    ) -> some View {
        ZStack(alignment: .topTrailing) {
            Image(systemName: systemName)
                .font(AppDesign.Typography.icon)
                .symbolRenderingMode(.hierarchical)
                .contentTransition(.symbolEffect(.replace))
                .frame(width: 30, height: 24)
                .background(
                    isSelected ? AppDesign.ColorToken.separator : .clear,
                    in: Capsule()
                )

            badge()
                .padding(5)
        }
        .contentShape(Capsule())
    }

    private func titlebarIcon(_ systemName: String, isSelected: Bool = false) -> some View {
        titlebarIcon(systemName, isSelected: isSelected) { EmptyView() }
    }
}

private struct TitlebarControlGroupModifier: ViewModifier {
    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content.glassEffect(.regular.interactive(), in: .capsule)
        } else {
            content
                .background(.regularMaterial, in: Capsule())
                .overlay {
                    Capsule().strokeBorder(.primary.opacity(0.08))
                }
        }
    }
}

private extension View {
    func titlebarControlGroup() -> some View {
        modifier(TitlebarControlGroupModifier())
    }
}

private struct FocusedToolWorkspaceView: View {
    @Bindable var workspace: WorkspaceState
    @Bindable var dataStore: LegacyDataStore

    var body: some View {
        ToolWorkspaceView(workspace: workspace, dataStore: dataStore)
            .background(AppDesign.ColorToken.canvas.ignoresSafeArea())
        .accessibilityElement(children: .contain)
    }
}

private struct PrimaryWorkspaceView: View {
    @Bindable var workspace: WorkspaceState
    @Bindable var dataStore: LegacyDataStore
    /// 中间列的实测宽度。问题刻度条按它决定位置与显隐。
    @State private var columnWidth: CGFloat = 0

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Group {
                switch workspace.selectedSection {
                case .conversation:
                    ConversationWorkspaceView(
                        workspace: workspace,
                        dataStore: dataStore,
                        contentTrailingInset: contextContentTrailingInset,
                        contentLeadingInset: questionRailContentInset
                    )
                case .leetCode:
                    LeetCodeWorkspaceView(workspace: workspace, dataStore: dataStore)
                case .plan:
                    StudyPlanWorkspaceView(workspace: workspace, dataStore: dataStore)
                case .review:
                    ReviewWorkspaceView(workspace: workspace, dataStore: dataStore)
                case .library:
                    LearningLibraryWorkspaceView(workspace: workspace, dataStore: dataStore)
                case .knowledge:
                    KnowledgeGraphWorkspaceView(workspace: workspace, dataStore: dataStore)
                case .insights:
                    LearningInsightsWorkspaceView(workspace: workspace, dataStore: dataStore)
                case .templates:
                    LearningTemplatesWorkspaceView(workspace: workspace, dataStore: dataStore)
                case .trash:
                    LearningTrashWorkspaceView(dataStore: dataStore)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(
                .trailing,
                ContextPanelOverlayPolicy.primaryTrailingInset(isVisible: shouldShowContextPanel)
            )
            .transaction(value: shouldShowContextPanel) { transaction in
                transaction.animation = nil
            }

            if shouldShowQuestionRail {
                QuestionRailView(workspace: workspace, questions: questionRailItems)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                    .zIndex(4)
            }

            if shouldShowContextPanel {
                ContextPanelView(
                    workspace: workspace,
                    outputs: conversationContext.outputs,
                    sources: conversationContext.sources + workspace.sources
                )
                    .frame(width: contextPanelWidth)
                    .padding(.top, AppDesign.Spacing.sm)
                    .padding(.trailing, AppDesign.Spacing.sm)
                    .transition(.opacity)
                    .zIndex(10)
            }
        }
        .background(AppDesign.ColorToken.canvas.ignoresSafeArea(.container, edges: .top))
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { columnWidth = $0 }
        .onChange(of: currentContextSources) { _, updated in
            // 只要「来源」标签还开着就跟着换会话更新。以前只在它是当前标签时同步，
            // 于是切了会话再点回来，看到的还是上一场对话的来源。
            if workspace.openToolTabs.contains(.sources) {
                workspace.presentedSources = updated
            }
        }
        .animation(AppDesign.Motion.fade, value: shouldShowContextPanel)
        .overlay {
            if workspace.conversationGeneration?.phase == .generating {
                Button("停止生成") {
                    workspace.stopConversationGeneration()
                }
                .keyboardShortcut(.cancelAction)
                .frame(width: 0, height: 0)
                .opacity(0)
                .accessibilityHidden(true)
            }
        }
    }

    private var shouldShowContextPanel: Bool {
        ContextPanelPresentationPolicy.isVisible(
            contextPresented: workspace.isContextPanelPresented,
            section: workspace.selectedSection,
            hasContext: !conversationContext.isEmpty || !workspace.sources.isEmpty
        )
    }

    private var conversationContext: ConversationContextSnapshot {
        guard let id = workspace.selectedConversationID,
              let conversation = dataStore.conversations.first(where: { $0.id == id })
        else { return ConversationContextSnapshot(outputs: [], sources: []) }
        let persisted = workspace.conversationContext(for: conversation)
        guard let generation = workspace.conversationGeneration,
              generation.conversationID == id,
              !generation.content.isEmpty
        else { return persisted }
        let live = ConversationContextDeriver.derive(messages: [
            ConversationTranscriptMessage(
                id: generation.messageID,
                role: "assistant",
                content: generation.content,
                createdAt: generation.startedAt,
                toolCalls: generation.toolCalls,
                providerID: generation.providerID,
                model: generation.model
            )
        ])
        return persisted.merging(live)
    }

    private var currentContextSources: [ContextItem] {
        conversationContext.sources + workspace.sources
    }

    private var contextPanelWidth: CGFloat {
        min(
            max(workspace.windowWidth * 0.18, AppDesign.Size.contextPanelMinimum),
            AppDesign.Size.contextPanelMaximum
        )
    }

    private var contextContentTrailingInset: CGFloat {
        ContextPanelOverlayPolicy.contentTrailingInset(
            isVisible: shouldShowContextPanel,
            panelWidth: contextPanelWidth
        )
    }

    private var shouldShowQuestionRail: Bool {
        QuestionRailPresentationPolicy.isVisible(
            section: workspace.selectedSection,
            questionCount: questionRailItems.count,
            columnWidth: columnWidth
        )
    }

    /// 刻度条在时正文要给它让出这一条，不让刻度压在字上。
    private var questionRailContentInset: CGFloat {
        shouldShowQuestionRail ? QuestionRailPresentationPolicy.contentInset : 0
    }

    private var questionRailItems: [QuestionRailItem] {
        guard
            let id = workspace.selectedConversationID,
            let conversation = dataStore.conversations.first(where: { $0.id == id })
        else { return [] }

        return workspace.questionRailItems(for: conversation)
    }
}

enum ContextPanelOverlayPolicy {
    static func primaryTrailingInset(isVisible _: Bool) -> CGFloat {
        0
    }

    static func contentTrailingInset(isVisible: Bool, panelWidth: CGFloat) -> CGFloat {
        isVisible ? panelWidth + AppDesign.Spacing.lg : 0
    }
}

/// 对话列头标题与正文 / 输入框共用的中轴：列宽减去右侧浮层后，在 820 内容宽上居中。
enum ConversationColumnLayout {
    static var contentMaximum: CGFloat { AppDesign.Size.contentColumnMaximum }
    static var minimumInset: CGFloat { AppDesign.Spacing.lg }

    /// 正文照旧在列里居中——列宽了就该有留白，不封顶。
    /// `railInset` 是问题刻度条占掉的那一条：列被压窄时正文左缘不能越过它，
    /// 否则刻度直接压在字上（侧栏 + 上下文面板都开着时就是这种局面）。
    static func contentLeadingInset(
        columnWidth: CGFloat,
        trailingInset: CGFloat,
        railInset: CGFloat = 0
    ) -> CGFloat {
        let available = max(0, columnWidth - trailingInset)
        let centered = ((available - contentMaximum) / 2).rounded()
        return max(max(minimumInset, centered), railInset)
    }

    static func titleGapAfterNavigation(
        columnWidth: CGFloat,
        trailingInset: CGFloat,
        headerLeadingPadding: CGFloat,
        navigationWidth: CGFloat,
        railInset: CGFloat = 0
    ) -> CGFloat {
        let leading = contentLeadingInset(
            columnWidth: columnWidth,
            trailingInset: trailingInset,
            railInset: railInset
        )
        return max(0, leading - headerLeadingPadding - navigationWidth)
    }
}

enum QuestionRailPresentationPolicy {
    static let minimumQuestionCount = 6
    static let tickStride: CGFloat = 15
    static let verticalInset: CGFloat = 12
    /// 刻度最长的一档（hover 时的波峰）。排版按它留位，免得展开时顶到正文。
    static let tickMaximumWidth: CGFloat = 32
    /// 刻度条贴着列的左缘——它是"这一列的目录"，不跟着正文跑。
    static let leading: CGFloat = 8
    /// 刻度右缘到正文左缘至少要留的空。
    static let minimumContentGap: CGFloat = 12

    /// 刻度条整体占掉的一条。正文左缘顶多让到这里，再窄就压上刻度了。
    static var contentInset: CGFloat { leading + tickMaximumWidth + minimumContentGap }

    /// 显示刻度所需的最小列宽：正文列 + 刻度那一条，两样都放得下才显示。
    /// 按「有没有地方放」判断，而不是盯着某一列开没开——第三列一展开中间列
    /// 掉到这条线以下自然消失，窗口拉大到三列都够宽时它也该留着。
    static var minimumColumnWidth: CGFloat {
        ConversationColumnLayout.contentMaximum + contentInset
    }

    static func isVisible(
        section: WorkspaceSection,
        questionCount: Int,
        columnWidth: CGFloat
    ) -> Bool {
        section == .conversation
            && questionCount >= minimumQuestionCount
            && columnWidth >= minimumColumnWidth
    }

    static func railHeight(questionCount: Int, availableHeight: CGFloat) -> CGFloat {
        let densityMatchedHeight = CGFloat(max(1, questionCount - 1)) * tickStride + verticalInset * 2
        return min(max(densityMatchedHeight, 96), max(96, availableHeight - 88))
    }
}

enum ContextPanelPresentationPolicy {
    static func isVisible(
        contextPresented: Bool,
        section: WorkspaceSection,
        hasContext: Bool
    ) -> Bool {
        contextPresented
            && section == .conversation
            && hasContext
    }
}

private struct QuestionRailView: View {
    @Bindable var workspace: WorkspaceState
    @State private var hoveredIndex: Int?
    /// 上一个**匹配上的**下标。见 `activeIndex` 的说明。
    @State private var lastResolvedIndex = 0

    let questions: [QuestionRailItem]

    init(workspace: WorkspaceState, questions: [QuestionRailItem]) {
        self.workspace = workspace
        self.questions = questions
    }

    /// 焦点刻度。
    ///
    /// 原来是 `firstIndex { ... } ?? 0`：只要 `activeQuestionID` 一时匹配不上
    /// （刚切会话、消息刚重排、网页侧还没上报第一条），就**回退到 0**，
    /// 焦点条瞬间跳到顶部；下一个滚动事件报上来又跳回中间——
    /// 就是"一会儿在顶部一会儿在中间"。
    /// 匹配不上时保留上一次的位置，什么都不动才是对的。
    private var activeIndex: Int {
        guard let matched = questions.firstIndex(where: { $0.id == workspace.activeQuestionID }) else {
            return min(lastResolvedIndex, max(0, questions.count - 1))
        }
        return matched
    }

    var body: some View {
        GeometryReader { proxy in
            let railHeight = QuestionRailPresentationPolicy.railHeight(
                questionCount: questions.count,
                availableHeight: proxy.size.height
            )
            let railTop = (proxy.size.height - railHeight) / 2

            ZStack(alignment: .leading) {
                ForEach(Array(questions.enumerated()), id: \.element.id) { index, question in
                    Button {
                        workspace.scrollToQuestion(question.id)
                    } label: {
                        Capsule()
                            .fill(tickColor(index))
                            .frame(width: tickWidth(index), height: 3)
                            .frame(width: QuestionRailPresentationPolicy.tickMaximumWidth, height: 16, alignment: .leading)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .position(
                        x: QuestionRailPresentationPolicy.tickMaximumWidth / 2,
                        y: railTop + stablePosition(index: index, height: railHeight)
                    )
                    .accessibilityLabel("跳转到：\(question.question)")
                }

                if let hoveredIndex, questions.indices.contains(hoveredIndex) {
                    railPreview(question: questions[hoveredIndex], index: hoveredIndex)
                        .position(
                            x: QuestionRailPresentationPolicy.tickMaximumWidth + 8 + 130,
                            y: previewPosition(
                                index: hoveredIndex,
                                railTop: railTop,
                                railHeight: railHeight,
                                availableHeight: proxy.size.height
                            )
                        )
                        .transition(.opacity.combined(with: .scale(scale: 0.97, anchor: .leading)))
                        .allowsHitTesting(false)
                        .zIndex(10)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                switch phase {
                case .active(let location):
                    let index = nearestIndex(
                        y: location.y,
                        railTop: railTop,
                        railHeight: railHeight
                    )
                    if hoveredIndex != index {
                        withAnimation(.snappy(duration: 0.20, extraBounce: 0.04)) {
                            hoveredIndex = index
                        }
                    }
                case .ended:
                    withAnimation(AppDesign.Motion.subtle) {
                        hoveredIndex = nil
                    }
                }
            }
        }
        .frame(width: QuestionRailPresentationPolicy.tickMaximumWidth)
        .onChange(of: workspace.activeQuestionID) { _, _ in
            if let matched = questions.firstIndex(where: { $0.id == workspace.activeQuestionID }) {
                lastResolvedIndex = matched
            }
        }
        .animation(.easeOut(duration: 0.15), value: activeIndex)
        .accessibilityLabel("问题导航")
        .frame(maxHeight: .infinity, alignment: .center)
        .padding(.leading, QuestionRailPresentationPolicy.leading)
    }

    private func tickWidth(_ index: Int) -> CGFloat {
        guard let hoveredIndex else {
            return index == activeIndex ? 20 : 10
        }
        let distance = CGFloat(abs(index - hoveredIndex))
        let wave = 1 / (1 + pow(distance / 1.65, 1.7))
        return 10 + 22 * wave
    }

    private func tickColor(_ index: Int) -> Color {
        if index == activeIndex { return .primary }
        guard let hoveredIndex else { return .secondary.opacity(0.28) }
        let distance = Double(abs(index - hoveredIndex))
        return .secondary.opacity(max(0.28, 0.72 - distance * 0.10))
    }

    private func stablePosition(index: Int, height: CGFloat) -> CGFloat {
        guard questions.count > 1 else { return height / 2 }
        let inset = QuestionRailPresentationPolicy.verticalInset
        let usableHeight = max(1, height - inset * 2)
        return inset + usableHeight * CGFloat(index) / CGFloat(questions.count - 1)
    }

    private func nearestIndex(y: CGFloat, railTop: CGFloat, railHeight: CGFloat) -> Int? {
        guard y >= railTop - 12, y <= railTop + railHeight + 12, questions.count > 1 else { return nil }
        let inset = QuestionRailPresentationPolicy.verticalInset
        let progress = min(max((y - railTop - inset) / max(1, railHeight - inset * 2), 0), 1)
        return min(max(Int((progress * CGFloat(questions.count - 1)).rounded()), 0), questions.count - 1)
    }

    private func previewPosition(
        index: Int,
        railTop: CGFloat,
        railHeight: CGFloat,
        availableHeight: CGFloat
    ) -> CGFloat {
        let raw = railTop + stablePosition(index: index, height: railHeight)
        return min(max(raw, 56), availableHeight - 56)
    }

    private func railPreview(question: QuestionRailItem, index: Int) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(question.question)
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
            Text(question.answer)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Text("当前会话 · 第 \(index + 1) 次提问")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .frame(width: 260, alignment: .leading)
        .navigationGlass(cornerRadius: AppDesign.Radius.medium)
    }
}
