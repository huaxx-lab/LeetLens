import SwiftUI

enum AppDesign {
    /// 字体阶梯（G-T1）：全 App 只有这一组字号，View 层不再新增 `.system(size:)`。
    /// 尺寸集合收敛为 26 / 22 / 17 / 15 / 13 / 12 / 11 七档，无半点字号。
    enum Typography {
        static let display = Font.system(size: 26, weight: .semibold)
        static let pageTitle = Font.system(size: 22, weight: .semibold)
        static let metricValue = Font.system(size: 22, weight: .semibold).monospacedDigit()
        static let sectionTitle = Font.system(size: 17, weight: .semibold)
        static let rowTitle = Font.system(size: 15, weight: .medium)
        /// 标题行的加重版：窗口标题、侧栏品牌行等"页面身份"文字。
        static let rowTitleEmphasis = Font.system(size: 15, weight: .semibold)
        static let body = Font.system(size: 13)
        static let bodyEmphasis = Font.system(size: 13, weight: .medium)
        static let aux = Font.system(size: 12)
        static let auxEmphasis = Font.system(size: 12, weight: .medium)
        static let micro = Font.system(size: 11)
        static let mono = Font.system(size: 12, design: .monospaced)
        /// 行内 SF Symbol 的统一口径（G-T5）。
        static let icon = Font.system(size: 15)
        static let iconCompact = Font.system(size: 13, weight: .medium)
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

    enum Size {
        /// 列头部高度。红绿灯与列头同一条中线——但不是列头去迁就系统，
        /// 而是 `WindowTitlebarLayout` 把红绿灯挪到列头这条线上来。
        /// 不要用 AppKit accessory 加高标题栏：实测按钮纹丝不动，那一层还会吃掉整行点击。
        static let columnHeader: CGFloat = 40
        /// 列头到窗口顶边的留白。窗口态谁都不许贴着顶边框，红绿灯也一样。
        /// 4pt：红绿灯中线落到 24pt（系统默认 16pt），比 Codex 略松一点点就够，
        /// 再多整条列头就和窗口脱节了。
        static let headerTopMargin: CGFloat = 4
        /// 系统默认标题栏高度。
        static let windowTitlebarInset: CGFloat = 28
        /// 红绿灯自己的左内缩。系统默认 9pt，贴边太紧，往右挪 3pt 和顶部留白配平。
        static let trafficLightLeadingInset: CGFloat = 14
        /// 红绿灯占位宽度：最左列头从这里之后开始排（三颗按钮 69pt + 一档间距）。
        static let trafficLightInset: CGFloat = 81
        static let sidebarMin: CGFloat = 218
        static let sidebarIdeal: CGFloat = 256
        static let sidebarMax: CGFloat = 310
        static let compactRow: CGFloat = 34
        static let listRow: CGFloat = 44
        static let contextPanel: CGFloat = 312
        static let contextPanelMinimum: CGFloat = 292
        static let contextPanelMaximum: CGFloat = 324
        static let inspectorMin: CGFloat = 380
        static let inspectorIdeal: CGFloat = 460
        static let inspectorMax: CGFloat = 620
        static let primaryMinimum: CGFloat = 620
        static let contentReadable: CGFloat = 780
        /// 对话正文 / 标题 / 输入框共用的内容列宽上限。
        /// 1100 而不是原来的 820：820 时正文在宽列里居中，左边会空出一大条，
        /// 和贴着列左缘的问题刻度条隔着一片空白。让正文往外延展，那条空白就没了。
        static let contentColumnMaximum: CGFloat = 1_100
        static let composerMinimumHeight: CGFloat = 50
        static let toolbarControl: CGFloat = 28
        static let rail: CGFloat = 56
        /// 页面头两档高度（G-T3）：列表类 44、带主按钮 54。
        static let pageHeader: CGFloat = 44
        static let pageHeaderProminent: CGFloat = 54
        /// 工具条内竖分隔线高度。
        static let toolbarSeparator: CGFloat = 18
        /// 内联输入框统一高度。
        static let fieldHeight: CGFloat = 30
        /// 行内图标槽位宽度，保证同列图标左缘对齐。
        static let iconSlot: CGFloat = 24
    }

    enum Motion {
        static let panel = Animation.spring(response: 0.38, dampingFraction: 0.88, blendDuration: 0.08)
        /// 分栏显隐使用无回弹的短过渡，既不僵硬，也不会让重型内容来回越界重排。
        static let panelTransition = Animation.easeInOut(duration: 0.22)
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
