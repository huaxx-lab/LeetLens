import SwiftUI

/// 页面交给中间列列头排版的内容。
///
/// **为什么需要它**：以前每个页面在列头下面再铺一条自己的工具条——
/// 列头写着「刷题 ···」，下面一条是「题库 | 动态 | 提交 · 搜索 · 刷新」，打开题目再多一条
/// 「‹ 49. 字母异位词分组 · 题目与提交 | 作答」，三条横带叠起来占掉 130pt，
/// 列头里还挂着和当前页无关的「新建会话」「分享」「任务上下文」。
/// 对齐 Codex：一列只有一行头部，左边是"我在哪"，右边是"这一页能做什么"，
/// 页面把自己的控件交上来，由列头统一排进那一行。
struct WorkspaceHeaderContent {
    /// 空字符串表示页面没有提供内容，列头按默认（显示分区标题）排。
    var id = ""
    /// 页面自己在 `leading` 里给了标题 / 面包屑时，列头不再重复写分区名。
    var hidesTitle = false
    var leading: AnyView?
    var trailing: AnyView?

    var isProvided: Bool { !id.isEmpty }
}

struct WorkspaceHeaderContentKey: PreferenceKey {
    static var defaultValue: WorkspaceHeaderContent { WorkspaceHeaderContent() }

    /// 同一时刻只有当前分区的页面在树里，谁提供了就用谁的；
    /// 嵌套的子视图后提供的覆盖先提供的（越深越具体）。
    static func reduce(value: inout WorkspaceHeaderContent, nextValue: () -> WorkspaceHeaderContent) {
        let next = nextValue()
        if next.isProvided { value = next }
    }
}

extension View {
    /// 把页面控件交给列头。`id` 只用来区分"提供了 / 没提供"，不参与更新判断——
    /// 闭包里读到的状态变了，页面 body 重算，列头跟着拿到新内容。
    func workspaceHeader<Leading: View, Trailing: View>(
        id: String,
        hidesTitle: Bool = true,
        @ViewBuilder leading: () -> Leading,
        @ViewBuilder trailing: () -> Trailing
    ) -> some View {
        preference(
            key: WorkspaceHeaderContentKey.self,
            value: WorkspaceHeaderContent(
                id: id,
                hidesTitle: hidesTitle,
                leading: AnyView(leading()),
                trailing: AnyView(trailing())
            )
        )
    }
}

/// 列头里的纯图标按钮：28pt 方形点击区、悬停才出底色。
/// 和 `ColumnHeaderButton` 同尺寸，但带 hover 与选中态，给页面操作用。
struct HeaderIconButton: View {
    let systemName: String
    let help: String
    var isSelected = false
    var disabled = false
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(AppDesign.Typography.iconCompact)
                .symbolRenderingMode(.hierarchical)
                .frame(width: AppDesign.Size.toolbarControl, height: AppDesign.Size.toolbarControl)
                .background(
                    isSelected ? AppDesign.ColorToken.selection : (isHovering && !disabled ? AppDesign.ColorToken.hover : .clear),
                    in: RoundedRectangle(cornerRadius: AppDesign.Radius.small, style: .continuous)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .foregroundStyle(disabled ? AnyShapeStyle(.tertiary) : (isSelected ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.secondary)))
        .onHover { isHovering = $0 }
        .help(help)
        .accessibilityLabel(help)
    }
}

/// 列头里带文字的操作（「问 AI」这种主操作）：胶囊、图标 + 文字。
struct HeaderPillButton: View {
    let title: String
    let systemImage: String
    var isSelected = false
    var help: String? = nil
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(AppDesign.Typography.auxEmphasis)
                .labelStyle(.titleAndIcon)
                .padding(.horizontal, 10)
                .frame(height: AppDesign.Size.toolbarControl - 2)
                .background(
                    isSelected ? AppDesign.ColorToken.selection : (isHovering ? AppDesign.ColorToken.hover : AppDesign.ColorToken.inlineFill),
                    in: Capsule()
                )
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .foregroundStyle(isSelected ? Color.accentColor : Color.primary)
        .onHover { isHovering = $0 }
        .help(help ?? title)
    }
}

/// 列头里的竖分隔线：页面操作 | 面板开关。
struct HeaderDivider: View {
    var body: some View {
        Rectangle()
            .fill(AppDesign.ColorToken.separator)
            .frame(width: 1, height: AppDesign.Size.toolbarSeparator)
            .padding(.horizontal, AppDesign.Spacing.xxs)
    }
}
