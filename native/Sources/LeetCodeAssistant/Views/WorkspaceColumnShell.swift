import AppKit
import SwiftUI

/// SwiftUI three-column shell. Not `NavigationSplitView`, not `NSSplitView`.
///
/// 每一列都是「外层裁剪框 + 内层内容」两层，**动画期间两层同宽**。
///
/// 曾经的做法是内层一步到位、只让外层补间，为的是别让 WKWebView 逐帧重排。
/// 代价是看着不像一个整体：点收起，中间列瞬间就是最终宽度了，侧栏才慢慢滑走，
/// 像侧栏盖在中间列上面。所以改回锁步——中间列展开与侧栏收起同时发生。
///
/// 逐帧重排的老问题用另外两招压住：动画从 0.22s 收到 0.18s；
/// 收起到很窄时内容宽度不再继续跟到 0，而是停在 `collapsedContentFloor`，
/// 避免把 0 宽度交给 WKWebView（那一下会把滚动位置和播放中的视频弄丢）。
///
/// 动画结束后，收起的列把内容宽度还原到最后一个正宽度并停在那儿（外层仍裁到 0），
/// 这样第三列放大再还原时，会话页面原样还在。
/// 收起过程中内容宽度的下限。再窄就不跟了——0 宽度的 WKWebView 重排会丢滚动位置，
/// 而这一段本来也几乎看不见（外层已经裁到比它还窄）。
/// 放在类型外：泛型类型里不能有 static 存储属性。
private let workspaceCollapsedContentFloor: CGFloat = 200

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
    /// 开合动画是否正在进行。只有这段时间内容宽度才跟着裁剪框走。
    @State private var isAnimatingColumns = false
    @State private var settleTask: Task<Void, Never>?


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
            let content = contentWidths(for: widths)

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
                // 中间列这边再出一条对称的抓取带。分栏线两侧各 8pt，合起来 16pt。
                // 不用一条 16pt 的带子横跨过去：越出列边界的那一半会被相邻列里的
                // WKWebView（真 AppKit 视图）挡住，点不着——每列自己的那半才稳。
                .overlay(alignment: .leading) {
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
                    if inspectorVisible && !inspectorExpanded {
                        ColumnResizeHandle(
                            width: inspectorWidth,
                            range: WorkspaceSplitLayoutPolicy.inspectorMin...WorkspaceSplitLayoutPolicy.inspectorMax(
                                total: proxy.size.width,
                                sidebarWidth: widths.sidebar
                            ),
                            growsOnDragRight: false,
                            onChange: onInspectorWidth
                        )
                    }
                }

                column(visible: widths.inspector, content: content.inspector, reveal: .trailing) {
                    inspector()
                }
                .overlay(alignment: .leading) {
                    if inspectorVisible && !inspectorExpanded {
                        ZStack(alignment: .leading) {
                            ColumnResizeHandle(
                                width: inspectorWidth,
                                range: WorkspaceSplitLayoutPolicy.inspectorMin...WorkspaceSplitLayoutPolicy.inspectorMax(
                                total: proxy.size.width,
                                sidebarWidth: widths.sidebar
                            ),
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
            .onChange(of: transitions) { _, _ in beginColumnAnimation() }
            .onAppear { restingWidths = widths.restingWidths(previous: restingWidths) }
            .onDisappear { settleTask?.cancel() }
        }
        .background(AppDesign.ColorToken.canvas)
    }

    /// 动画期间内容跟着裁剪框走（锁步）；静止时收起的列回落到最后一个正宽度。
    private func contentWidths(for widths: WorkspaceColumnWidths) -> WorkspaceColumnWidths {
        guard isAnimatingColumns else { return widths.contentWidths(fallingBackTo: restingWidths) }
        let floor = workspaceCollapsedContentFloor
        return WorkspaceColumnWidths(
            sidebar: max(widths.sidebar, min(floor, restingWidths.sidebar)),
            detail: max(widths.detail, min(floor, restingWidths.detail)),
            inspector: max(widths.inspector, min(floor, restingWidths.inspector))
        )
    }

    /// 开合开始时进入锁步，一个动画时长之后退出。
    /// 退出这一下会把收起的列的内容宽度从 floor 还原到 resting——必须不带动画，
    /// 否则动画刚停又起一段。
    private func beginColumnAnimation() {
        isAnimatingColumns = true
        settleTask?.cancel()
        settleTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(AppDesign.Motion.panelTransitionDuration))
            guard !Task.isCancelled else { return }
            var transaction = Transaction(animation: nil)
            transaction.disablesAnimations = true
            withTransaction(transaction) { isAnimatingColumns = false }
        }
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

    /// 单侧抓取带宽度。分栏线两侧各挂一条，实际可拖范围是 16pt。
    /// 原来只有贴着第三列内侧的 6pt，指针得先瞄准才拖得动。
    static let thickness: CGFloat = 8

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: ColumnResizeHandleView, context: Context) -> CGSize? {
        CGSize(width: Self.thickness, height: proposal.height ?? nsView.bounds.height)
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
