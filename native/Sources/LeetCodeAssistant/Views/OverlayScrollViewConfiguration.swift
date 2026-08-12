import AppKit
import QuartzCore
import SwiftUI

/// 将 SwiftUI `ScrollView` 的系统滚动条整体替换为自绘悬浮 thumb：
/// 无轨道、圆角胶囊、滚动时淡入、静止后淡出，视觉对齐 Codex。
struct OverlayScrollViewConfiguration: NSViewRepresentable {
    let axes: Axis.Set
    /// `TextEditor` 自带的 NSScrollView 不是 background 视图的祖先，
    /// 只能在同层子树里找，否则会错误接管外层页面的滚动条。
    let target: ScrollTarget

    init(axes: Axis.Set = .vertical, target: ScrollTarget = .enclosing) {
        self.axes = axes
        self.target = target
    }

    enum ScrollTarget {
        case enclosing
        case embeddedTextView
    }

    func makeNSView(context: Context) -> NSView {
        let view = ScrollAttachmentView(axes: axes, target: target)
        view.configureEnclosingScrollView()
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        guard let view = nsView as? ScrollAttachmentView else { return }
        view.axes = axes
        view.target = target
        view.configureEnclosingScrollView()
    }
}

extension View {
    /// 全项目统一的无轨道悬浮滚动条。SwiftUI `ScrollView` 走
    /// `FloatingScrollIndicatorModifier`（与承载方式无关），见那边的注释。
    func floatingScrollIndicators(_ axes: Axis.Set = .vertical) -> some View {
        modifier(FloatingScrollIndicatorModifier(axes: axes))
    }

    /// `TextEditor` 专用：它内部确实是 NSTextView + NSScrollView，
    /// 且那个 scrollView 不是 background 视图的祖先，只能在同层子树里找。
    func floatingTextScrollIndicators(_ axes: Axis.Set = .vertical) -> some View {
        background {
            OverlayScrollViewConfiguration(axes: axes, target: .embeddedTextView)
                .frame(width: 0, height: 0)
        }
    }
}

private final class ScrollAttachmentView: NSView {
    var axes: Axis.Set
    var target: OverlayScrollViewConfiguration.ScrollTarget
    private weak var configuredScrollView: NSScrollView?

    init(axes: Axis.Set, target: OverlayScrollViewConfiguration.ScrollTarget) {
        self.axes = axes
        self.target = target
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        configureEnclosingScrollView()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        configureEnclosingScrollView()
    }

    private func locateScrollView() -> NSScrollView? {
        switch target {
        case .enclosing:
            return enclosingScrollView
        case .embeddedTextView:
            return superview.flatMap(Self.firstTextScrollView(in:))
        }
    }

    private static func firstTextScrollView(in view: NSView) -> NSScrollView? {
        for subview in view.subviews {
            if let scrollView = subview as? NSScrollView, scrollView.documentView is NSTextView {
                return scrollView
            }
            if let found = firstTextScrollView(in: subview) { return found }
        }
        return nil
    }

    func configureEnclosingScrollView() {
        DispatchQueue.main.async { [weak self] in
            guard let self, let scrollView = self.locateScrollView() else { return }
            scrollView.drawsBackground = false
            scrollView.borderType = .noBorder
            scrollView.autohidesScrollers = true
            scrollView.hasVerticalScroller = false
            scrollView.hasHorizontalScroller = false
            if self.configuredScrollView !== scrollView {
                self.configuredScrollView = scrollView
                FloatingScrollBar.install(on: scrollView)
            }
            FloatingScrollBar.overlay(for: scrollView)?.axes = self.axes
            FloatingScrollBar.overlay(for: scrollView)?.refresh(flash: false)
        }
    }
}

/// 浮在 scrollView 内容之上的自绘滚动条：只画 thumb，不画轨道。
final class FloatingScrollBar: NSView {
    private static let overlays = NSMapTable<NSScrollView, FloatingScrollBar>.weakToWeakObjects()

    private weak var scrollView: NSScrollView?
    private weak var observedDocument: NSView?
    private let verticalThumb = ThumbView()
    private let horizontalThumb = ThumbView()
    private var hideWorkItem: DispatchWorkItem?
    private var stretchResetWorkItem: DispatchWorkItem?
    private var stretchAmount: CGFloat = 0
    private var lastContentOrigin: CGPoint = .zero

    var axes: Axis.Set = .vertical {
        didSet { refresh(flash: false) }
    }

    override var isFlipped: Bool { true }

    static func install(on scrollView: NSScrollView) {
        guard overlays.object(forKey: scrollView) == nil else { return }
        let bar = FloatingScrollBar()
        bar.scrollView = scrollView
        bar.frame = scrollView.bounds
        bar.autoresizingMask = [.width, .height]
        bar.verticalThumb.alphaValue = 0
        bar.horizontalThumb.alphaValue = 0
        bar.addSubview(bar.verticalThumb)
        bar.addSubview(bar.horizontalThumb)
        // 必须真的挂进层级：overlays 是弱引用表，只登记不挂载的话 bar 会当场释放，
        // 于是全 App 既没有系统滚动条（hasVerticalScroller = false）也没有自绘的。
        scrollView.addSubview(bar, positioned: .above, relativeTo: scrollView.contentView)

        scrollView.contentView.postsBoundsChangedNotifications = true
        scrollView.postsFrameChangedNotifications = true
        NotificationCenter.default.addObserver(
            bar, selector: #selector(bar.scrolled),
            name: NSView.boundsDidChangeNotification, object: scrollView.contentView
        )
        NotificationCenter.default.addObserver(
            bar, selector: #selector(bar.resized),
            name: NSView.frameDidChangeNotification, object: scrollView
        )

        bar.lastContentOrigin = scrollView.contentView.bounds.origin
        bar.verticalThumb.usesY = true
        bar.horizontalThumb.usesY = false
        bar.verticalThumb.onDrag = { [weak bar] delta in bar?.dragVertical(delta) }
        bar.horizontalThumb.onDrag = { [weak bar] delta in bar?.dragHorizontal(delta) }
        bar.attachDocumentObserver()

        overlays.setObject(bar, forKey: scrollView)
    }

    /// 内容尺寸变化（documentView frame）时重算 thumb 长度，
    /// 避免内容增长后 thumb 仍按旧的较小高度比例绘制得过长。
    private func attachDocumentObserver() {
        guard let scrollView, let document = scrollView.documentView, document !== observedDocument else { return }
        observedDocument = document
        document.postsFrameChangedNotifications = true
        NotificationCenter.default.addObserver(
            self, selector: #selector(resized),
            name: NSView.frameDidChangeNotification, object: document
        )
    }

    static func overlay(for scrollView: NSScrollView) -> FloatingScrollBar? {
        overlays.object(forKey: scrollView)
    }

    @objc private func scrolled() {
        let origin = scrollView?.contentView.bounds.origin ?? .zero
        let delta = hypot(origin.x - lastContentOrigin.x, origin.y - lastContentOrigin.y)
        lastContentOrigin = origin
        // 弹性动效：滚动时 thumb 真实加长（不是 layer 缩放，短胶囊被纵向 scale
        // 会把两端拉成尖的椭圆），静止后带缓动地收回。
        stretchAmount = min(44, stretchAmount * 0.4 + delta * 0.55)
        layoutThumbs()
        stretchResetWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.stretchAmount = 0
            self.layoutThumbs(animated: true)
        }
        stretchResetWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.16, execute: work)
        refresh(flash: true)
    }

    @objc private func resized() {
        refresh(flash: false)
    }

    func refresh(flash: Bool) {
        attachDocumentObserver()
        layoutThumbs()
        if flash { reveal() }
    }

    private func layoutThumbs(animated: Bool = false) {
        guard let scrollView, let document = scrollView.documentView else {
            verticalThumb.isHidden = true
            horizontalThumb.isHidden = true
            return
        }
        let visible = scrollView.contentView.bounds
        let doc = document.bounds
        var verticalFrame = verticalThumb.frame
        var horizontalFrame = horizontalThumb.frame
        var showVertical = false
        var showHorizontal = false

        if axes.contains(.vertical), doc.height > visible.height, visible.height > 0 {
            let inset: CGFloat = 6
            let trackHeight = bounds.height - inset * 2
            let thumbHeight = min(trackHeight, max(32, trackHeight * visible.height / doc.height) + stretchAmount)
            let maxOffset = doc.height - visible.height
            let offset = min(max(visible.origin.y - doc.origin.y, 0), maxOffset)
            let y = inset + (trackHeight - thumbHeight) * (offset / maxOffset)
            verticalFrame = CGRect(x: bounds.width - 10, y: y, width: 6, height: thumbHeight)
            showVertical = true
        }

        if axes.contains(.horizontal), doc.width > visible.width, visible.width > 0 {
            let inset: CGFloat = 6
            let trackWidth = bounds.width - inset * 2
            let thumbWidth = min(trackWidth, max(32, trackWidth * visible.width / doc.width) + stretchAmount)
            let maxOffset = doc.width - visible.width
            let offset = min(max(visible.origin.x - doc.origin.x, 0), maxOffset)
            let x = inset + (trackWidth - thumbWidth) * (offset / maxOffset)
            horizontalFrame = CGRect(x: x, y: bounds.height - 10, width: thumbWidth, height: 6)
            showHorizontal = true
        }

        verticalThumb.isHidden = !showVertical
        horizontalThumb.isHidden = !showHorizontal
        guard animated else {
            verticalThumb.frame = verticalFrame
            horizontalThumb.frame = horizontalFrame
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.35
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.3, 1.15)
            if showVertical { verticalThumb.animator().frame = verticalFrame }
            if showHorizontal { horizontalThumb.animator().frame = horizontalFrame }
        }
    }

    private func reveal() {
        hideWorkItem?.cancel()
        for thumb in [verticalThumb, horizontalThumb] where !thumb.isHidden {
            thumb.animator().alphaValue = 1
        }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.4
                self.verticalThumb.animator().alphaValue = 0
                self.horizontalThumb.animator().alphaValue = 0
            }
        }
        hideWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8, execute: work)
    }

    private func dragVertical(_ delta: CGFloat) {
        guard let scrollView, let document = scrollView.documentView else { return }
        let visible = scrollView.contentView.bounds
        let doc = document.bounds
        guard doc.height > visible.height else { return }
        let inset: CGFloat = 6
        let trackHeight = bounds.height - inset * 2
        let thumbHeight = max(32, trackHeight * visible.height / doc.height)
        let maxOffset = doc.height - visible.height
        let current = visible.origin.y - doc.origin.y
        let next = min(max(current + delta / (trackHeight - thumbHeight) * maxOffset, 0), maxOffset)
        scrollView.contentView.scroll(to: NSPoint(x: visible.origin.x, y: doc.origin.y + next))
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    private func dragHorizontal(_ delta: CGFloat) {
        guard let scrollView, let document = scrollView.documentView else { return }
        let visible = scrollView.contentView.bounds
        let doc = document.bounds
        guard doc.width > visible.width else { return }
        let inset: CGFloat = 6
        let trackWidth = bounds.width - inset * 2
        let thumbWidth = max(32, trackWidth * visible.width / doc.width)
        let maxOffset = doc.width - visible.width
        let current = visible.origin.x - doc.origin.x
        let next = min(max(current + delta / (trackWidth - thumbWidth) * maxOffset, 0), maxOffset)
        scrollView.contentView.scroll(to: NSPoint(x: doc.origin.x + next, y: visible.origin.y))
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        return (hit === verticalThumb || hit === horizontalThumb) ? hit : nil
    }
}

private final class ThumbView: NSView {
    var onDrag: ((CGFloat) -> Void)?
    var usesY = false
    private var lastPoint: NSPoint?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func draw(_ dirtyRect: NSRect) {
        // 两端必须是正圆胶囊：yRadius 取宽度的一半（之前误用高度的一半，
        // 画出来是椭圆，thumb 两端发尖）。
        let radius = min(bounds.width, bounds.height) / 2
        let path = NSBezierPath(
            roundedRect: bounds,
            xRadius: radius,
            yRadius: radius
        )
        NSColor.systemGray.withAlphaComponent(0.45).setFill()
        path.fill()
    }

    override func mouseDown(with event: NSEvent) {
        lastPoint = convert(event.locationInWindow, from: nil)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let last = lastPoint else { return }
        let point = convert(event.locationInWindow, from: nil)
        onDrag?(usesY ? point.y - last.y : point.x - last.x)
        lastPoint = point
    }

    override func mouseUp(with event: NSEvent) {
        lastPoint = nil
    }
}

/// AppKit 托管的滚动容器（List、TextEditor、NSTableView 等）不走 SwiftUI 的
/// `.scrollIndicators(.hidden)`；系统设置为"始终显示滚动条"时就会露出带轨道的
/// 旧式 NSScroller。窗口级兜底：遍历视图树，关掉原生 scroller 并装上悬浮 thumb。
/// SwiftUI 自己的 ScrollView 不是 NSScrollView 承载，不受影响。
@MainActor
enum AppKitScrollNormalizer {
    static func normalize(window: NSWindow?) {
        guard let root = window?.contentView else { return }
        normalize(view: root)
    }

    private static func normalize(view: NSView) {
        if let scrollView = view as? NSScrollView {
            apply(to: scrollView)
        }
        for child in view.subviews {
            normalize(view: child)
        }
    }

    private static func apply(to scrollView: NSScrollView) {
        // 只关原生 scroller，不装自绘 bar：这些表面都挂了
        // FloatingScrollIndicatorModifier，它自己画悬浮 thumb；
        // 这里再装一条就会和 modifier 的叠出重影。
        // TextEditor 等显式走 floatingTextScrollIndicators 的，
        // 由 OverlayScrollViewConfiguration 自己 install，不经过这里。
        guard scrollView.hasVerticalScroller || scrollView.hasHorizontalScroller else { return }
        scrollView.hasVerticalScroller = false
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
    }
}
