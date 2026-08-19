import AppKit
import SwiftUI

/// 全项目统一的滚动条：无轨道、无边框的悬浮胶囊，可拖动。
/// 弹性动效：滚动时 thumb 沿滚动方向拉伸、略微变粗，静止后弹簧回弹并淡出。
///
/// **拖动为什么走 `ScrollPosition` 而不是 NSScrollView**：原实现先取
/// `background` 里那个 NSView 的 `enclosingScrollView` 再直写 bounds。但那个
/// 视图是 ScrollView 的**背景兄弟节点**，不是它的后代——`enclosingScrollView`
/// 往上找只会找到外层（通常为 nil），于是 `guard` 当场返回，全 App 的 thumb
/// 都拖不动（对话页能拖是因为它滚的是 WKWebView，走 JS 那套自绘滚动条）。
/// `ScrollPosition.scrollTo(point:)` 直接由 SwiftUI 定位，与承载方式无关。
struct FloatingScrollIndicatorModifier: ViewModifier {
    let axes: Axis.Set

    @State private var metrics = ScrollMetrics()
    @State private var isActive = false
    @State private var stretch: CGFloat = 0
    @State private var idleTask: Task<Void, Never>?
    @State private var lastActivity = Date.distantPast
    @State private var scrollPosition = ScrollPosition()
    @State private var dragStartOffset: CGPoint?

    func body(content: Content) -> some View {
        content
            // 关掉系统指示器，避免和我们的胶囊叠在一起画两条。
            // 必须是 `.never`：`.hidden` 只是"这一轮别画"，SwiftUI 仍会在
            // HostingScrollView 上把 hasVerticalScroller 打开——系统滚动条是
            // legacy 样式（接了鼠标或设为"始终显示"）时，那就是一条 17pt 实心
            // 滚动条盖在我们的胶囊上，直到窗口级兜底把它关掉才消失。
            .scrollIndicators(.never)
            .scrollPosition($scrollPosition)
            .onScrollGeometryChange(for: ScrollMetrics.self) { geometry in
                ScrollMetrics(
                    offset: geometry.contentOffset,
                    contentSize: geometry.contentSize,
                    containerSize: geometry.containerSize,
                    insets: geometry.contentInsets
                )
            } action: { oldValue, newValue in
                let delta = hypot(
                    newValue.offset.x - oldValue.offset.x,
                    newValue.offset.y - oldValue.offset.y
                )
                metrics = newValue
                // 列宽变化也会打到这里（容器尺寸变了），但那不是"用户在滚动"。
                // 不拦住的话，拖分栏线时两边会莫名冒出滚动条，还跟着列宽一路挪。
                guard delta > 0.5 else { return }
                reveal(delta: delta)
            }
            .overlay(alignment: .topLeading) { thumbs }
    }

    @ViewBuilder
    private var thumbs: some View {
        GeometryReader { proxy in
            ZStack(alignment: .topLeading) {
                if axes.contains(.vertical), let bar = metrics.verticalBar(in: proxy.size, extra: stretch) {
                    thumb(width: FloatingScrollIndicator.thickness + min(2, stretch / 20), height: bar.length)
                        .offset(x: proxy.size.width - FloatingScrollIndicator.thickness - FloatingScrollIndicator.edgeInset - min(2, stretch / 20), y: bar.origin)
                        .gesture(dragGesture(vertical: true, proxySize: proxy.size))
                }
                if axes.contains(.horizontal), let bar = metrics.horizontalBar(in: proxy.size, extra: stretch) {
                    thumb(width: bar.length, height: FloatingScrollIndicator.thickness + min(2, stretch / 20))
                        .offset(x: bar.origin, y: proxy.size.height - FloatingScrollIndicator.thickness - FloatingScrollIndicator.edgeInset - min(2, stretch / 20))
                        .gesture(dragGesture(vertical: false, proxySize: proxy.size))
                }
            }
        }
    }

    private func thumb(width: CGFloat, height: CGFloat) -> some View {
        Capsule(style: .continuous)
            .fill(Color.secondary.opacity(0.42))
            .frame(width: width, height: height)
            .opacity(isActive ? 1 : 0)
            .contentShape(Capsule().inset(by: -4))
    }

    private func dragGesture(vertical: Bool, proxySize: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                let start = dragStartOffset ?? metrics.offset
                if dragStartOffset == nil { dragStartOffset = start }
                guard let target = metrics.offset(
                    draggingFrom: start,
                    by: vertical ? value.translation.height : value.translation.width,
                    vertical: vertical,
                    in: proxySize
                ) else { return }

                // 拖动是直接定位，不能带动画：带上就会在手指后面追，松手还要再滑一段。
                var transaction = Transaction(animation: nil)
                transaction.disablesAnimations = true
                withTransaction(transaction) { scrollPosition.scrollTo(point: target) }
                reveal(delta: 0)
            }
            .onEnded { _ in dragStartOffset = nil }
    }

    private func reveal(delta: CGFloat) {
        lastActivity = .now
        if !isActive {
            withAnimation(.easeOut(duration: 0.12)) { isActive = true }
        }
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            stretch = min(FloatingScrollIndicator.maximumStretch, stretch * 0.4 + delta * 0.55)
        }
        guard idleTask == nil else { return }
        idleTask = Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(160))
                guard !Task.isCancelled else { break }
                let idleDuration = Date.now.timeIntervalSince(lastActivity)
                if idleDuration >= 0.16, stretch != 0 {
                    withAnimation(.easeOut(duration: 0.2)) { stretch = 0 }
                }
                guard idleDuration >= 0.9 else { continue }
                withAnimation(.easeOut(duration: 0.25)) { isActive = false }
                break
            }
            idleTask = nil
        }
    }
}

enum FloatingScrollIndicator {
    static let thickness: CGFloat = 6
    static let edgeInset: CGFloat = 4
    static let trackInset: CGFloat = 6
    static let minimumLength: CGFloat = 28
    static let maximumStretch: CGFloat = 44

    /// 由内容/视口尺寸推算 thumb 的长度与位置。抽成纯函数是为了能单测，
    /// 也保证横竖两个方向用同一套算法。`extra` 是滚动时的弹性拉伸量。
    static func bar(
        offset: CGFloat,
        contentLength: CGFloat,
        containerLength: CGFloat,
        extra: CGFloat = 0
    ) -> (origin: CGFloat, length: CGFloat)? {
        guard containerLength > 0, contentLength > containerLength + 0.5 else { return nil }
        let track = containerLength - trackInset * 2
        guard track > minimumLength else { return nil }
        let length = max(minimumLength, track * containerLength / contentLength)
        let scrollable = contentLength - containerLength
        let progress = min(max(offset / scrollable, 0), 1)
        let origin = trackInset + (track - length) * progress
        guard extra > 0 else { return (origin, length) }
        let stretched = min(length + extra, track)
        let clampedOrigin = min(origin, trackInset + track - stretched)
        return (clampedOrigin, stretched)
    }

    /// 把 thumb 在轨道上走过的距离换算成内容要滚多远。thumb 长度必须和 `bar`
    /// 用同一个公式，否则手指和 thumb 会越拖越分家。入参与返回都在"条形坐标"里
    /// （顶端为 0），insets 的换算由调用方完成。
    static func dragTarget(
        start: CGFloat,
        translation: CGFloat,
        contentLength: CGFloat,
        containerLength: CGFloat
    ) -> CGFloat? {
        guard containerLength > 0, contentLength > containerLength + 0.5 else { return nil }
        let track = containerLength - trackInset * 2
        guard track > minimumLength else { return nil }
        let length = max(minimumLength, track * containerLength / contentLength)
        let travel = track - length
        guard travel > 0.5 else { return nil }
        let scrollable = contentLength - containerLength
        return min(max(start + translation * scrollable / travel, 0), scrollable)
    }
}

private struct ScrollMetrics: Equatable {
    var offset = CGPoint.zero
    var contentSize = CGSize.zero
    var containerSize = CGSize.zero
    var insets = EdgeInsets()

    func verticalBar(in size: CGSize, extra: CGFloat = 0) -> (origin: CGFloat, length: CGFloat)? {
        FloatingScrollIndicator.bar(
            offset: offset.y + insets.top,
            contentLength: contentSize.height + insets.top + insets.bottom,
            containerLength: size.height,
            extra: extra
        )
    }

    func horizontalBar(in size: CGSize, extra: CGFloat = 0) -> (origin: CGFloat, length: CGFloat)? {
        FloatingScrollIndicator.bar(
            offset: offset.x + insets.leading,
            contentLength: contentSize.width + insets.leading + insets.trailing,
            containerLength: size.width,
            extra: extra
        )
    }

    /// 拖动 thumb 时的目标 contentOffset。`start` 是按下那一刻的 contentOffset，
    /// 换进条形坐标算完再换回来——`scrollTo(point:)` 收的是 contentOffset。
    func offset(draggingFrom start: CGPoint, by translation: CGFloat, vertical: Bool, in size: CGSize) -> CGPoint? {
        if vertical {
            guard let value = FloatingScrollIndicator.dragTarget(
                start: start.y + insets.top,
                translation: translation,
                contentLength: contentSize.height + insets.top + insets.bottom,
                containerLength: size.height
            ) else { return nil }
            return CGPoint(x: offset.x, y: value - insets.top)
        }
        guard let value = FloatingScrollIndicator.dragTarget(
            start: start.x + insets.leading,
            translation: translation,
            contentLength: contentSize.width + insets.leading + insets.trailing,
            containerLength: size.width
        ) else { return nil }
        return CGPoint(x: value - insets.leading, y: offset.y)
    }
}
