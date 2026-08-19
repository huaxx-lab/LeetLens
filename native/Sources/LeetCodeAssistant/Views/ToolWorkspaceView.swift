import Combine
import SwiftUI
import WebKit

struct ToolWorkspaceView: View {
    @Bindable var workspace: WorkspaceState
    @Bindable var dataStore: LegacyDataStore
    @ObservedObject private var browserSession = BrowserSession.shared
    @State private var hoveredTabID: String?
    /// 正在被拖的标签。拖动期间界面读 `dragOrder`，底层数据一动不动。
    @State private var draggedTab: TabStripItem?
    @State private var dragOrder: [TabStripItem]?
    @State private var dragOffset: CGFloat = 0
    @State private var dragGrabOffset: CGFloat = 0
    /// 标签条内容相对可视区的起点。标签条自己会滚，算落点必须带上它。
    @State private var stripContentOrigin: CGFloat = 0

    var body: some View {
        VStack(spacing: 0) {
            // 占满模式仍然是浏览器，不是纯网页预览：标签栏与地址栏不能消失。
            toolColumnHeader
                .padding(.top, toolHeaderTopInset)
            Divider()

            toolContents
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(AppDesign.ColorToken.canvas)
        .onChange(of: workspace.activeTool) { oldValue, newValue in
            if oldValue == .browser, newValue != .browser {
                browserSession.suspendMedia()
            }
        }
        .onChange(of: workspace.isToolWorkspacePresented) { _, isPresented in
            if !isPresented { browserSession.suspendMedia() }
        }
        // 恢复上次的页面推迟到这里：启动时第三列没打开就不该偷偷加载。
        .task { browserSession.activateIfNeeded() }
        .onReceive(browserSession.$currentAddress.combineLatest(browserSession.$pageTitle)) { address, title in
            guard let url = URL(string: address) else { return }
            try? dataStore.recordVideoVisit(url: url, title: title)
        }
    }

    private var toolContents: some View {
        ZStack {
            if workspace.openToolTabs.contains(.browser) {
                toolLayer(.browser) { BrowserToolView(workspace: workspace) }
            }
            if workspace.openToolTabs.contains(.video) {
                toolLayer(.video) {
                    EmptyRuntimeToolView(title: "尚未选择视频", systemImage: "play.rectangle", description: "B 站视频链接会在保留会话的内置浏览器标签中播放。")
                }
            }
            if workspace.openToolTabs.contains(.preview) {
                toolLayer(.preview) {
                    RuntimeArtifactToolView(
                        item: workspace.selectedToolItems[.preview],
                        emptyTitle: "暂无可预览内容",
                        systemImage: "doc.richtext"
                    )
                }
            }
            if workspace.openToolTabs.contains(.run) {
                toolLayer(.run) {
                    RuntimeArtifactToolView(
                        item: workspace.selectedToolItems[.run],
                        emptyTitle: "尚未运行代码",
                        systemImage: "terminal"
                    )
                }
            }
            if workspace.openToolTabs.contains(.evidence) {
                toolLayer(.evidence) { EvidenceToolView(workspace: workspace, dataStore: dataStore) }
            }
            if workspace.openToolTabs.contains(.sources) {
                toolLayer(.sources) { SourcesToolView(workspace: workspace) }
            }
        }
    }

    private func toolLayer<Content: View>(
        _ tool: ToolKind,
        @ViewBuilder content: () -> Content
    ) -> some View {
        content()
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .opacity(workspace.activeTool == tool ? 1 : 0)
            .allowsHitTesting(workspace.activeTool == tool)
            .accessibilityHidden(workspace.activeTool != tool)
            .zIndex(workspace.activeTool == tool ? 1 : 0)
    }

    private var toolColumnHeader: some View {
        GeometryReader { geometry in
            HStack(spacing: AppDesign.Spacing.xs) {
                if showsFocusedWorkspaceChrome {
                    focusedWorkspaceChrome
                }

                // 标签、`+`、右侧窗口按钮共用一条中线。以前标签单独往下挪了 7pt，
                // 只有一个标签时那点错位最扎眼——看着就像标签掉在了工具栏外面。
                unifiedTabStrip(
                    maximumWidth: BrowserTabStripSizingPolicy.availableWidth(
                        headerWidth: geometry.size.width,
                        showsFocusedChrome: showsFocusedWorkspaceChrome
                    )
                )

                toolHeaderButton("plus", help: "新标签页") {
                    browserSession.openBlankTab()
                    workspace.selectToolTab(.browser)
                }

                Spacer(minLength: AppDesign.Spacing.xs)

                if workspace.isToolWorkspaceFocused {
                    toolHeaderButton("arrow.down.right.and.arrow.up.left", help: "恢复分栏") {
                        workspace.restoreToolWorkspace()
                    }
                    toolHeaderButton("xmark", help: "关闭工具工作区") {
                        workspace.dismissToolWorkspace()
                    }
                } else {
                    toolHeaderButton("arrow.up.left.and.arrow.down.right", help: "展开面板") {
                        workspace.focusToolWorkspace()
                    }
                    toolHeaderButton("sidebar.right", help: "收起工具工作区", isSelected: true) {
                        workspace.dismissToolWorkspace()
                    }
                }
            }
            .frame(maxHeight: .infinity, alignment: .center)
        }
        .padding(.leading, showsFocusedWorkspaceChrome ? workspace.headerLeadingInset : AppDesign.Spacing.xs)
        .padding(.trailing, AppDesign.Spacing.xs)
        .frame(height: AppDesign.Size.columnHeader)
    }

    private var showsFocusedWorkspaceChrome: Bool {
        workspace.isToolWorkspaceFocused
            && !workspace.isSettingsPresented
            && !workspace.isSidebarPresented
    }

    private var focusedWorkspaceChrome: some View {
        HStack(spacing: AppDesign.Spacing.xxs) {
            toolHeaderButton("sidebar.left", help: "显示侧栏") {
                workspace.toggleSidebar()
            }

            toolHeaderButton("chevron.left", help: "后退", disabled: !workspace.canNavigateBack) {
                withAnimation(AppDesign.Motion.selection) { workspace.navigateBack() }
            }

            toolHeaderButton("chevron.right", help: "前进", disabled: !workspace.canNavigateForward) {
                withAnimation(AppDesign.Motion.selection) { workspace.navigateForward() }
            }

            toolHeaderButton("square.and.pencil", help: "新建会话") {
                withAnimation(AppDesign.Motion.selection) {
                    workspace.restoreToolWorkspace()
                    workspace.selectedConversationID = nil
                    workspace.selectedSection = .conversation
                }
            }
        }
        .fixedSize()
        // 标签胶囊需要离开窗口顶边，但左上导航仍应和红绿灯同一中线。
        .offset(y: -toolHeaderTopInset)
    }

    private var toolHeaderTopInset: CGFloat {
        ToolHeaderLayoutPolicy.topInset(isFullScreen: workspace.isWindowFullScreen)
    }

    /// 一条标签栏，工具标签和网页标签排在一起。
    ///
    /// 宽度是动态的：标签多了先一起变窄，窄到下限还放不下才滚动。
    /// 拖动时不动底层数据，只改一份临时顺序，松手才落盘——
    /// 这样拖到一半松手不会留下半成品，动画也只需要跟着这一份顺序走。
    private func unifiedTabStrip(maximumWidth: CGFloat) -> some View {
        let items = displayedTabs
        let width = BrowserTabStripSizingPolicy.tabWidth(
            available: maximumWidth,
            count: items.count,
            isFocused: workspace.isToolWorkspaceFocused
        )
        let content = BrowserTabStripSizingPolicy.contentWidth(count: items.count, tabWidth: width)
        let stripWidth = min(content, maximumWidth)

        // 标签条落在标题栏那一带：AppKit 认为按在这里是要拖窗口，而且拖拽在
        // mouseDown 当场就开始，SwiftUI 手势根本来不及接管——表现就是
        // "拖标签结果整扇窗口跟着走"。放进我们自己的 hosting view 才拦得住。
        return NonWindowDragging(
            content: tabStripContent(items: items, width: width)
                .frame(width: stripWidth, height: AppDesign.Size.columnHeader, alignment: .leading)
        )
        .frame(width: stripWidth, height: AppDesign.Size.columnHeader, alignment: .leading)
    }

    private func tabStripContent(items: [TabStripItem], width: CGFloat) -> some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal) {
                HStack(spacing: BrowserTabStripSizingPolicy.spacing) {
                    ForEach(items) { item in
                        tabCell(item, width: width, items: items, proxy: proxy)
                    }
                }
                .frame(height: AppDesign.Size.columnHeader, alignment: .center)
                // 拖动时被拖的那一张自己跟手，其余靠这里的动画让位。
                .animation(AppDesign.Motion.selection, value: items)
                .onGeometryChange(for: CGFloat.self) { proxy in
                    proxy.frame(in: .named(ToolWorkspaceView.stripSpaceName)).minX
                } action: { origin in
                    stripContentOrigin = origin
                }
            }
            // 必须是 .never 而不是 .hidden：.hidden 只是不画，指示器那条空间照留，
            // 于是标签一旦多到要滚动，整排就被那条留白往上顶。
            .scrollIndicators(.never)
            .coordinateSpace(name: ToolWorkspaceView.stripSpaceName)
            .onChange(of: workspace.activeTool) { _, activeTool in
                guard draggedTab == nil, activeTool != .browser else { return }
                withAnimation(AppDesign.Motion.selection) {
                    proxy.scrollTo(TabStripItem.tool(activeTool).id, anchor: .center)
                }
            }
            .onChange(of: activeBrowserTabID) { _, id in
                guard draggedTab == nil, let id, workspace.activeTool == .browser else { return }
                withAnimation(AppDesign.Motion.selection) {
                    proxy.scrollTo(TabStripItem.web(id).id, anchor: .center)
                }
            }
        }
    }

    /// 标签条自己的坐标系。拖动落点要用指针在这个坐标系里的位置算，
    /// 所以它不能是 @MainActor 隔离的实例成员——`onGeometryChange` 的闭包是 Sendable 的。
    nonisolated static let stripSpaceName = "tool.tabstrip"

    /// 当前应该显示的标签顺序。拖动中用临时顺序，其余时候由记住的顺序推出来。
    private var displayedTabs: [TabStripItem] {
        dragOrder ?? TabStripOrder.items(
            tools: workspace.openToolTabs.filter { $0 != .browser },
            web: browserSession.tabs.map(\.id),
            remembered: workspace.tabStripOrder
        )
    }

    private var activeBrowserTabID: UUID? {
        browserSession.tabs.first { $0.isActive }?.id
    }

    private func title(for item: TabStripItem) -> String {
        switch item {
        case .tool(let kind): kind.title
        case .web(let id): browserSession.tabs.first { $0.id == id }?.title ?? "新标签页"
        }
    }

    private func systemImage(for item: TabStripItem) -> String {
        switch item {
        case .tool(let kind): kind.systemImage
        case .web: "globe"
        }
    }

    private func isSelected(_ item: TabStripItem) -> Bool {
        switch item {
        case .tool(let kind): workspace.activeTool == kind
        case .web(let id):
            workspace.activeTool == .browser && browserSession.tabs.first { $0.id == id }?.isActive == true
        }
    }

    private func select(_ item: TabStripItem) {
        switch item {
        case .tool(let kind):
            workspace.selectToolTab(kind)
        case .web(let id):
            browserSession.selectTab(id)
            workspace.selectToolTab(.browser)
        }
    }

    private func close(_ item: TabStripItem) {
        let items = displayedTabs
        let wasSelected = isSelected(item)
        switch item {
        case .tool(let kind): workspace.closeToolTab(kind)
        case .web(let id): browserSession.closeTab(id)
        }
        // 关掉的不是当前这张就别动焦点，正在看的东西不该被别处的关闭动作带走。
        guard wasSelected, let next = TabStripOrder.neighbour(of: item, in: items) else { return }
        select(next)
    }

    private func tabCell(
        _ item: TabStripItem,
        width: CGFloat,
        items: [TabStripItem],
        proxy: ScrollViewProxy
    ) -> some View {
        let dragging = draggedTab == item
        let selected = isSelected(item)
        let hovered = hoveredTabID == item.id
        return HStack(spacing: 5) {
            Image(systemName: systemImage(for: item))
                .font(AppDesign.Typography.auxEmphasis)
                .foregroundStyle(.secondary)
            Text(title(for: item))
                .font(AppDesign.Typography.bodyEmphasis)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 0)
            Button {
                close(item)
            } label: {
                Image(systemName: "xmark")
                    .font(AppDesign.Typography.micro)
                    .foregroundStyle(.secondary)
                    .frame(width: AppDesign.Size.iconSlot, height: AppDesign.Size.iconSlot)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("关闭\(title(for: item))")
            .fixedSize()
            .opacity(selected || hovered ? 1 : 0)
            .allowsHitTesting(selected || hovered)
        }
        .padding(.leading, AppDesign.Spacing.compact)
        .padding(.trailing, AppDesign.Spacing.xxs)
        .frame(width: width, height: AppDesign.Size.fieldHeight)
        .background(
            selected
                ? AppDesign.ColorToken.inlineFill
                : (hovered ? AppDesign.ColorToken.hover : .clear),
            in: RoundedRectangle(cornerRadius: AppDesign.Radius.medium, style: .continuous)
        )
        .contentShape(Rectangle())
        .onHover { hovering in
            hoveredTabID = hovering ? item.id : (hoveredTabID == item.id ? nil : hoveredTabID)
        }
        .onTapGesture { select(item) }
        .highPriorityGesture(dragGesture(for: item, width: width, proxy: proxy))
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { select(item) }
        .help("切换或拖动标签页")
        // 被拖的那一张 1:1 跟手，不参与让位动画，否则拖起来像在追鼠标。
        .offset(x: dragging ? dragOffset : 0)
        .scaleEffect(dragging ? 1.02 : 1)
        .zIndex(dragging ? 2 : 0)
        .shadow(
            color: .black.opacity(dragging ? 0.16 : 0),
            radius: dragging ? 9 : 0,
            y: dragging ? 3 : 0
        )
        .animation(dragging ? nil : AppDesign.Motion.selection, value: dragOffset)
        .id(item.id)
    }

    private func dragGesture(
        for item: TabStripItem,
        width: CGFloat,
        proxy: ScrollViewProxy
    ) -> some Gesture {
        DragGesture(
            minimumDistance: BrowserTabOrderPolicy.dragMinimumDistance,
            coordinateSpace: .named(ToolWorkspaceView.stripSpaceName)
        )
        .onChanged { value in
            let items = displayedTabs
            guard let index = items.firstIndex(of: item) else { return }
            let stride = width + BrowserTabStripSizingPolicy.spacing

            if draggedTab != item {
                draggedTab = item
                dragOrder = items
                // 抓在标签内部什么位置，松手前就一直保持在那个位置，不会突然跳到指针底下。
                dragGrabOffset = value.startLocation.x - (stripContentOrigin + CGFloat(index) * stride)
            }

            let target = TabStripOrder.index(
                forPointer: value.location.x,
                contentOrigin: stripContentOrigin,
                tabWidth: width,
                count: items.count
            )
            if target != index {
                dragOrder = TabStripOrder.moved(items, dragging: item, to: target)
                // 落到边上的那一格时把相邻标签滚出来，藏起来的也换得了位置。
                withAnimation(AppDesign.Motion.selection) {
                    proxy.scrollTo(item.id, anchor: target > index ? .trailing : .leading)
                }
            }
            let slot = stripContentOrigin + CGFloat(target) * stride
            dragOffset = value.location.x - dragGrabOffset - slot
        }
        .onEnded { _ in
            guard draggedTab == item, let order = dragOrder else { return }
            commitTabOrder(order)
            withAnimation(AppDesign.Motion.selection) {
                draggedTab = nil
                dragOrder = nil
                dragOffset = 0
                dragGrabOffset = 0
            }
        }
    }

    /// 拖完落盘。统一顺序记在 workspace 上，两类标签各自的相对顺序回写给各自的家。
    private func commitTabOrder(_ order: [TabStripItem]) {
        workspace.rememberTabStripOrder(order.map(\.id))
        workspace.reorderToolTabs(order.compactMap { item in
            if case .tool(let kind) = item { return kind }
            return nil
        })
        browserSession.reorderTabs(order.compactMap { item in
            if case .web(let id) = item { return id }
            return nil
        })
    }

    private func toolHeaderButton(
        _ systemName: String,
        help: String,
        isSelected: Bool = false,
        disabled: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(AppDesign.Typography.icon)
                .symbolRenderingMode(.hierarchical)
                .frame(width: 32, height: 30)
                .background(isSelected ? AppDesign.ColorToken.separator : .clear, in: Capsule())
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .foregroundStyle(disabled ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.primary))
        .help(help)
    }

}

private struct SourcesToolView: View {
    @Bindable var workspace: WorkspaceState

    private var groups: [ContextSourceGroup] {
        ContextSourceGrouping.groups(for: workspace.presentedSources)
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: AppDesign.Spacing.lg) {
                ForEach(groups) { group in
                    VStack(alignment: .leading, spacing: AppDesign.Spacing.xxs) {
                        Label(group.category.rawValue, systemImage: group.category.systemImage)
                            .font(AppDesign.Typography.bodyEmphasis)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, AppDesign.Spacing.sm)

                        ForEach(group.items) { item in
                            Button {
                                // 点一条就跳过去看。「来源」标签本身不会关，
                                // 看完点回来清单还在原处。
                                workspace.openContextItem(item)
                            } label: {
                                HStack(spacing: AppDesign.Spacing.compact) {
                                    Image(systemName: item.systemImage)
                                        .font(AppDesign.Typography.icon)
                                        .symbolRenderingMode(.hierarchical)
                                        .foregroundStyle(.secondary)
                                        .frame(width: AppDesign.Size.iconSlot)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(item.title)
                                            .font(AppDesign.Typography.bodyEmphasis)
                                            .foregroundStyle(.primary)
                                            .lineLimit(2)
                                        Text(item.subtitle)
                                            .font(AppDesign.Typography.aux)
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                    }
                                    Spacer(minLength: AppDesign.Spacing.xs)
                                    Image(systemName: "chevron.right")
                                        .font(AppDesign.Typography.micro)
                                        .foregroundStyle(.tertiary)
                                }
                                .padding(.horizontal, AppDesign.Spacing.sm)
                                .frame(maxWidth: .infinity, minHeight: 52, alignment: .leading)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .padding(.vertical, AppDesign.Spacing.md)
        }
        .scrollIndicators(.hidden)
        .overlay {
            if groups.isEmpty {
                ContentUnavailableView("暂无来源", systemImage: "link", description: Text("联网搜索或引用网页后会在这里分类显示"))
            }
        }
    }
}

private struct BrowserToolView: View {
    @Bindable var workspace: WorkspaceState
    @ObservedObject private var session = BrowserSession.shared
    /// 只是地址栏的编辑副本；页面与历史由 BrowserSession 的每个标签持有。
    @State private var address: String
    @FocusState private var isAddressFocused: Bool

    init(workspace: WorkspaceState) {
        self.workspace = workspace
        let current = BrowserSession.shared.currentAddress
        _address = State(initialValue: current)
    }

    var body: some View {
        VStack(spacing: 0) {
            browserNavigationBar
            Divider()

            if !session.hasActivePage {
                ContentUnavailableView(
                    "开始浏览",
                    systemImage: "globe",
                    description: Text("输入 URL 以打开页面")
                )
            } else {
                ZStack(alignment: .topTrailing) {
                    BrowserWebView(session: session)

                    if session.isLoading {
                        ProgressView()
                            .controlSize(.small)
                            .padding(AppDesign.Spacing.sm)
                    }

                    if let message = session.loadError, !session.isLoading {
                        ContentUnavailableView {
                            Label("网页加载失败", systemImage: "exclamationmark.triangle")
                        } description: {
                            Text(message)
                        } actions: {
                            Button("重新加载") { session.reload() }
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(AppDesign.ColorToken.canvas)
                    }
                }
            }
        }
        .onReceive(session.$currentAddress) { value in
            // 重定向只回填地址栏，不再写入任何全局导航状态。
            guard !isAddressFocused, value != address else { return }
            address = value
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var browserNavigationBar: some View {
        HStack(spacing: 6) {
            browserCommand("chevron.left", help: "后退", disabled: !session.canGoBack) {
                session.goBack()
            }
            browserCommand("chevron.right", help: "前进", disabled: !session.canGoForward) {
                session.goForward()
            }
            browserCommand("arrow.clockwise", help: "重新加载", disabled: !session.hasActivePage) {
                session.reload()
            }

            TextField("输入 URL", text: $address)
                .focused($isAddressFocused)
                .textFieldStyle(.plain)
                .multilineTextAlignment(.center)
                .padding(.horizontal, AppDesign.Spacing.compact)
                .frame(height: AppDesign.Size.fieldHeight)
                .background(
                    AppDesign.ColorToken.inlineFill,
                    in: RoundedRectangle(cornerRadius: AppDesign.Radius.medium, style: .continuous)
                )
                .onSubmit { navigateToAddress() }
                .onChange(of: isAddressFocused) { _, focused in
                    guard !focused, !session.currentAddress.isEmpty else { return }
                    address = session.currentAddress
                }

            Menu {
                Button("新标签页", systemImage: "plus", action: openNewTab)
                Button("重新加载", systemImage: "arrow.clockwise") { session.reload() }
                    .disabled(!session.hasActivePage)
                Button("复制地址", systemImage: "doc.on.doc") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(address, forType: .string)
                }
                .disabled(address.isEmpty)
            } label: {
                Image(systemName: "ellipsis")
                    .font(AppDesign.Typography.iconCompact)
                    .frame(
                        width: AppDesign.Size.toolbarControl,
                        height: AppDesign.Size.toolbarControl
                    )
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .frame(width: AppDesign.Size.toolbarControl)
            .help("浏览器菜单")
        }
        .buttonStyle(.plain)
        .padding(.horizontal, AppDesign.Spacing.sm)
        .padding(.vertical, AppDesign.Spacing.xs)
        .background(AppDesign.ColorToken.canvas)
    }

    private func browserCommand(
        _ systemName: String,
        help: String,
        disabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(AppDesign.Typography.iconCompact)
                .frame(
                    width: AppDesign.Size.toolbarControl,
                    height: AppDesign.Size.toolbarControl
                )
                .contentShape(Rectangle())
        }
        .disabled(disabled)
        .help(help)
    }

    private func navigateToAddress() {
        guard let normalized = BrowserAddressPolicy.normalize(address) else { return }
        address = normalized
        if let url = URL(string: normalized) { session.navigate(to: url) }
    }

    private func openNewTab() {
        session.openBlankTab()
        address = ""
    }

}

/// 地址栏输入与导航判定。抽成纯函数以便测试。
enum BrowserAddressPolicy {
    static let desktopSafariUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) "
        + "AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15"

    /// 地址栏输入规范化：缺协议时补 https，空串返回 nil。
    static func normalize(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let candidate = trimmed.contains("://") ? trimmed : "https://\(trimmed)"
        guard let components = URLComponents(string: candidate),
              let scheme = components.scheme?.lowercased(),
              ["http", "https"].contains(scheme),
              components.host?.isEmpty == false,
              let url = components.url
        else { return nil }
        return url.absoluteString
    }

    /// 是否需要发起导航。基准是上次**请求**的地址，而不是 webView 的当前地址：
    /// 页面重定向后（baidu.com → https://www.baidu.com/）后者永远不等于请求地址，
    /// 于是每次 `updateNSView` 都会重新加载一遍，表现为页面一直闪。
    static func shouldNavigate(requested: URL, lastRequested: URL?) -> Bool {
        requested != lastRequested
    }

    static func shouldNavigate(requested: URL, pending: URL?, isLoading: Bool) -> Bool {
        !isLoading || requested != pending
    }

    /// 已经位于同一主机的 HTTPS 页面时，不允许页面脚本把顶层导航降级到 HTTP。
    /// 百度会重复发起这种降级，放行会让地址栏在 http/https 之间持续抖动。
    static func shouldBlockInsecureDowngrade(
        requested: URL?,
        current: URL?,
        isMainFrame: Bool
    ) -> Bool {
        guard isMainFrame,
              requested?.scheme?.lowercased() == "http",
              current?.scheme?.lowercased() == "https",
              let requestedHost = requested?.host?.lowercased(),
              requestedHost == current?.host?.lowercased()
        else { return false }
        return true
    }
}

enum BrowserHostClaimPolicy {
    static func accepts(candidateGeneration: UInt64, activeGeneration: UInt64) -> Bool {
        candidateGeneration >= activeGeneration
    }
}

enum BrowserTabOpeningPolicy {
    static func shouldReuseActiveTab(requestedNewTab: Bool, activeTabHasPage: Bool) -> Bool {
        requestedNewTab && !activeTabHasPage
    }
}

enum BrowserTabOrderPolicy {
    static let dragMinimumDistance: CGFloat = 6

    static func reordered(_ ids: [UUID], dragging: UUID, over target: UUID) -> [UUID] {
        guard dragging != target,
              let sourceIndex = ids.firstIndex(of: dragging),
              let targetIndex = ids.firstIndex(of: target)
        else { return ids }

        var result = ids
        let moved = result.remove(at: sourceIndex)
        result.insert(moved, at: min(targetIndex, result.count))
        return result
    }

    static func targetIndex(
        startIndex: Int,
        translation: CGFloat,
        tabExtent: CGFloat,
        count: Int
    ) -> Int {
        guard count > 0, tabExtent > 0 else { return 0 }
        let crossedTabs = Int((translation / tabExtent).rounded())
        return min(max(startIndex + crossedTabs, 0), count - 1)
    }

    static func moved(_ ids: [UUID], dragging: UUID, toIndex: Int) -> [UUID] {
        guard let sourceIndex = ids.firstIndex(of: dragging), !ids.isEmpty else { return ids }
        var result = ids
        let moved = result.remove(at: sourceIndex)
        result.insert(moved, at: min(max(toIndex, 0), result.count))
        return result
    }
}

/// 把一段界面放进「按在这儿不算拖窗口」的 hosting view。
///
/// 标签条落在窗口标题栏那一带。AppKit 在 mouseDown 当场就决定要不要拖窗口——
/// 依据是命中的那个 NSView 的 `mouseDownCanMoveWindow`——SwiftUI 的手势根本来不及接管，
/// 表现就是"拖标签结果整扇窗口跟着走"。
///
/// 两条走不通的路（scratchpad/drag-harness*.swift 实测）：
/// ① 在背景垫一层 `mouseDownCanMoveWindow == false` 的 NSView：`NSHostingView` 自己重写了
///    `hitTest`，命中的永远是外层 hosting view，垫片根本轮不上；
/// ② 只让这个 Host 说 false：SwiftUI 的 `ScrollView` 在里面铺了一整套真 NSScrollView
///    （HostingScrollView → HostingClipView → DocumentView → PlatformGroupContainer），
///    命中的是最深的那个，它照样说 true。
///
/// 所以改成鼠标进入这块区域时直接把窗口标成"不可拖"，离开再还回去。
private struct NonWindowDragging<Content: View>: View {
    /// 纯事件层：一个**不承载任何 SwiftUI 内容**的透明 NSView，铺在内容背后。
    ///
    /// 早先这里是 `NSHostingView<Content>`（内容嵌在里面）。那样做会崩：
    /// 嵌套的 hosting view 被父布局改尺寸时，它在 `setFrameSize` 里发起
    /// KVO → `setNeedsUpdateConstraints`，而此刻 AppKit 正在跑布局，
    /// 于是 `_postWindowNeedsUpdateConstraints` 抛异常直接 abort——
    /// 第三列展开、放大、全屏都会改它的尺寸，所以必崩。
    ///
    /// 现在它只做鼠标追踪，不参与布局、不持有内容，也就不可能触发约束更新。
    private struct TrackingLayer: NSViewRepresentable {
        func makeNSView(context: Context) -> NSView { Tracker() }
        func updateNSView(_ nsView: NSView, context: Context) {}
        static func dismantleNSView(_ nsView: NSView, coordinator: ()) {
            nsView.window?.isMovable = true
        }
    }

    private final class Tracker: NSView {
        private var hoverTracking: NSTrackingArea?

        override var mouseDownCanMoveWindow: Bool { false }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            if let hoverTracking { removeTrackingArea(hoverTracking) }
            let area = NSTrackingArea(
                rect: .zero,
                options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                owner: self
            )
            addTrackingArea(area)
            hoverTracking = area
        }

        override func mouseEntered(with event: NSEvent) {
            super.mouseEntered(with: event)
            window?.isMovable = false
        }

        override func mouseExited(with event: NSEvent) {
            super.mouseExited(with: event)
            window?.isMovable = true
        }

        override func viewWillMove(toWindow newWindow: NSWindow?) {
            // 视图被摘走时一定要还回去，否则留下一扇怎么都拖不动的窗口。
            window?.isMovable = true
            super.viewWillMove(toWindow: newWindow)
        }
    }

    let content: Content

    var body: some View {
        // 追踪层铺在背景，内容照常由 SwiftUI 自己布局——不再套进 hosting view。
        content.background(TrackingLayer())
    }
}

enum ToolHeaderLayoutPolicy {
    /// 第三列列头的纵向对齐。三列共用一条中线：侧栏和中间列都是往上提
    /// （`-16` / `-6`，各自对齐红绿灯），这一列原来反而往下推 `Spacing.xs`，
    /// 于是标签条明显低于左边两列。窗口态改成与中间列同一口径的上提量。
    static func topInset(isFullScreen: Bool) -> CGFloat {
        isFullScreen ? 0 : -6
    }
}

/// 标签条上的一格。工具标签（来源、证据、预览…）和网页标签在同一条上，
/// 所以它们是同一种东西——「来源」不是别的什么面板，就是一个普通标签。
enum TabStripItem: Hashable, Identifiable, Sendable {
    case tool(ToolKind)
    case web(UUID)

    var id: String {
        switch self {
        case .tool(let kind): "tool:\(kind.rawValue)"
        case .web(let identifier): "web:\(identifier.uuidString)"
        }
    }
}

enum TabStripOrder {
    /// 记住的顺序说了算，但只认还活着的标签；新开的补在后面。
    ///
    /// 顺序单独存一份而不是直接排两个数组：跨类型拖动（把网页标签拖到「来源」前面）
    /// 只有一条统一的顺序才表达得出来。
    static func items(tools: [ToolKind], web: [UUID], remembered: [String]) -> [TabStripItem] {
        let live = tools.map(TabStripItem.tool) + web.map(TabStripItem.web)
        let byID = Dictionary(live.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var seen: Set<String> = []
        var result = remembered.compactMap { id -> TabStripItem? in
            guard let item = byID[id], seen.insert(id).inserted else { return nil }
            return item
        }
        for item in live where seen.insert(item.id).inserted {
            result.append(item)
        }
        return result
    }

    static func moved(_ items: [TabStripItem], dragging: TabStripItem, to index: Int) -> [TabStripItem] {
        guard let source = items.firstIndex(of: dragging) else { return items }
        var result = items
        let moved = result.remove(at: source)
        result.insert(moved, at: min(max(index, 0), result.count))
        return result
    }

    /// 关掉当前标签之后该落到哪一张：先看右边，右边没有再看左边。
    /// 和浏览器一致，也不区分工具标签和网页标签——它们在这条上就是同一种东西。
    static func neighbour(of item: TabStripItem, in items: [TabStripItem]) -> TabStripItem? {
        guard let index = items.firstIndex(of: item) else { return nil }
        if index + 1 < items.count { return items[index + 1] }
        if index > 0 { return items[index - 1] }
        return nil
    }

    /// 指针落在第几格。用指针的绝对位置而不是位移量：
    /// 拖动过程中标签条自己也会滚动，只看位移会算到别的格子上去。
    static func index(
        forPointer x: CGFloat,
        contentOrigin: CGFloat,
        tabWidth: CGFloat,
        count: Int
    ) -> Int {
        guard count > 0, tabWidth > 0 else { return 0 }
        let stride = tabWidth + BrowserTabStripSizingPolicy.spacing
        let slot = Int(((x - contentOrigin) / stride).rounded(.down))
        return min(max(slot, 0), count - 1)
    }
}

enum BrowserTabStripSizingPolicy {
    static let spacing: CGFloat = 4
    /// 收缩下限。再窄标题就只剩两个字，和图标挤成一团。
    static let minimumWidth: CGFloat = 104

    static func maximumWidth(isFocused: Bool) -> CGFloat { isFocused ? 220 : 176 }

    /// 标签多了先一起变窄，窄到下限还放不下才开始滚动——和浏览器一个规矩。
    static func tabWidth(available: CGFloat, count: Int, isFocused: Bool) -> CGFloat {
        let maximum = maximumWidth(isFocused: isFocused)
        guard count > 1 else { return maximum }
        let fair = (available - spacing * CGFloat(count - 1)) / CGFloat(count)
        return min(maximum, max(minimumWidth, fair))
    }

    static func contentWidth(count: Int, tabWidth: CGFloat) -> CGFloat {
        guard count > 0 else { return 0 }
        return CGFloat(count) * tabWidth + CGFloat(count - 1) * spacing
    }

    static func availableWidth(headerWidth: CGFloat, showsFocusedChrome: Bool) -> CGFloat {
        let focusedChromeWidth: CGFloat = showsFocusedChrome ? 150 : 0
        let fixedControlsWidth: CGFloat = 32 + 64 + 5 * AppDesign.Spacing.xs
        return max(minimumWidth, headerWidth - focusedChromeWidth - fixedControlsWidth)
    }

    /// 标签条实际占的宽度。撑不满就按内容走，`+` 会跟着标签右移；
    /// 撑满了就停在可用宽度上，右侧窗口按钮不会被顶掉。
    static func stripWidth(
        headerWidth: CGFloat,
        count: Int,
        isFocused: Bool,
        showsFocusedChrome: Bool
    ) -> CGFloat {
        guard count > 0 else { return 0 }
        let available = availableWidth(headerWidth: headerWidth, showsFocusedChrome: showsFocusedChrome)
        let width = tabWidth(available: available, count: count, isFocused: isFocused)
        return min(contentWidth(count: count, tabWidth: width), available)
    }

    static func width(
        headerWidth: CGFloat,
        nonBrowserTabCount: Int,
        browserTabCount: Int,
        isFocused: Bool
    ) -> CGFloat {
        stripWidth(
            headerWidth: headerWidth,
            count: nonBrowserTabCount + browserTabCount,
            isFocused: isFocused,
            showsFocusedChrome: isFocused
        )
    }
}

/// 浏览器会话：每个标签持有自己的 WKWebView，并在分栏 / 占满视图之间移动当前标签。
///
/// 第三列现在只有一棵视图树（`PrimaryWorkspaceView.inspector`），放大只改宽度，
/// SwiftUI 切换时会把 `NSViewRepresentable` 整个拆掉重建。若 WKWebView 由视图持有，
/// 切到全屏就等于换了一个空白 webView——页面直接消失。这里把它提到视图之外，
/// 视图重建时只是把同一个 NSView 换个父视图。
struct BrowserTabSnapshot: Identifiable, Equatable {
    let id: UUID
    let title: String
    let address: String
    let isActive: Bool
    let isLoading: Bool
}

@MainActor
final class BrowserSession: ObservableObject {
    static let shared = BrowserSession()

    @Published private(set) var tabs: [BrowserTabSnapshot] = []
    @Published private(set) var canGoBack = false
    @Published private(set) var canGoForward = false
    @Published private(set) var currentAddress = ""
    @Published private(set) var pageTitle = ""
    @Published private(set) var isLoading = false
    @Published private(set) var loadError: String?
    @Published private(set) var hasActivePage = false
    @Published private(set) var history: [BrowserHistoryEntry] = []
    @Published private(set) var downloadStatus: String?

    @MainActor
    private final class Tab {
        let id: UUID
        let webView: WKWebView
        let navigationDelegate: NavigationDelegate
        var lastRequestedURL: URL?
        var pendingRestoreURL: URL?
        var persistedTitle = ""
        var isLoading = false
        var loadError: String?
        var observations: [NSKeyValueObservation] = []

        init(configuration: WKWebViewConfiguration) {
            let id = UUID()
            self.id = id
            navigationDelegate = NavigationDelegate(tabID: id)
            webView = WKWebView(frame: .zero, configuration: configuration)
        }
    }

    private var tabStorage: [Tab] = []
    private var activeTabID = UUID()
    private var activeOwner: UUID?
    private var activeHostGeneration: UInt64 = 0
    private var nextHostGeneration: UInt64 = 0
    private weak var activeContainer: NSView?
    private var browserConstraints: [NSLayoutConstraint] = []
    private let popupBridge = WebViewPopupBridge()
    private let preferences = UserDefaults.standard
    private var historyStore = BrowserHistoryStore()

    private enum Persistence {
        static let key = "browser.session.v1"
        static let historyKey = "browser.history.v1"
        static let maximumTabs = 12
    }

    private struct StoredSession: Codable {
        let activeIndex: Int
        let tabs: [StoredTab]
    }

    private struct StoredTab: Codable {
        let url: String
        let title: String
    }

    private var activeTab: Tab {
        tabStorage.first { $0.id == activeTabID } ?? tabStorage[0]
    }

    private init() {
        historyStore = Self.restoreHistory(from: preferences)
        history = historyStore.entries
        let restored = BrowserPreferences.shared.restoresSession ? Self.restoreSession(from: preferences) : nil
        if let restored, !restored.tabs.isEmpty {
            tabStorage = restored.tabs.map { stored in
                let tab = makeTab()
                tab.pendingRestoreURL = URL(string: stored.url)
                tab.persistedTitle = stored.title
                return tab
            }
            let index = min(max(0, restored.activeIndex), tabStorage.count - 1)
            activeTabID = tabStorage[index].id
        } else {
            let initial = makeTab()
            tabStorage = [initial]
            activeTabID = initial.id
        }

        popupBridge.createWebViewHandler = { [weak self] configuration, action, _ in
            self?.openPopupTab(configuration: configuration, requestedURL: action.request.url)
        }
        popupBridge.closeWebViewHandler = { [weak self] webView in
            guard let self,
                  let tab = self.tabStorage.first(where: { $0.webView === webView })
            else { return false }
            self.closeTab(tab.id)
            return true
        }
        // 会话是单例、活得比第三列久，所以由它自己听「收起」广播。
        // 挂在那一列的视图上不行：收起时它和回调一起没了。
        NotificationCenter.default.addObserver(
            forName: .suspendToolMedia,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.suspendMedia() }
        }
        // 这里**不**恢复上次的页面。启动时第三列多半还没打开，提前导航等于
        // 让上次那个 B 站视频在看不见的地方就开始加载甚至出声。
        // 真正的恢复推迟到 `activateIfNeeded()`——第三列首次真的要显示时。
        publishState()
    }

    func open(_ url: URL, inNewTab: Bool = true) {
        // 同一个链接反复点，应该回到它已经开着的那个标签，而不是一直堆新标签。
        // 浏览器里点站内链接会走 `navigate`，不经过这里，所以这条只影响
        // 「从对话/来源列表打开外部链接」这类入口——正是重复开标签的来源。
        if let existing = tabStorage.first(where: { BrowserSession.sameDocument($0.webView.url ?? $0.lastRequestedURL ?? $0.pendingRestoreURL, url) }) {
            activate(existing)
            return
        }
        let activeTabHasPage = hasPage(activeTab)
        guard inNewTab,
              !BrowserTabOpeningPolicy.shouldReuseActiveTab(
                  requestedNewTab: inNewTab,
                  activeTabHasPage: activeTabHasPage
              )
        else {
            navigate(to: url)
            return
        }
        makeRoomForNewTab()
        let tab = makeTab()
        tabStorage.append(tab)
        activate(tab)
        navigate(tab, to: url)
    }

    /// 两个地址是不是"同一篇文档"。用于「同一个链接点第二次要回到原标签」。
    /// 忽略 scheme、末尾斜杠、`www.` 前缀和 fragment；查询串保留
    /// （B 站的 `?p=2` 是不同分 P，力扣的 `?envType=` 也可能是不同入口）。
    nonisolated static func sameDocument(_ lhs: URL?, _ rhs: URL?) -> Bool {
        guard let lhs, let rhs else { return false }
        func key(_ url: URL) -> String? {
            guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
            components.fragment = nil
            guard let host = components.host?.lowercased() else { return nil }
            let path = components.path.hasSuffix("/") ? String(components.path.dropLast()) : components.path
            let query = components.query.map { "?\($0)" } ?? ""
            return host.hasPrefix("www.") ? "\(host.dropFirst(4))\(path)\(query)" : "\(host)\(path)\(query)"
        }
        guard let left = key(lhs), let right = key(rhs) else { return false }
        return left == right
    }

    private func hasPage(_ tab: Tab) -> Bool {
        tab.lastRequestedURL != nil || tab.pendingRestoreURL != nil || tab.webView.url != nil
    }

    func navigate(to url: URL) {
        navigate(activeTab, to: url)
    }

    private func navigate(_ tab: Tab, to url: URL) {
        guard BrowserAddressPolicy.shouldNavigate(
            requested: url,
            pending: tab.lastRequestedURL,
            isLoading: tab.isLoading
        ) else { return }
        if ProcessInfo.processInfo.environment["LEETCODE_BROWSER_DEBUG"] != nil {
            NSLog("[browser] navigate tab=\(tab.id) \(url.absoluteString)")
        }
        tab.lastRequestedURL = url
        tab.pendingRestoreURL = nil
        tab.isLoading = true
        tab.loadError = nil
        publishState()
        BrowserMediaLifecycle.navigate(tab.webView, to: url)
        persistSession()
    }

    func openBlankTab() {
        makeRoomForNewTab()
        let tab = makeTab()
        tabStorage.append(tab)
        activate(tab)
    }

    func selectTab(_ id: UUID) {
        guard let tab = tabStorage.first(where: { $0.id == id }), tab.id != activeTabID else { return }
        activate(tab)
    }

    func moveTab(_ id: UUID, over targetID: UUID) {
        let currentOrder = tabStorage.map(\.id)
        let reordered = BrowserTabOrderPolicy.reordered(
            currentOrder,
            dragging: id,
            over: targetID
        )
        guard reordered != currentOrder else { return }

        let tabsByID = Dictionary(uniqueKeysWithValues: tabStorage.map { ($0.id, $0) })
        tabStorage = reordered.compactMap { tabsByID[$0] }
        publishState()
    }

    func moveTab(_ id: UUID, toIndex: Int) {
        let currentOrder = tabStorage.map(\.id)
        let reordered = BrowserTabOrderPolicy.moved(
            currentOrder,
            dragging: id,
            toIndex: toIndex
        )
        guard reordered != currentOrder else { return }

        let tabsByID = Dictionary(uniqueKeysWithValues: tabStorage.map { ($0.id, $0) })
        tabStorage = reordered.compactMap { tabsByID[$0] }
        publishState()
    }

    /// 标签条拖完之后一次性落位。少一个、多一个都当作数据已经变了，直接忽略这次排序。
    func reorderTabs(_ ids: [UUID]) {
        let current = tabStorage.map(\.id)
        guard ids != current, Set(ids) == Set(current) else { return }
        let tabsByID = Dictionary(uniqueKeysWithValues: tabStorage.map { ($0.id, $0) })
        tabStorage = ids.compactMap { tabsByID[$0] }
        publishState()
        persistSession()
    }

    func commitTabOrder() {
        persistSession()
    }

    func closeTab(_ id: UUID) {
        guard let index = tabStorage.firstIndex(where: { $0.id == id }) else { return }
        let closing = tabStorage[index]
        let wasActive = closing.id == activeTabID

        if tabStorage.count == 1 {
            let replacement = makeTab()
            tabStorage = [replacement]
            activeTabID = replacement.id
        } else {
            tabStorage.remove(at: index)
            if wasActive {
                activeTabID = tabStorage[min(index, tabStorage.count - 1)].id
            }
        }

        if wasActive, closing.webView.superview != nil {
            NSLayoutConstraint.deactivate(browserConstraints)
            browserConstraints.removeAll(keepingCapacity: true)
            closing.webView.removeFromSuperview()
        }
        BrowserMediaLifecycle.pauseAndRelease(closing.webView)

        if wasActive, let container = activeContainer, container.window != nil {
            attach(to: container)
        }
        publishState()
        persistSession()
    }

    /// 分栏与占满切换时两棵 SwiftUI 视图会短暂共存。只有已进入窗口的容器
    /// 才能认领当前标签，旧容器后续的 update 不能再把它抢回去。
    func registerHost() -> UInt64 {
        nextHostGeneration &+= 1
        return nextHostGeneration
    }

    func claim(container: NSView, owner: UUID, generation: UInt64) {
        guard container.window != nil,
              BrowserHostClaimPolicy.accepts(
                candidateGeneration: generation,
                activeGeneration: activeHostGeneration
              )
        else { return }
        activeHostGeneration = generation
        activeOwner = owner
        activeContainer = container
        attach(to: container)
    }

    func release(owner: UUID) {
        guard activeOwner == owner else { return }
        activeOwner = nil
        activeContainer = nil
        NSLayoutConstraint.deactivate(browserConstraints)
        browserConstraints.removeAll(keepingCapacity: true)
        // 这里只做"松开所有权"，视图留在原处：下一次 `claim`/`attach` 会把
        // webview 挂到新容器上（`attach` 已处理换容器与约束）。视图短暂留在
        // 旧容器上是无害的——旧容器紧接着就会被移除。
        //
        // 不要在这里 `removeFromSuperview`：放大/还原只是换容器，下一拍就会挂回来，
        // 中途摘掉会让画面白一下；播放中摘还会让 WebKit 的合成层失效。
    }

    /// 第三列首次真正可见时才把上次的页面加载回来。
    /// 幂等：之后每次显示都会调，但 `pendingRestoreURL` 只在第一次有值。
    func activateIfNeeded() {
        restoreIfNeeded(activeTab)
    }

    func suspendMedia() {
        for tab in tabStorage {
            // `pauseAllMediaPlayback` 只管主 frame。B 站把播放器放在 <iframe> 里，
            // 只调它的话面板收起后声音照旧——所以再往所有子 frame 里下一道暂停。
            tab.webView.pauseAllMediaPlayback(completionHandler: nil)
            tab.webView.evaluateJavaScript(
                BrowserMediaLifecycle.pauseInAllFramesScript,
                in: nil,
                in: .page
            ) { _ in }
        }
    }

    func goBack() { activeTab.webView.goBack() }
    func goForward() { activeTab.webView.goForward() }
    func reload() { activeTab.webView.reload() }

    func setRestoresSession(_ enabled: Bool) {
        if enabled {
            persistSession()
        } else {
            preferences.removeObject(forKey: Persistence.key)
        }
    }

    func removeHistoryEntry(_ id: UUID) {
        historyStore.remove(id: id)
        persistHistory()
    }

    func clearHistory() {
        historyStore.removeAll()
        persistHistory()
    }

    func clearBrowsingData() async {
        let store = WKWebsiteDataStore.default()
        await withCheckedContinuation { continuation in
            store.removeData(
                ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(),
                modifiedSince: .distantPast
            ) {
                continuation.resume()
            }
        }
        for tab in tabStorage {
            tab.webView.stopLoading()
            BrowserMediaLifecycle.pauseAndRelease(tab.webView)
            tab.webView.removeFromSuperview()
        }
        let initial = makeTab()
        tabStorage = [initial]
        activeTabID = initial.id
        clearHistory()
        preferences.removeObject(forKey: Persistence.key)
        publishState()
        if let container = activeContainer, container.window != nil {
            attach(to: container)
        }
    }

    private func makeTab(configuration suppliedConfiguration: WKWebViewConfiguration? = nil) -> Tab {
        let configuration = suppliedConfiguration ?? {
            let value = WKWebViewConfiguration()
            value.websiteDataStore = .default()
            return value
        }()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        // 页面一律不许自己开始播放，必须用户点过才行。
        // 两个原因：一是恢复上次会话时那个 B 站视频会在看不见的地方就出声；
        // 二是"播放中"正是布局变化把 WebKit 合成层弄崩的前提，能不播就少一类崩溃。
        configuration.mediaTypesRequiringUserActionForPlayback = .all

        let tab = Tab(configuration: configuration)
        // WKWebView 默认 UA 没有 Safari 产品标识，百度会把它当成受限内嵌页。
        tab.webView.customUserAgent = BrowserAddressPolicy.desktopSafariUserAgent
        tab.webView.allowsMagnification = true
        tab.webView.allowsBackForwardNavigationGestures = true
        tab.webView.navigationDelegate = tab.navigationDelegate
        tab.webView.uiDelegate = popupBridge
        tab.navigationDelegate.session = self
        let tabID = tab.id
        tab.observations = [
            tab.webView.observe(\.title, options: [.new]) { [weak self, weak webView = tab.webView] _, _ in
                guard let webView else { return }
                Task { @MainActor [weak self] in self?.syncNavigationState(tabID: tabID, webView: webView) }
            },
            tab.webView.observe(\.url, options: [.new]) { [weak self, weak webView = tab.webView] _, _ in
                guard let webView else { return }
                Task { @MainActor [weak self] in self?.syncNavigationState(tabID: tabID, webView: webView) }
            },
            tab.webView.observe(\.canGoBack, options: [.new]) { [weak self, weak webView = tab.webView] _, _ in
                guard let webView else { return }
                Task { @MainActor [weak self] in self?.syncNavigationState(tabID: tabID, webView: webView) }
            },
            tab.webView.observe(\.canGoForward, options: [.new]) { [weak self, weak webView = tab.webView] _, _ in
                guard let webView else { return }
                Task { @MainActor [weak self] in self?.syncNavigationState(tabID: tabID, webView: webView) }
            }
        ]
        return tab
    }

    private func openPopupTab(
        configuration: WKWebViewConfiguration,
        requestedURL: URL?
    ) -> WKWebView {
        makeRoomForNewTab()
        let tab = makeTab(configuration: configuration)
        tab.lastRequestedURL = requestedURL
        tab.isLoading = true
        tabStorage.append(tab)
        activate(tab)
        return tab.webView
    }

    private func makeRoomForNewTab() {
        guard tabStorage.count >= Persistence.maximumTabs else { return }
        let candidate = tabStorage.first { $0.id != activeTabID } ?? tabStorage[0]
        closeTab(candidate.id)
    }

    private func activate(_ tab: Tab) {
        guard tabStorage.contains(where: { $0.id == tab.id }) else { return }
        if activeTabID != tab.id {
            activeTab.webView.pauseAllMediaPlayback(completionHandler: nil)
        }
        activeTabID = tab.id
        restoreIfNeeded(tab)
        if let container = activeContainer, container.window != nil {
            attach(to: container)
        }
        publishState()
        persistSession()
    }

    private func attach(to container: NSView) {
        let webView = activeTab.webView
        // 一个容器只能显示一个标签。旧实现把非活动 WKWebView 留在容器内，
        // 切回时又因 `superview === container` 提前返回，导致地址和选中态已切回、
        // 画面仍被后一个标签盖住。
        for tab in tabStorage where tab.webView !== webView && tab.webView.superview === container {
            tab.webView.removeFromSuperview()
        }
        if webView.superview === container {
            container.addSubview(webView, positioned: .above, relativeTo: nil)
            return
        }
        if ProcessInfo.processInfo.environment["LEETCODE_BROWSER_DEBUG"] != nil {
            NSLog("[browser] reparent tab=\(activeTab.id) container=\(ObjectIdentifier(container))")
        }
        NSLayoutConstraint.deactivate(browserConstraints)
        browserConstraints.removeAll(keepingCapacity: true)
        webView.removeFromSuperview()
        webView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(webView)
        browserConstraints = [
            webView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            webView.topAnchor.constraint(equalTo: container.topAnchor),
            webView.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ]
        NSLayoutConstraint.activate(browserConstraints)
    }

    private func publishState() {
        let active = activeTab
        let address = displayAddress(for: active)
        let title = active.webView.title ?? active.persistedTitle
        let snapshots = tabStorage.map { tab in
            let tabAddress = displayAddress(for: tab)
            let fallback = tabAddress.isEmpty ? "新标签页" : (URL(string: tabAddress)?.host ?? "新标签页")
            let liveTitle = tab.webView.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return BrowserTabSnapshot(
                id: tab.id,
                title: liveTitle.isEmpty ? (tab.persistedTitle.isEmpty ? fallback : tab.persistedTitle) : liveTitle,
                address: tabAddress,
                isActive: tab.id == activeTabID,
                isLoading: tab.isLoading
            )
        }

        if tabs != snapshots { tabs = snapshots }
        if canGoBack != active.webView.canGoBack { canGoBack = active.webView.canGoBack }
        if canGoForward != active.webView.canGoForward { canGoForward = active.webView.canGoForward }
        if currentAddress != address { currentAddress = address }
        if pageTitle != title { pageTitle = title }
        if isLoading != active.isLoading { isLoading = active.isLoading }
        if loadError != active.loadError { loadError = active.loadError }
        let activeHasPage = hasPage(active)
        if hasActivePage != activeHasPage { hasActivePage = activeHasPage }
    }

    private func navigationStarted(tabID: UUID, webView: WKWebView) {
        guard let tab = tabStorage.first(where: { $0.id == tabID }) else { return }
        tab.isLoading = true
        tab.loadError = nil
        syncNavigationState(tabID: tabID, webView: webView)
    }

    private func navigationFinished(tabID: UUID, webView: WKWebView) {
        guard let tab = tabStorage.first(where: { $0.id == tabID }) else { return }
        tab.isLoading = false
        tab.loadError = nil
        tab.persistedTitle = webView.title ?? tab.persistedTitle
        if let url = webView.url, ["http", "https"].contains(url.scheme?.lowercased() ?? "") {
            historyStore.record(url: url, title: tab.persistedTitle)
            persistHistory()
        }
        syncNavigationState(tabID: tabID, webView: webView)
        persistSession()
    }

    private func restoreIfNeeded(_ tab: Tab) {
        guard let url = tab.pendingRestoreURL else { return }
        tab.pendingRestoreURL = nil
        tab.lastRequestedURL = url
        tab.isLoading = true
        BrowserMediaLifecycle.navigate(tab.webView, to: url)
    }

    private func displayAddress(for tab: Tab) -> String {
        tab.webView.url?.absoluteString
            ?? tab.lastRequestedURL?.absoluteString
            ?? tab.pendingRestoreURL?.absoluteString
            ?? ""
    }

    private func persistSession() {
        guard BrowserPreferences.shared.restoresSession else {
            preferences.removeObject(forKey: Persistence.key)
            return
        }
        let storedTabs = tabStorage.prefix(Persistence.maximumTabs).compactMap { tab -> StoredTab? in
            let address = displayAddress(for: tab)
            guard BrowserAddressPolicy.normalize(address) != nil else { return nil }
            let title = tab.webView.title?.trimmingCharacters(in: .whitespacesAndNewlines)
            return StoredTab(url: address, title: title?.isEmpty == false ? title! : tab.persistedTitle)
        }
        guard !storedTabs.isEmpty else {
            preferences.removeObject(forKey: Persistence.key)
            return
        }
        let activeAddress = displayAddress(for: activeTab)
        let activeIndex = storedTabs.firstIndex(where: { $0.url == activeAddress }) ?? 0
        guard let data = try? JSONEncoder().encode(StoredSession(activeIndex: activeIndex, tabs: storedTabs)) else { return }
        preferences.set(data, forKey: Persistence.key)
    }

    private static func restoreSession(from preferences: UserDefaults) -> StoredSession? {
        guard let data = preferences.data(forKey: Persistence.key),
              let value = try? JSONDecoder().decode(StoredSession.self, from: data)
        else { return nil }
        let tabs = value.tabs.prefix(Persistence.maximumTabs).filter {
            BrowserAddressPolicy.normalize($0.url) != nil
        }
        guard !tabs.isEmpty else { return nil }
        return StoredSession(activeIndex: value.activeIndex, tabs: Array(tabs))
    }

    private func persistHistory() {
        history = historyStore.entries
        guard !history.isEmpty else {
            preferences.removeObject(forKey: Persistence.historyKey)
            return
        }
        if let data = try? JSONEncoder().encode(history) {
            preferences.set(data, forKey: Persistence.historyKey)
        }
    }

    private static func restoreHistory(from preferences: UserDefaults) -> BrowserHistoryStore {
        guard let data = preferences.data(forKey: Persistence.historyKey),
              let entries = try? JSONDecoder().decode([BrowserHistoryEntry].self, from: data)
        else { return BrowserHistoryStore() }
        return BrowserHistoryStore(entries: entries)
    }

    fileprivate func downloadDestination(suggestedFilename: String) -> URL? {
        let fallback = suggestedFilename.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "下载文件"
            : suggestedFilename
        if BrowserPreferences.shared.asksWhereToSaveDownloads {
            let panel = NSSavePanel()
            panel.nameFieldStringValue = fallback
            panel.directoryURL = BrowserPreferences.shared.downloadDirectory
            panel.canCreateDirectories = true
            guard panel.runModal() == .OK else { return nil }
            return panel.url
        }

        let directory = BrowserPreferences.shared.downloadDirectory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let candidate = directory.appending(path: fallback)
        guard FileManager.default.fileExists(atPath: candidate.path) else { return candidate }
        let extensionName = candidate.pathExtension
        let stem = candidate.deletingPathExtension().lastPathComponent
        for suffix in 2...999 {
            let name = extensionName.isEmpty ? "\(stem) \(suffix)" : "\(stem) \(suffix).\(extensionName)"
            let alternate = directory.appending(path: name)
            if !FileManager.default.fileExists(atPath: alternate.path) { return alternate }
        }
        return nil
    }

    fileprivate func reportDownloadFinished(at url: URL?) {
        downloadStatus = url.map { "已下载到 \($0.lastPathComponent)" } ?? "下载已完成"
    }

    fileprivate func reportDownloadFailure(_ error: Error) {
        downloadStatus = "下载失败：\(error.localizedDescription)"
    }

    private func syncNavigationState(tabID: UUID, webView: WKWebView) {
        guard tabStorage.contains(where: { $0.id == tabID }) else { return }
        publishState()
    }

    private func recordNavigationFailure(tabID: UUID, webView: WKWebView, error: Error) {
        guard let tab = tabStorage.first(where: { $0.id == tabID }) else { return }
        tab.isLoading = false
        let nsError = error as NSError
        if nsError.domain != NSURLErrorDomain || nsError.code != NSURLErrorCancelled {
            tab.loadError = error.localizedDescription
        }
        syncNavigationState(tabID: tabID, webView: webView)
    }

    fileprivate final class NavigationDelegate: NSObject, WKNavigationDelegate, WKDownloadDelegate {
        weak var session: BrowserSession?
        private let tabID: UUID
        private let debug = ProcessInfo.processInfo.environment["LEETCODE_BROWSER_DEBUG"] != nil
        private var recent: [String: (count: Int, windowStart: Date)] = [:]
        private var downloadDestinations: [ObjectIdentifier: URL] = [:]

        init(tabID: UUID) {
            self.tabID = tabID
        }

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void
        ) {
            let key = navigationAction.request.url?.absoluteString ?? ""
            if navigationAction.shouldPerformDownload {
                decisionHandler(.download)
                return
            }
            if BrowserAddressPolicy.shouldBlockInsecureDowngrade(
                requested: navigationAction.request.url,
                current: webView.url,
                isMainFrame: navigationAction.targetFrame?.isMainFrame == true
            ) {
                if debug { NSLog("[browser] downgrade-block tab=\(tabID) \(key)") }
                decisionHandler(.cancel)
                return
            }
            let now = Date()
            var entry = recent[key] ?? (0, now)
            if now.timeIntervalSince(entry.windowStart) > 3 { entry = (0, now) }
            entry.count += 1
            recent[key] = entry
            if recent.count > 64 {
                recent = recent.filter { now.timeIntervalSince($0.value.windowStart) <= 3 }
            }
            if entry.count > 6, navigationAction.navigationType != .linkActivated {
                NSLog("[browser] loop-break tab=\(tabID) \(key)")
                decisionHandler(.cancel)
                return
            }
            if debug { NSLog("[browser] policy tab=\(tabID) type=\(navigationAction.navigationType.rawValue) \(key)") }
            decisionHandler(.allow)
        }

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationResponse: WKNavigationResponse,
            decisionHandler: @escaping @MainActor (WKNavigationResponsePolicy) -> Void
        ) {
            decisionHandler(navigationResponse.canShowMIMEType ? .allow : .download)
        }

        func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
            download.delegate = self
        }

        func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
            download.delegate = self
        }

        func download(
            _ download: WKDownload,
            decideDestinationUsing response: URLResponse,
            suggestedFilename: String,
            completionHandler: @escaping @MainActor (URL?) -> Void
        ) {
            let destination = session?.downloadDestination(suggestedFilename: suggestedFilename)
            if let destination { downloadDestinations[ObjectIdentifier(download)] = destination }
            completionHandler(destination)
        }

        func downloadDidFinish(_ download: WKDownload) {
            let destination = downloadDestinations.removeValue(forKey: ObjectIdentifier(download))
            session?.reportDownloadFinished(at: destination)
        }

        func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
            downloadDestinations.removeValue(forKey: ObjectIdentifier(download))
            session?.reportDownloadFailure(error)
        }

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation?) {
            if debug { NSLog("[browser] start tab=\(tabID) \(webView.url?.absoluteString ?? "nil")") }
            session?.navigationStarted(tabID: tabID, webView: webView)
        }

        func webView(_ webView: WKWebView, didCommit navigation: WKNavigation?) {
            session?.syncNavigationState(tabID: tabID, webView: webView)
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation?) {
            if debug { NSLog("[browser] finish tab=\(tabID) \(webView.url?.absoluteString ?? "nil")") }
            session?.navigationFinished(tabID: tabID, webView: webView)
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation?, withError error: Error) {
            NSLog("[browser] fail tab=\(tabID) \(error.localizedDescription)")
            session?.recordNavigationFailure(tabID: tabID, webView: webView, error: error)
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation?, withError error: Error) {
            NSLog("[browser] failProvisional tab=\(tabID) \(error.localizedDescription)")
            session?.recordNavigationFailure(tabID: tabID, webView: webView, error: error)
        }

        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            let error = NSError(
                domain: "LeetCodeAssistant.Browser",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "网页进程已退出，请重新加载"]
            )
            session?.recordNavigationFailure(tabID: tabID, webView: webView, error: error)
        }
    }
}

/// 只负责把当前标签的 webView 挂进 SwiftUI 布局，本身不持有页面状态。
private struct BrowserWebView: NSViewRepresentable {
    let session: BrowserSession

    func makeCoordinator() -> Coordinator {
        Coordinator(generation: session.registerHost())
    }

    func makeNSView(context: Context) -> BrowserContainerView {
        let container = BrowserContainerView()
        container.session = session
        container.owner = context.coordinator.owner
        container.generation = context.coordinator.generation
        return container
    }

    func updateNSView(_ container: BrowserContainerView, context: Context) {
        container.session = session
        container.owner = context.coordinator.owner
        container.generation = context.coordinator.generation
        session.claim(
            container: container,
            owner: context.coordinator.owner,
            generation: context.coordinator.generation
        )
    }

    static func dismantleNSView(_ container: BrowserContainerView, coordinator: Coordinator) {
        container.session?.release(owner: coordinator.owner)
        container.session = nil
    }

    final class Coordinator {
        let owner = UUID()
        let generation: UInt64

        init(generation: UInt64) {
            self.generation = generation
        }
    }
}

@MainActor
private final class BrowserContainerView: NSView {
    weak var session: BrowserSession?
    var owner = UUID()
    var generation: UInt64 = 0

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let session else { return }
        if window == nil {
            session.release(owner: owner)
        } else {
            session.claim(container: self, owner: owner, generation: generation)
        }
    }
}

@MainActor
enum BrowserMediaLifecycle {
    /// 暂停当前页 **和所有同源子 frame** 里的音视频。
    /// 跨源 iframe 读不到（会抛异常），逐个 try 掉即可——B 站主站的播放器是同源的。
    static let pauseInAllFramesScript = """
    (() => {
      const pause = doc => {
        try {
          doc.querySelectorAll('video,audio').forEach(media => {
            try { media.pause(); } catch (_) {}
          });
        } catch (_) {}
      };
      pause(document);
      for (const frame of Array.from(document.querySelectorAll('iframe'))) {
        try { if (frame.contentDocument) pause(frame.contentDocument); } catch (_) {}
      }
      return true;
    })()
    """

    static let shutdownScript = """
    (() => {
      document.querySelectorAll('video,audio').forEach(media => {
        try { media.pause(); } catch (_) {}
        media.removeAttribute('src');
        media.querySelectorAll('source').forEach(source => source.removeAttribute('src'));
        try { media.load(); } catch (_) {}
      });
      return true;
    })()
    """

    static func pauseAndRelease(_ webView: WKWebView) {
        webView.pauseAllMediaPlayback { [webView] in
            webView.evaluateJavaScript(shutdownScript) { [webView] _, _ in
                webView.stopLoading()
                webView.loadHTMLString("", baseURL: nil)
            }
        }
        webView.stopLoading()
    }

    static func navigate(_ webView: WKWebView, to url: URL) {
        // **不要把导航压在 evaluateJavaScript 的回调里**：那段脚本跑在**旧页面**上，
        // 重站点（百度这类）主线程忙的时候回调迟迟不来，整个跳转就跟着卡住，
        // 表现为点了地址半天没反应、然后突然刷出来。
        // 加载新地址本身就会拆掉旧文档，停媒体尽力而为即可，不该成为导航的前置条件。
        webView.pauseAllMediaPlayback(completionHandler: nil)
        webView.stopLoading()
        webView.load(URLRequest(url: url))
    }
}

private struct EmptyRuntimeToolView: View {
    let title: String
    let systemImage: String
    let description: String

    var body: some View {
        ContentUnavailableView(title, systemImage: systemImage, description: Text(description))
    }
}

private struct RuntimeArtifactToolView: View {
    let item: ContextItem?
    let emptyTitle: String
    let systemImage: String

    var body: some View {
        if let item {
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(item.title)
                        .font(AppDesign.Typography.rowTitle)
                        .lineLimit(2)
                    if !item.subtitle.isEmpty {
                        Text(item.subtitle)
                            .font(AppDesign.Typography.aux)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }
                .padding(AppDesign.Spacing.md)

                Divider()

                if let value = item.url, let url = URL(string: value) {
                    ArtifactWebPreview(url: url)
                } else {
                    Text(item.subtitle)
                        .font(AppDesign.Typography.body.monospaced())
                        .textSelection(.enabled)
                        .padding(AppDesign.Spacing.md)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }
            }
        } else {
            ContentUnavailableView(emptyTitle, systemImage: systemImage)
        }
    }
}

private struct ArtifactWebPreview: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.allowsMagnification = true
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        guard webView.url != url else { return }
        if url.isFileURL {
            webView.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        } else {
            webView.load(URLRequest(url: url))
        }
    }
}

private struct EvidenceToolView: View {
    @Bindable var workspace: WorkspaceState
    @Bindable var dataStore: LegacyDataStore

    private var record: LearningRecord? {
        if let id = workspace.selectedLearningRecordID,
           let selected = dataStore.learningRecords.first(where: { $0.id == id }) {
            return selected
        }
        return nil
    }

    var body: some View {
        if let record {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(record.title)
                            .font(AppDesign.Typography.rowTitle)
                        Text("\(record.evidenceCount) 条学习证据 · 掌握度 \(Int(record.masteryScore))%")
                            .font(AppDesign.Typography.aux)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.bottom, AppDesign.Spacing.md)

                    ForEach(record.evidence) { evidence in
                        HStack(alignment: .top, spacing: AppDesign.Spacing.sm) {
                            Circle()
                                .fill(evidenceColor(evidence.signal))
                                .frame(width: 6, height: 6)
                                .padding(.top, 6)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(evidence.summary)
                                    .font(AppDesign.Typography.body)
                                    .fixedSize(horizontal: false, vertical: true)
                                Text(evidence.observedAt, format: .dateTime.month().day().hour().minute())
                                    .font(AppDesign.Typography.aux)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                        }
                        .padding(.bottom, AppDesign.Spacing.md)
                    }
                }
                .padding(AppDesign.Spacing.md)
            }
            .floatingScrollIndicators()
        } else {
            ContentUnavailableView("暂无学习证据", systemImage: "doc.text.magnifyingglass")
        }
    }

    private func evidenceColor(_ signal: String) -> Color {
        switch signal {
        case "demonstrated", "mastered": AppDesign.ColorToken.success
        case "struggling", "error": AppDesign.ColorToken.warning
        default: .accentColor
        }
    }
}
