import SwiftUI

/// 页内列表列（算法模板列表、学习计划日历这类"二级侧栏"）。
///
/// **为什么需要它**：这些列原来是写死的 pt——`minWidth: 268, maxWidth: 268`、
/// `minWidth: 344, maxWidth: 344`——上下界一样就等于焊死。窗口从 1440 拉到 1920，
/// 它们纹丝不动，多出来的 480pt 全给了右边；列表里被截断的标题拉多宽都还是截断的。
///
/// 这里给它们一条统一的可拖区间，用的是第一列分栏线那同一个 `ColumnResizeHandle`
/// （光标、8pt 抓取带、拖动时锁窗口移动的处理都现成）。宽度按页各存各的：
/// 日历和模板列表想要的宽度本来就不一样，共用一个键会互相打架。
///
/// 不改成 `HSplitView`：那会给每个 pane 画自己的不透明底，圆角玻璃卡外面又套出
/// 一个直角矩形，背景渐变也被挡住——这两页当初就是因为这个才从 HSplitView 换回 HStack 的。
struct PaneListColumnModifier: ViewModifier {
    let storageKey: String
    let defaultWidth: CGFloat
    let range: ClosedRange<CGFloat>

    @State private var width: CGFloat?

    private var current: CGFloat { width ?? defaultWidth }

    func body(content: Content) -> some View {
        content
            .frame(width: current)
            .frame(maxHeight: .infinity)
            .overlay(alignment: .trailing) {
                ColumnResizeHandle(
                    width: current,
                    range: range,
                    growsOnDragRight: true
                ) { newValue in
                    width = newValue
                    UserDefaults.standard.set(Double(newValue), forKey: storageKey)
                }
            }
            .onAppear {
                guard width == nil else { return }
                let stored = UserDefaults.standard.double(forKey: storageKey)
                // 存过的值也要重新夹一遍：区间以后可能收窄，旧值不该把列顶出界。
                width = stored > 0 ? min(max(stored, range.lowerBound), range.upperBound) : defaultWidth
            }
    }
}

extension View {
    /// - Parameters:
    ///   - storageKey: 这一列自己的宽度存档键，各页不共用。
    ///   - defaultWidth: 没存过时的初始宽度，保持各页原本的观感。
    ///   - minWidth: 下限。日历那种有固定列数的内容要比列表给得高一些。
    func paneListColumn(
        storageKey: String,
        defaultWidth: CGFloat,
        minWidth: CGFloat = AppDesign.Size.paneListMin,
        maxWidth: CGFloat = AppDesign.Size.paneListMax
    ) -> some View {
        modifier(
            PaneListColumnModifier(
                storageKey: storageKey,
                defaultWidth: defaultWidth,
                range: minWidth...maxWidth
            )
        )
    }
}

/// 两栏等价内容的比例分栏（刷题页的题面 / 代码与提交）。
///
/// **为什么不用 `HSplitView`**：它是 `NSSplitView`，不吃 SwiftUI 动画。三列开合时
/// 外层列宽正在补间，它每一帧都按新宽度重新分配窗格、里面的 WKWebView 每帧重排一次，
/// 画面上就是窗格互相错位、题面从左边被裁掉一截、代码行号漏到最左边。
///
/// **存比例不存绝对宽度**：列被拉宽或收窄时两栏按同一个比例一起缩放，看着才是一个整体；
/// 存绝对宽度的话，列一变宽全部多出来的空间都堆给右栏。
struct ProportionalSplit<Leading: View, Trailing: View>: View {
    let storageKey: String
    var defaultFraction: Double = 0.5
    var minLeading: CGFloat = 360
    var minTrailing: CGFloat = 380
    @ViewBuilder var leading: () -> Leading
    @ViewBuilder var trailing: () -> Trailing

    @State private var fraction: Double?

    var body: some View {
        GeometryReader { proxy in
            let total = proxy.size.width
            let width = leadingWidth(total: total)
            HStack(spacing: 0) {
                leading()
                    .frame(width: width)
                    .frame(maxHeight: .infinity)

                Rectangle()
                    .fill(AppDesign.ColorToken.separator)
                    .frame(width: 1)
                    .frame(maxHeight: .infinity)
                    .overlay {
                        ColumnResizeHandle(
                            width: width,
                            range: minLeading...max(minLeading, total - minTrailing),
                            growsOnDragRight: true
                        ) { newValue in
                            guard total > 0 else { return }
                            // 夹在 10%–90%：拖到贴边之后列就再也拉不回来了。
                            let next = min(max(Double(newValue / total), 0.1), 0.9)
                            fraction = next
                            UserDefaults.standard.set(next, forKey: storageKey)
                        }
                    }

                trailing()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    /// 比例换算成宽度后仍要夹一次最小宽：窗口很窄时按比例算出来的值会小于任一栏的下限。
    private func leadingWidth(total: CGFloat) -> CGFloat {
        let upper = max(minLeading, total - minTrailing)
        return min(max(total * (fraction ?? storedFraction), minLeading), upper)
    }

    private var storedFraction: Double {
        let stored = UserDefaults.standard.double(forKey: storageKey)
        return stored > 0 ? stored : defaultFraction
    }
}
