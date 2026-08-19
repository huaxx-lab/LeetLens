import AppKit
import SwiftUI

/// SwiftUI three-column shell. Not `NavigationSplitView`, not `NSSplitView`.
///
/// 每一列都是「外层裁剪框 + 内层固定宽度内容」两层：
/// **外层**的宽度参与动画（展开/收起时补间），**内层**一步到位落到目标宽度。
/// 这是当初把动画整个关掉的那个坑的正解——中间列和第三列里装的是 WKWebView，
/// 让它跟着补间宽度走等于每帧重排一次网页，滚动位置乱跳、播放中的视频还会卡住；
/// 现在网页只在动画开始时排一次，动画本身只是把它裁出来/裁回去。
///
/// 收起的列不卸载、也不把内容宽度压成 0（那等于再重排两次），
/// 而是保持最后一个正宽度，外层裁到 0——第三列放大再还原时，会话页面原样还在。
struct WorkspaceColumnShell<Sidebar: View, Detail: View, Inspector: View>: View {
    var sidebarVisible: Bool
    var inspectorVisible: Bool
    var inspectorExpanded: Bool
    var sidebarWidth: CGFloat
    var inspectorWidth: CGFloat
    var onSidebarWidth: (CGFloat) -> Void
    var onInspectorWidth: (CGFloat) -> Void
    @ViewBuilder var sidebar: () -> Sidebar
    @ViewBuilder var detail: () -> Detail
    @ViewBuilder var inspector: () -> Inspector

    @State private var restingWidths = WorkspaceColumnWidths(sidebar: 0, detail: 0, inspector: 0)

    var body: some View {
        GeometryReader { proxy in
            let widths = WorkspaceSplitLayoutPolicy.columnWidths(
                total: proxy.size.width,
                sidebarVisible: sidebarVisible,
                sidebarWidth: sidebarWidth,
                inspectorVisible: inspectorVisible,
                inspectorExpanded: inspectorExpanded,
                inspectorWidth: inspectorWidth
            )
            let content = widths.contentWidths(fallingBackTo: restingWidths)

            HStack(spacing: 0) {
                column(visible: widths.sidebar, content: content.sidebar, reveal: .trailing) {
                    sidebar()
                }
                .overlay(alignment: .trailing) {
                    if sidebarVisible {
                        ColumnResizeHandle(
                            width: sidebarWidth,
                            range: WorkspaceSplitLayoutPolicy.sidebarMin...WorkspaceSplitLayoutPolicy.sidebarMax,
                            growsOnDragRight: true,
                            onChange: onSidebarWidth
                        )
                    }
                }
                .overlay(alignment: .trailing) {
                    if sidebarVisible { ColumnHairline() }
                }

                column(visible: widths.detail, content: content.detail, reveal: .leading) {
                    detail()
                }

                column(visible: widths.inspector, content: content.inspector, reveal: .trailing) {
                    inspector()
                }
                .overlay(alignment: .leading) {
                    if inspectorVisible && !inspectorExpanded {
                        ZStack(alignment: .leading) {
                            ColumnResizeHandle(
                                width: inspectorWidth,
                                range: WorkspaceSplitLayoutPolicy.inspectorMin...WorkspaceSplitLayoutPolicy.inspectorMax,
                                growsOnDragRight: false,
                                onChange: onInspectorWidth
                            )
                            ColumnHairline()
                        }
                    }
                }
            }
            // 只有显隐/放大这三个开关变化时才补间。拖分栏线改的是宽度本身，
            // 挂上动画就会跟不上指针——那时要的是一比一跟手。
            .animation(AppDesign.Motion.panelTransition, value: transitions)
            .onChange(of: widths) { _, new in restingWidths = new.restingWidths(previous: restingWidths) }
            .onAppear { restingWidths = widths.restingWidths(previous: restingWidths) }
        }
        .background(AppDesign.ColorToken.canvas)
    }

    private var transitions: WorkspaceColumnTransitions {
        WorkspaceColumnTransitions(
            sidebar: sidebarVisible,
            inspector: inspectorVisible,
            expanded: inspectorExpanded
        )
    }

    /// 外层按 `visible` 裁剪（参与动画），内层固定在 `content`（不参与动画）。
    /// `reveal` 决定内容贴哪一边：贴住"要出现的那条边"，动画才像列从边上推进来。
    @ViewBuilder
    private func column<Content: View>(
        visible: CGFloat,
        content: CGFloat,
        reveal: Alignment,
        @ViewBuilder body: () -> Content
    ) -> some View {
        body()
            .frame(width: content)
            .frame(maxHeight: .infinity)
            .animation(nil, value: content)
            .frame(width: visible, alignment: reveal)
            .clipped()
            // `.clipped()` 只裁画面不裁命中：不加这一句，收起的列还会在原地吃掉点击。
            .contentShape(Rectangle())
    }
}

/// 三列各自的宽度。抽成值类型是为了能单测，也让动画有一个明确的比较对象。
struct WorkspaceColumnWidths: Equatable {
    var sidebar: CGFloat
    var detail: CGFloat
    var inspector: CGFloat

    /// 内容排版用的宽度：列还在就用它自己的宽度，收起了就沿用最后一个正宽度。
    func contentWidths(fallingBackTo resting: WorkspaceColumnWidths) -> WorkspaceColumnWidths {
        WorkspaceColumnWidths(
            sidebar: sidebar > 0 ? sidebar : resting.sidebar,
            detail: detail > 0 ? detail : resting.detail,
            inspector: inspector > 0 ? inspector : resting.inspector
        )
    }

    /// 记账用：只记正宽度，0 不覆盖旧值。
    func restingWidths(previous: WorkspaceColumnWidths) -> WorkspaceColumnWidths {
        WorkspaceColumnWidths(
            sidebar: sidebar > 0 ? sidebar : previous.sidebar,
            detail: detail > 0 ? detail : previous.detail,
            inspector: inspector > 0 ? inspector : previous.inspector
        )
    }
}

private struct WorkspaceColumnTransitions: Equatable {
    var sidebar: Bool
    var inspector: Bool
    var expanded: Bool
}

/// 列与列之间的发丝线：系统分隔色，不是实心黑边。
private struct ColumnHairline: View {
    var body: some View {
        Rectangle()
            .fill(AppDesign.ColorToken.separator)
            .frame(width: 1)
            .allowsHitTesting(false)
    }
}

/// Invisible 6pt drag strip. AppKit owns the pointer so the titlebar region
/// cannot steal `mouseDown` and start a window move.
struct ColumnResizeHandle: NSViewRepresentable {
    var width: CGFloat
    var range: ClosedRange<CGFloat>
    var growsOnDragRight: Bool
    var onChange: (CGFloat) -> Void

    func makeNSView(context: Context) -> ColumnResizeHandleView {
        let view = ColumnResizeHandleView()
        apply(to: view)
        return view
    }

    func updateNSView(_ view: ColumnResizeHandleView, context: Context) {
        apply(to: view)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: ColumnResizeHandleView, context: Context) -> CGSize? {
        CGSize(width: 6, height: proposal.height ?? nsView.bounds.height)
    }

    private func apply(to view: ColumnResizeHandleView) {
        view.currentWidth = width
        view.range = range
        view.growsOnDragRight = growsOnDragRight
        view.onChange = onChange
    }
}

final class ColumnResizeHandleView: NSView {
    var currentWidth: CGFloat = 0
    var range: ClosedRange<CGFloat> = 0...1
    var growsOnDragRight = true
    var onChange: ((CGFloat) -> Void)?

    private var dragOriginWidth: CGFloat = 0
    private var dragOriginX: CGFloat = 0

    override var mouseDownCanMoveWindow: Bool { false }
    override var isOpaque: Bool { false }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .resizeLeftRight)
    }

    override func mouseDown(with event: NSEvent) {
        dragOriginWidth = currentWidth
        dragOriginX = event.locationInWindow.x
        window?.isMovable = false
    }

    override func mouseDragged(with event: NSEvent) {
        let delta = event.locationInWindow.x - dragOriginX
        let raw = growsOnDragRight ? dragOriginWidth + delta : dragOriginWidth - delta
        let clamped = min(max(raw.rounded(), range.lowerBound), range.upperBound)
        onChange?(clamped)
    }

    override func mouseUp(with event: NSEvent) {
        window?.isMovable = true
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        window?.isMovable = true
        super.viewWillMove(toWindow: newWindow)
    }
}
