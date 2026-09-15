import SwiftUI

// MARK: - 一体化页面的表面约定（2026-09）
//
// 用户原话："不要这样进行布局设计，尽量一体化""我要的是简洁优美"。
// 之前的做法是每块内容一张玻璃卡：列表一张、详情一张、详情里每小节再一张，
// 页面变成一格一格的盒子，边框、底色、圆角、阴影叠了好几层。现在的规矩：
//
// 1. 一页就是一张画布。列与列之间一条发丝线（`Hairline`），不再给整列套圆角卡。
// 2. 内容靠字重、字号和留白分组（`DocumentSection`），不画框。
// 3. 只有"内容对象"保留一块很淡的实底：代码块、输入框。
// 4. 玻璃只给真正浮在内容上面的东西：对话输入框、浮窗、弹出层、底部胶囊条。
// 5. 颜色克制：小节图标一律次级灰；强调色只用于选中态和主操作。

/// 一像素分隔线。列之间竖着用，区块之间横着用。
struct Hairline: View {
    var axis: Axis = .horizontal

    var body: some View {
        Rectangle()
            .fill(AppDesign.ColorToken.separator)
            .frame(width: axis == .vertical ? 1 : nil, height: axis == .horizontal ? 1 : nil)
            .allowsHitTesting(false)
    }
}

/// 文档里的一节：小标题 + 内容。不铺底、不描边。
struct DocumentSection<Content: View, Accessory: View>: View {
    let title: String
    var systemImage: String?
    @ViewBuilder var accessory: () -> Accessory
    @ViewBuilder var content: () -> Content

    init(
        _ title: String,
        systemImage: String? = nil,
        @ViewBuilder accessory: @escaping () -> Accessory = { EmptyView() },
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.title = title
        self.systemImage = systemImage
        self.accessory = accessory
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AppDesign.Spacing.sm) {
            HStack(spacing: 6) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .font(AppDesign.Typography.aux)
                        .foregroundStyle(.secondary)
                }
                Text(title)
                    .font(AppDesign.Typography.headline)
                Spacer(minLength: 0)
                accessory()
            }
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// 一排并列的指标：同一条带子里用竖发丝线隔开，不再是四张分开的卡。
struct MetricStrip<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            content()
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// `MetricStrip` 里的一格。`showsDivider` 给除第一格以外的格子画左侧竖线。
struct MetricCell: View {
    let title: String
    let value: String
    var unit: String = ""
    var detail: String?
    var tint: Color = .primary
    var showsDivider = true

    var body: some View {
        HStack(spacing: 0) {
            if showsDivider {
                Hairline(axis: .vertical)
                    .padding(.vertical, AppDesign.Spacing.xxs)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(AppDesign.Typography.aux)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                HStack(alignment: .firstTextBaseline, spacing: 1) {
                    Text(value)
                        .font(AppDesign.Typography.metricValue)
                        .foregroundStyle(tint)
                    if !unit.isEmpty {
                        Text(unit)
                            .font(AppDesign.Typography.aux)
                            .foregroundStyle(.secondary)
                    }
                }
                if let detail {
                    Text(detail)
                        .font(AppDesign.Typography.micro)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, AppDesign.Spacing.md)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }
}

/// 页面级的扁平按钮（页头动作）：很淡的实底胶囊，主操作用强调色实底。
struct PageActionButton: View {
    let title: String
    let systemImage: String
    var isProminent = false
    var isBusy = false
    var help: String?
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if isBusy {
                    ProgressView().controlSize(.small).scaleEffect(0.65).frame(width: 12, height: 12)
                } else {
                    Image(systemName: systemImage).font(AppDesign.Typography.aux.weight(.semibold))
                }
                Text(title).font(AppDesign.Typography.auxEmphasis)
            }
            .foregroundStyle(isProminent ? Color.white : Color.primary)
            .padding(.horizontal, 10)
            .frame(height: AppDesign.Size.toolbarControl - 2)
            .background(background, in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .help(help ?? title)
    }

    private var background: Color {
        if isProminent { return Color.accentColor.opacity(isHovering ? 0.9 : 1) }
        return isHovering ? AppDesign.ColorToken.hover.opacity(1.6) : AppDesign.ColorToken.inlineFill
    }
}

extension View {
    /// 页内静态控件的底（筛选、页内按钮、菜单胶囊）：一层很淡的实底，不是玻璃。
    /// 真正浮在内容上的控件（脑图工具条、运行 / 提交）才用 `glassCapsule()`。
    func quietCapsule() -> some View {
        background(AppDesign.ColorToken.inlineFill, in: Capsule())
    }

    func quietCircle() -> some View {
        background(AppDesign.ColorToken.inlineFill, in: Circle())
    }
}

/// 在两种 LabelStyle 之间按条件切换（`ViewThatFits` 的宽窄两档用）。
struct AnyLabelStyle: LabelStyle {
    private let make: (Configuration) -> AnyView

    init<Style: LabelStyle>(_ style: Style) {
        make = { AnyView(Label($0).labelStyle(style)) }
    }

    func makeBody(configuration: Configuration) -> some View {
        make(configuration)
    }
}
