import SwiftUI

enum AppDesign {
    /// 字体阶梯（G-T1）：全 App 只有这一组字号，View 层不再新增 `.system(size:)`。
    /// 基准尺寸集合收敛为 26 / 22 / 17 / 15 / 13 / 12 / 11 七档，无半点字号。
    ///
    /// 每档都乘 `scale`（「设置 ▸ 外观 ▸ 界面字号」）。所以这里是**计算属性**而不是 `static let`：
    /// `static let` 在进程启动时就定死了，换档位不会变；计算属性在 View 的 body 里求值，
    /// 那次对 `InterfaceMetrics.shared` 的读取会被 SwiftUI 登记成依赖，改档位即时重绘。
    @MainActor
    enum Typography {
        /// 当前界面字号倍率，见 `InterfaceMetrics`。
        static var scale: CGFloat { InterfaceMetrics.shared.scale }

        static var display: Font { .system(size: 26 * scale, weight: .semibold) }
        static var pageTitle: Font { .system(size: 22 * scale, weight: .semibold) }
        static var metricValue: Font { .system(size: 22 * scale, weight: .semibold).monospacedDigit() }
        static var sectionTitle: Font { .system(size: 17 * scale, weight: .semibold) }
        static var rowTitle: Font { .system(size: 15 * scale, weight: .medium) }
        /// 标题行的加重版：窗口标题、侧栏品牌行等"页面身份"文字。
        static var rowTitleEmphasis: Font { .system(size: 15 * scale, weight: .semibold) }
        static var body: Font { .system(size: 13 * scale) }
        static var bodyEmphasis: Font { .system(size: 13 * scale, weight: .medium) }
        static var aux: Font { .system(size: 12 * scale) }
        static var auxEmphasis: Font { .system(size: 12 * scale, weight: .medium) }
        static var micro: Font { .system(size: 11 * scale) }
        static var mono: Font { .system(size: 12 * scale, design: .monospaced) }
        /// 行内 SF Symbol 的统一口径（G-T5）。
        static var icon: Font { .system(size: 15 * scale) }
        static var iconCompact: Font { .system(size: 13 * scale, weight: .medium) }
    }

    enum Spacing {
        static let xxs: CGFloat = 4
        static let xs: CGFloat = 8
        static let compact: CGFloat = 10
        static let sm: CGFloat = 12
        static let rowInset: CGFloat = 14
        static let md: CGFloat = 16
        static let lg: CGFloat = 24
        static let section: CGFloat = 28
        static let xl: CGFloat = 32
    }

    enum Radius {
        static let small: CGFloat = 6
        static let medium: CGFloat = 8
        static let card: CGFloat = 10
        static let floating: CGFloat = 16
        static let composer: CGFloat = 22
    }

    /// 尺寸阶梯。
    ///
    /// 分两类：
    /// **窗口 chrome**（列头高度、红绿灯内缩、标题栏）是死数——它们要和系统画的东西对齐，
    /// 跟着界面字号一起变会把红绿灯和列头的中线错开。
    /// **装文字的那些**（列宽、行高、输入框）跟着 `Typography.scale` 一起放大：
    /// 只放大字不放大列，侧栏标题只会截得更狠——"字大了反而更难看"就是这么来的。
    @MainActor
    enum Size {
        /// 装文字的尺寸统一走它。取整到整数点，避免半点宽度在分栏线上抖。
        private static func scaled(_ value: CGFloat) -> CGFloat {
            (value * AppDesign.Typography.scale).rounded()
        }

        // MARK: 窗口 chrome —— 不缩放

        /// 列头部高度。红绿灯与列头同一条中线——但不是列头去迁就系统，
        /// 而是 `WindowTitlebarLayout` 把红绿灯挪到列头这条线上来。
        /// 不要用 AppKit accessory 加高标题栏：实测按钮纹丝不动，那一层还会吃掉整行点击。
        nonisolated static let columnHeader: CGFloat = 40
        /// 列头到窗口顶边的留白。窗口态谁都不许贴着顶边框，红绿灯也一样。
        /// 4pt：红绿灯中线落到 24pt（系统默认 16pt），比 Codex 略松一点点就够，
        /// 再多整条列头就和窗口脱节了。
        nonisolated static let headerTopMargin: CGFloat = 4
        /// 系统默认标题栏高度。
        nonisolated static let windowTitlebarInset: CGFloat = 28
        /// 红绿灯自己的左内缩。系统默认 9pt，贴边太紧，往右挪 3pt 和顶部留白配平。
        nonisolated static let trafficLightLeadingInset: CGFloat = 14
        /// 红绿灯占位宽度：最左列头从这里之后开始排（三颗按钮 69pt + 一档间距）。
        nonisolated static let trafficLightInset: CGFloat = 81
        /// 标题栏那一带的控件槽位。跟着 `columnHeader` 走，所以也不缩放：
        /// 它放大而列头不放大，控件就会顶出那条 40pt 的可视带。
        nonisolated static let toolbarControl: CGFloat = 28
        /// 工具条内竖分隔线高度。
        nonisolated static let toolbarSeparator: CGFloat = 18
        nonisolated static let rail: CGFloat = 56

        // MARK: 装文字的尺寸 —— 跟随界面字号

        /// 页内列表列（题库列表 / 复习队列 / 算法模板 / 计划日历这类"二级侧栏"）的可拖区间。
        /// 和第一列不是一回事：它在详情窗格内部，窗口拉宽时得能跟着拉宽，
        /// 否则 1920 的窗口里它还是 268pt，多出来的宽度全堆给右边。
        static var paneListMin: CGFloat { scaled(240) }
        static var paneListMax: CGFloat { scaled(520) }
        static var sidebarMin: CGFloat { scaled(218) }
        static var sidebarIdeal: CGFloat { scaled(256) }
        static var sidebarMax: CGFloat { scaled(310) }
        static var compactRow: CGFloat { scaled(34) }
        static var listRow: CGFloat { scaled(44) }
        static var contextPanel: CGFloat { scaled(312) }
        static var contextPanelMinimum: CGFloat { scaled(292) }
        static var contextPanelMaximum: CGFloat { scaled(324) }
        static var inspectorMin: CGFloat { scaled(380) }
        static var inspectorIdeal: CGFloat { scaled(460) }
        /// 第三列的**兜底**上限，真正的上限按窗口算（`WorkspaceSplitLayoutPolicy.inspectorMax(total:sidebarWidth:)`）：
        /// 写死 620 的话，屏幕再大第三列也只能到 620pt，浏览器一开就挤。
        static var inspectorMax: CGFloat { scaled(620) }
        /// 中间列最小宽。**自动布局**用它：窗口窄到三列放不下时，应用自己收侧栏。
        static var primaryMinimum: CGFloat { scaled(620) }
        /// 手动拖分栏线时中间列的下限。比自动断点低——你自己把它压窄是明确意图，
        /// 和"窗口太小、应用替你决定"是两回事。第三列能拉多宽由它决定。
        static var primaryDragMinimum: CGFloat { scaled(420) }
        static var contentReadable: CGFloat { scaled(780) }
        /// 设置页表单列宽。全 App 只有这一个值：页头当年写死 740、账户页内容却用 980，
        /// 于是那一页的标题和卡片左缘对不齐。
        static var settingsColumn: CGFloat { scaled(740) }
        /// 对话正文 / 标题 / 输入框共用的内容列宽上限。
        /// 1100 而不是原来的 820：820 时正文在宽列里居中，左边会空出一大条，
        /// 和贴着列左缘的问题刻度条隔着一片空白。让正文往外延展，那条空白就没了。
        static var contentColumnMaximum: CGFloat { scaled(1_100) }
        /// 仪表盘类页面（学习洞察这种卡片网格）的版心上限。
        /// 比正文列宽得多：卡片网格不是要读的长句子，没有"每行别超过 N 个字"的约束，
        /// 钉在 1100 的结果就是 1920 宽的窗口里两侧各空 400pt，内容缩成中间一座孤岛。
        static var dashboardColumnMaximum: CGFloat { scaled(1_600) }
        static var composerMinimumHeight: CGFloat { scaled(50) }
        /// 页面头两档高度（G-T3）：列表类 44、带主按钮 54。
        static var pageHeader: CGFloat { scaled(44) }
        static var pageHeaderProminent: CGFloat { scaled(54) }
        /// 内联输入框统一高度。
        static var fieldHeight: CGFloat { scaled(30) }
        /// 行内图标槽位宽度，保证同列图标左缘对齐。
        static var iconSlot: CGFloat { scaled(24) }
    }

    enum Motion {
        static let panel = Animation.spring(response: 0.38, dampingFraction: 0.88, blendDuration: 0.08)
        /// 分栏显隐使用无回弹的短过渡，既不僵硬，也不会让重型内容来回越界重排。
        /// 三列开合的时长。内容宽度现在跟着裁剪框一起补间（"一个平面"），
        /// 这一段里网页要逐帧重排，帧数越少越稳，所以从 0.22 收到 0.18。
        static let panelTransitionDuration: Double = 0.18
        static let panelTransition = Animation.easeInOut(duration: panelTransitionDuration)
        static let selection = Animation.snappy(duration: 0.22, extraBounce: 0.03)
        static let subtle = Animation.easeOut(duration: 0.16)
        static let fade = Animation.easeInOut(duration: 0.18)
    }

    enum ColorToken {
        static let canvas = Color(nsColor: .textBackgroundColor)
        static let sidebar = Color(nsColor: .windowBackgroundColor).opacity(0.42)
        /// 侧栏整列（含顶部红绿灯行）统一的淡灰表面，对齐 Codex。
        /// 侧栏整列底色：比中间画布深一档，窗口态/全屏态共用同一种颜色。
        /// `windowBackgroundColor` 在新系统上几乎和画布同色，换 underPage 才拉得开。
        static let sidebarSurface = Color(nsColor: .underPageBackgroundColor)
        static let raised = Color(nsColor: .controlBackgroundColor)
        static let separator = Color.primary.opacity(0.075)
        static let selection = Color.accentColor.opacity(0.12)
        /// 列表行选中底色：与系统列表（Finder/备忘录非焦点态）一致，全 App 唯一实现（G-T6）。
        static let listSelection = Color(nsColor: .unemphasizedSelectedContentBackgroundColor)
        static let code = Color(nsColor: .textBackgroundColor)
        static let success = Color(nsColor: .systemGreen)
        static let warning = Color(nsColor: .systemOrange)
        /// 悬停态：全 App 唯一实现（G-T6），替代散落的 0.05/0.055/0.065。
        static let hover = Color.primary.opacity(0.05)
        /// 内联控件底（搜索框、地址栏、胶囊按钮的静态底色）。
        static let inlineFill = Color.primary.opacity(0.06)
        static let info = Color(nsColor: .systemBlue)
    }
}

private struct NavigationGlassModifier: ViewModifier {
    let cornerRadius: CGFloat
    let interactive: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            if interactive {
                content.glassEffect(.regular.interactive(), in: .rect(cornerRadius: cornerRadius))
            } else {
                content.glassEffect(.regular, in: .rect(cornerRadius: cornerRadius))
            }
        } else {
            content
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .strokeBorder(.primary.opacity(0.09))
                }
                .shadow(color: .black.opacity(0.08), radius: 18, y: 8)
        }
    }
}

extension View {
    func navigationGlass(
        cornerRadius: CGFloat = AppDesign.Radius.floating,
        interactive: Bool = false
    ) -> some View {
        modifier(NavigationGlassModifier(cornerRadius: cornerRadius, interactive: interactive))
    }
}

/// 贴附在内容表面上的轻量玻璃（无悬浮投影），用于胶囊按钮、账户行等内联控件。
private struct InlineGlassModifier: ViewModifier {
    let cornerRadius: CGFloat
    let interactive: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            if interactive {
                content.glassEffect(.regular.interactive(), in: .rect(cornerRadius: cornerRadius))
            } else {
                content.glassEffect(.regular, in: .rect(cornerRadius: cornerRadius))
            }
        } else {
            content
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .strokeBorder(.primary.opacity(0.08))
                }
        }
    }
}

extension View {
    func inlineGlass(cornerRadius: CGFloat, interactive: Bool = false) -> some View {
        modifier(InlineGlassModifier(cornerRadius: cornerRadius, interactive: interactive))
    }
}
