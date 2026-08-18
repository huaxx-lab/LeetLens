import AppKit
import SwiftUI

struct GlobalSidebarView: View {
    @Bindable var workspace: WorkspaceState
    @Bindable var dataStore: LegacyDataStore
    @Environment(\.colorScheme) private var colorScheme
    @State private var expandedGroups: Set<SidebarGroup> = [.learning, .conversations, .plans]
    @State private var pendingConversationDeletion: ConversationSummary?
    /// 账户行那个 `Menu` 必须拿到显式宽度，见 `accountMenu` 的注释。
    @State private var sidebarWidth = AppDesign.Size.sidebarIdeal

    var body: some View {
        // Codex 式侧栏：品牌行 → 新建会话 → 导航列表 → 账户行，全程零横线，
        // 分组只靠留白（主线 2 / G-T4）。
        VStack(spacing: 0) {
            columnHeader
            sidebarHeader
            newConversationButton
                .padding(.horizontal, AppDesign.Spacing.xs)
                .padding(.bottom, AppDesign.Spacing.xs)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    navigationRow(.leetCode)
                    navigationRow(.plan)
                    navigationRow(.review)

                    groupHeader(.learning, title: "学习中心", systemImage: "folder")
                    if expandedGroups.contains(.learning) {
                        navigationRow(.library, indented: true)
                        navigationRow(.knowledge, indented: true)
                        navigationRow(.insights, indented: true)
                        navigationRow(.templates, indented: true)
                    }

                    groupHeader(.conversations, title: "最近会话", systemImage: "clock")
                    if expandedGroups.contains(.conversations) {
                        ForEach(dataStore.conversations) { conversation in
                            conversationRow(conversation)
                        }
                    }

                    if !dataStore.leetCodePlans.isEmpty {
                        groupHeader(.plans, title: "力扣题单", systemImage: "list.bullet.rectangle")
                        if expandedGroups.contains(.plans) {
                            ForEach(dataStore.leetCodePlans) { plan in
                                planRow(plan)
                            }
                        }
                    }

                    navigationRow(.trash)
                        .padding(.top, AppDesign.Spacing.xxs)
                }
                .padding(.horizontal, AppDesign.Spacing.xs)
                .padding(.bottom, AppDesign.Spacing.compact)
            }
            .floatingScrollIndicators()

            accountMenu
                .padding(.horizontal, AppDesign.Spacing.xs)
                .padding(.top, AppDesign.Spacing.xs)
                .padding(.bottom, AppDesign.Spacing.xs)
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { sidebarWidth = $0 }
        .background(sidebarSurface.ignoresSafeArea())
        .confirmationDialog(
            "删除这个会话？",
            isPresented: Binding(
                get: { pendingConversationDeletion != nil },
                set: { if !$0 { pendingConversationDeletion = nil } }
            ),
            titleVisibility: .visible,
            presenting: pendingConversationDeletion
        ) { conversation in
            Button("删除“\(conversation.title)”", role: .destructive) {
                deleteConversation(conversation)
            }
            Button("取消", role: .cancel) { pendingConversationDeletion = nil }
        } message: { _ in
            Text("该操作会同时从原项目的会话记录中移除内容，且无法撤销。")
        }
    }

    /// 侧栏列头。它是最左一列，窗口态下红绿灯就浮在这一行左侧，
    /// 控件从 `headerLeadingInset` 之后开始排，两者同处一行（对齐 Codex）。
    private var columnHeader: some View {
        HStack(spacing: 0) {
            // 收起动画期间这一列还在（宽度渐变到 0），但详情列头的 ⧉ 已经出现了。
            // 不加这道判断就会同时看到两颗，其中一颗跟着变窄的侧栏往左滑。
            if workspace.isSidebarPresented {
                if workspace.isWindowFullScreen {
                    // 全屏没有红绿灯占位，⧉ 和前进后退并成一组顶到最左。
                    WorkspaceHistoryChrome(workspace: workspace)
                    Spacer(minLength: 0)
                } else {
                    // 窗口态保持原样：最左是红绿灯，这颗按钮靠右贴住列尾。
                    Spacer(minLength: 0)
                    sidebarIconButton("sidebar.left", help: "收起侧栏") {
                        workspace.toggleSidebar()
                    }
                }
            }
        }
        // 侧栏这一列天生比详情列低一截，两种状态都要往回提：
        // 窗口态对齐红绿灯（实测红绿灯中心 49，本行未提时 61）→ -12；
        // 全屏没有红绿灯，改为对齐详情列头（实测详情 ✎ 中心 53，本行 63）→ -10。
        .offset(y: workspace.isWindowFullScreen ? -10 : -16)
        .padding(.leading, workspace.headerLeadingInset)
        .padding(.trailing, AppDesign.Spacing.xs)
        .frame(height: AppDesign.Size.columnHeader)
    }

    private var sidebarHeader: some View {
        HStack(spacing: 6) {
            // 不用 fixedSize：列宽被压到最小宽以下时它会溢出并被裁掉，
            // 结果是品牌行整个消失、只剩右边的搜索键。
            Text("LeetCode AI")
                .font(AppDesign.Typography.sectionTitle)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .layoutPriority(1)

            Spacer(minLength: 8)

            sidebarIconButton("magnifyingglass", help: "搜索会话（⌘F）") {
                workspace.isSearchPalettePresented = true
            }
            .keyboardShortcut("f", modifiers: .command)
        }
        .frame(height: 40)
        .padding(.horizontal, 12)
        .padding(.top, 4)
        .padding(.bottom, 5)
    }

    /// 与导航行同一族的普通行（不再是加重主按钮），对齐 Codex 的"新聊天"入口。
    private var newConversationButton: some View {
        Button { createConversation() } label: {
            Label("新建会话", systemImage: "square.and.pencil")
                .symbolRenderingMode(.hierarchical)
                .font(AppDesign.Typography.bodyEmphasis)
                .frame(maxWidth: .infinity, minHeight: AppDesign.Size.compactRow, alignment: .leading)
                .padding(.horizontal, AppDesign.Spacing.xs)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(hoverlessSelection(workspace.selectedSection == .conversation && workspace.selectedConversationID == nil))
        .keyboardShortcut("n", modifiers: .command)
    }

    private func navigationRow(_ section: WorkspaceSection, indented: Bool = false) -> some View {
        Button {
            withAnimation(AppDesign.Motion.selection) { workspace.selectedSection = section }
        } label: {
            Label(section.title, systemImage: section.systemImage)
                .symbolRenderingMode(.hierarchical)
                .font(AppDesign.Typography.body)
                .frame(maxWidth: .infinity, minHeight: AppDesign.Size.compactRow, alignment: .leading)
                .padding(.leading, indented ? Self.indentedInset : AppDesign.Spacing.xs)
                .padding(.trailing, AppDesign.Spacing.xs)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(hoverlessSelection(workspace.selectedSection == section))
        .accessibilityLabel(section.title)
    }

    private func groupHeader(
        _ group: SidebarGroup,
        title: String,
        systemImage: String
    ) -> some View {
        Button {
            withAnimation(.easeOut(duration: 0.14)) {
                if expandedGroups.contains(group) { expandedGroups.remove(group) }
                else { expandedGroups.insert(group) }
            }
        } label: {
            HStack(spacing: 9) {
                Image(systemName: systemImage)
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.secondary)
                    .frame(width: 18)
                Text(title)
                    .font(AppDesign.Typography.bodyEmphasis)
                Spacer(minLength: 4)
            }
            .frame(maxWidth: .infinity, minHeight: AppDesign.Size.compactRow, alignment: .leading)
            .padding(.horizontal, AppDesign.Spacing.xs)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityValue(expandedGroups.contains(group) ? "已展开" : "已收起")
        .padding(.top, 5)
    }

    private func conversationRow(_ conversation: ConversationSummary) -> some View {
        Button {
            withAnimation(AppDesign.Motion.selection) {
                workspace.selectedConversationID = conversation.id
                workspace.selectedSection = .conversation
            }
        } label: {
            FadingSidebarText(conversation.title)
                .font(AppDesign.Typography.body)
                .frame(maxWidth: .infinity, minHeight: 32, alignment: .leading)
                .padding(.leading, Self.indentedInset)
                .padding(.trailing, AppDesign.Spacing.xs)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(
            hoverlessSelection(
                workspace.selectedSection == .conversation
                    && workspace.selectedConversationID == conversation.id
            )
        )
        .help(conversation.summary.isEmpty ? conversation.title : conversation.summary)
        .contextMenu {
            Button("删除会话", systemImage: "trash", role: .destructive) {
                pendingConversationDeletion = conversation
            }
        }
    }

    private func planRow(_ plan: LeetCodePlanSummary) -> some View {
        Button {
            try? dataStore.selectLeetCodePlan(plan.id)
            workspace.selectedSection = .leetCode
        } label: {
            HStack(spacing: 6) {
                FadingSidebarText(plan.name)
                Spacer(minLength: 4)
                Text("\(plan.solvedCount)/\(plan.questionCount)")
                    .font(AppDesign.Typography.micro.monospacedDigit())
                    .foregroundStyle(
                        plan.questionCount > 0 && plan.solvedCount >= plan.questionCount
                            ? AppDesign.ColorToken.success
                            : Color.secondary
                    )
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.primary.opacity(0.05), in: Capsule())
            }
            .font(AppDesign.Typography.body)
            .frame(maxWidth: .infinity, minHeight: 32, alignment: .leading)
            .padding(.leading, Self.indentedInset)
            .padding(.trailing, AppDesign.Spacing.xs)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var accountMenu: some View {
        Menu {
            Button("用量统计", systemImage: "chart.bar.xaxis") {
                workspace.isUsagePresented = true
            }
            Divider()
            Button("账户连接", systemImage: "person.crop.circle") { workspace.presentSettings() }
            Button("设置", systemImage: "gearshape") { workspace.presentSettings() }
            Divider()
            Button("退出 LeetCode AI 助手", systemImage: "rectangle.portrait.and.arrow.right") {
                NSApplication.shared.terminate(nil)
            }
        } label: {
            HStack(spacing: 9) {
                accountAvatar
                Text(dataStore.leetCodeUsername.isEmpty ? "本地用户" : dataStore.leetCodeUsername)
                    .font(AppDesign.Typography.bodyEmphasis)
                    .lineLimit(1)
                Spacer(minLength: 6)
                Image(systemName: "chevron.up.chevron.down")
                    .font(AppDesign.Typography.micro)
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, AppDesign.Spacing.xs)
            .frame(height: 40)
            .contentShape(Rectangle())
            .inlineGlass(cornerRadius: AppDesign.Radius.medium, interactive: true)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .buttonStyle(.plain)
        // `Menu` + `.borderlessButton` **完全不理会 label 的尺寸**，会把自己排成
        // 「可用宽度 × 512」，于是头像和名字被挤到那块巨大区域的正中间——
        // 看起来就是账户行没有左对齐。`.fixedSize()` 不但无效还会更糟，
        // 唯一可行的是量出可用宽度后显式钉死。
        .frame(
            width: max(0, sidebarWidth - AppDesign.Spacing.xs * 2),
            height: AppDesign.Size.columnHeader,
            alignment: .leading
        )
        .accessibilityLabel("账户与设置")
    }

    /// 头像：先把图片在 AppKit 层面渲染成 28pt 圆形小图（固有尺寸），
    /// SwiftUI 拿到的就是一张小圆图，任何布局都不可能把它撑大。
    @ViewBuilder
    private var accountAvatar: some View {
        Group {
            if let data = dataStore.leetCodeProfile.avatarData, let image = NSImage(data: data) {
                Image(nsImage: AvatarRenderer.circular(image))
            } else if let url = dataStore.leetCodeProfile.avatarURL {
                RemoteAvatarImage(url: url)
            } else {
                monogramAvatar
            }
        }
        .frame(width: 28, height: 28)
        .overlay {
            Circle().strokeBorder(.white.opacity(0.3), lineWidth: 0.5)
        }
        .shadow(color: .black.opacity(0.08), radius: 2.5, y: 1)
    }

    /// 无头像时的字母徽标：渐变玻璃底 + 用户名首字符。
    private var monogramAvatar: some View {
        ZStack {
            Circle()
                .fill(
                    LinearGradient(
                        colors: [.teal, .blue.opacity(0.85)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
            if let initial = dataStore.leetCodeUsername.first {
                Text(String(initial).uppercased())
                    .font(AppDesign.Typography.auxEmphasis)
                    .foregroundStyle(.white)
            } else {
                Image(systemName: "person.fill")
                    .font(AppDesign.Typography.auxEmphasis)
                    .foregroundStyle(.white)
            }
        }
        .frame(width: 28, height: 28)
    }

    private var sidebarSurface: some View {
        AppDesign.ColorToken.sidebarSurface
            .ignoresSafeArea()
    }

    private func hoverlessSelection(_ selected: Bool) -> some View {
        RoundedRectangle(cornerRadius: AppDesign.Radius.medium, style: .continuous)
            .fill(selected ? AppDesign.ColorToken.listSelection : .clear)
    }

    /// 二级行（学习中心子项 / 会话 / 题单）统一缩进，删掉此前 27 与 35 两套体系。
    private static let indentedInset: CGFloat = 27

    private func sidebarIconButton(_ systemImage: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(AppDesign.Typography.icon)
                .frame(width: AppDesign.Size.fieldHeight, height: AppDesign.Size.fieldHeight)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private func createConversation() {
        withAnimation(AppDesign.Motion.selection) {
            workspace.selectedConversationID = nil
            workspace.selectedSection = .conversation
        }
    }

    private func deleteConversation(_ conversation: ConversationSummary) {
        do {
            try dataStore.deleteConversation(conversation.id)
            if workspace.selectedConversationID == conversation.id {
                workspace.selectedConversationID = nil
            }
        } catch {
            NSSound.beep()
        }
        pendingConversationDeletion = nil
    }
}

/// 把任意图片渲染成固定点尺寸的圆形头像（纵横填充裁剪），
/// 产物是固有尺寸 28pt 的 NSImage，SwiftUI 端无需任何缩放修饰符。
private enum AvatarRenderer {
    static func circular(_ source: NSImage, diameter: CGFloat = 28) -> NSImage {
        let size = NSSize(width: diameter, height: diameter)
        return NSImage(size: size, flipped: false) { rect in
            NSGraphicsContext.current?.imageInterpolation = .high
            NSBezierPath(ovalIn: rect).addClip()
            let s = source.size
            guard s.width > 0, s.height > 0 else { return false }
            let scale = max(rect.width / s.width, rect.height / s.height)
            let w = s.width * scale
            let h = s.height * scale
            source.draw(
                in: NSRect(x: rect.midX - w / 2, y: rect.midY - h / 2, width: w, height: h),
                from: .zero,
                operation: .sourceOver,
                fraction: 1
            )
            return true
        }
    }
}

/// 远程头像：自行下载并预渲染成 28pt 圆形小图，绕开 AsyncImage 的布局缺陷。
private struct RemoteAvatarImage: View {
    let url: URL
    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
            } else {
                Circle().fill(.quaternary)
            }
        }
        .task(id: url) {
            guard image == nil else { return }
            let key = url.absoluteString
            if let cached = RemoteAvatarCache.shared.image(for: key) {
                image = cached
                return
            }
            guard !Task.isCancelled,
                  let (data, _) = try? await URLSession.shared.data(from: url),
                  !Task.isCancelled,
                  let downloaded = NSImage(data: data)
            else { return }
            let rendered = AvatarRenderer.circular(downloaded)
            guard !Task.isCancelled else { return }
            RemoteAvatarCache.shared.insert(rendered, for: key)
            image = rendered
        }
    }
}

@MainActor
private final class RemoteAvatarCache {
    static let shared = RemoteAvatarCache()
    private let storage = NSCache<NSString, NSImage>()

    private init() {
        storage.countLimit = 64
        storage.totalCostLimit = 16 * 1_024 * 1_024
    }

    func image(for key: String) -> NSImage? {
        storage.object(forKey: key as NSString)
    }

    func insert(_ image: NSImage, for key: String) {
        let pixelCost = max(1, Int(image.size.width * image.size.height * 4))
        storage.setObject(image, forKey: key as NSString, cost: pixelCost)
    }
}

private enum SidebarGroup: Hashable {
    case learning
    case conversations
    case plans
}

private struct FadingSidebarText: View {
    let value: String
    @State private var idealWidth: CGFloat = 0
    @State private var actualWidth: CGFloat = 0

    init(_ value: String) {
        self.value = value
    }

    private var isTruncated: Bool { idealWidth > actualWidth + 1 }

    var body: some View {
        Text(value)
            .lineLimit(1)
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { actualWidth = $0 }
            .background(
                Text(value)
                    .lineLimit(1)
                    .fixedSize()
                    .hidden()
                    .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { idealWidth = $0 }
            )
            // 只有真的被截断时才加尾端渐隐；文本放得下时最后一个字符不发虚。
            .mask {
                LinearGradient(
                    stops: [
                        .init(color: .black, location: 0),
                        .init(color: .black, location: isTruncated ? 0.88 : 1),
                        .init(color: .clear, location: 1)
                    ],
                    startPoint: .leading,
                    endPoint: .trailing
                )
            }
    }
}



struct SearchPaletteView: View {
    @Bindable var workspace: WorkspaceState
    @Bindable var dataStore: LegacyDataStore
    let onDismiss: () -> Void

    @State private var query = ""
    @State private var selectedIndex = 0
    @FocusState private var isFocused: Bool

    private var results: [ConversationSummary] {
        let source = dataStore.conversations
        guard !query.isEmpty else { return Array(source.prefix(9)) }
        return Array(source.filter {
            $0.title.localizedCaseInsensitiveContains(query)
                || $0.summary.localizedCaseInsensitiveContains(query)
        }.prefix(9))
    }

    var body: some View {
        ZStack(alignment: .top) {
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture { onDismiss() }

            panel
                .frame(width: 640)
                .padding(.top, 96)
        }
        .onExitCommand { onDismiss() }
        .onAppear { isFocused = true }
    }

    private var panel: some View {
        VStack(alignment: .leading, spacing: 0) {
            TextField("搜索聊天", text: $query)
                .textFieldStyle(.plain)
                .font(.title3)
                .focused($isFocused)
                .padding(.horizontal, 18)
                .padding(.top, 16)
                .padding(.bottom, 8)
                .onChange(of: query) { _, _ in selectedIndex = 0 }
                .onSubmit { selectCurrent() }

            VStack(alignment: .leading, spacing: 2) {
                sectionTitle("聊天")
                ForEach(Array(results.enumerated()), id: \.element.id) { index, conversation in
                    paletteRow(
                        title: conversation.title,
                        shortcut: "⌘\(index + 1)",
                        highlighted: index == selectedIndex
                    ) {
                        select(conversation)
                    }
                    .onHover { hovering in
                        if hovering { selectedIndex = index }
                    }
                }

                sectionTitle("推荐")
                    .padding(.top, 8)
                paletteRow(
                    title: "新聊天",
                    shortcut: "⌘N",
                    systemImage: "square.and.pencil",
                    highlighted: false
                ) {
                    workspace.selectedConversationID = nil
                    workspace.selectedSection = .conversation
                    onDismiss()
                }
            }
            .padding(.horizontal, 8)
            .padding(.bottom, 10)
        }
        .background(
            Color(nsColor: .textBackgroundColor),
            in: RoundedRectangle(cornerRadius: 16, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(.primary.opacity(0.06))
        }
        .shadow(color: .black.opacity(0.10), radius: 24, y: 10)
        .onMoveCommand { direction in
            switch direction {
            case .down: selectedIndex = min(selectedIndex + 1, max(0, results.count - 1))
            case .up: selectedIndex = max(selectedIndex - 1, 0)
            default: break
            }
        }
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(title)
            .font(.callout)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            .padding(.top, 8)
            .padding(.bottom, 4)
    }

    private func paletteRow(
        title: String,
        shortcut: String,
        systemImage: String? = nil,
        highlighted: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(.secondary)
                        .frame(width: 18)
                }
                Text(title)
                    .font(.callout)
                    .lineLimit(1)
                Spacer(minLength: 12)
                Text(shortcut)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(Color.primary.opacity(0.05), in: Capsule())
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(
                highlighted ? Color.primary.opacity(0.06) : .clear,
                in: RoundedRectangle(cornerRadius: 10, style: .continuous)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func selectCurrent() {
        guard results.indices.contains(selectedIndex) else { return }
        select(results[selectedIndex])
    }

    private func select(_ conversation: ConversationSummary) {
        workspace.selectedSection = .conversation
        workspace.selectedConversationID = conversation.id
        onDismiss()
    }
}
