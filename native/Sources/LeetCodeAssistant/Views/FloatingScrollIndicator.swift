import AppKit
import SwiftUI

/// 全项目统一的滚动条：无轨道、无边框的悬浮胶囊，可拖动。
/// 弹性动效：滚动时 thumb 沿滚动方向拉伸、略微变粗，静止后弹簧回弹并淡出。
///
/// **为什么不是纯 overlay**：thumb 必须能抓住拖动。捕获承载视图后优先直写
/// NSScrollView 的 bounds（当前系统 SwiftUI ScrollView 由其承载）；拿不到时
/// 退化为合成 scrollWheel 事件，两种承载都能滚。
struct FloatingScrollIndicatorModifier: ViewModifier {
    let axes: Axis.Set

    @State private var metrics = ScrollMetrics()
    @State private var isActive = false
    @State private var stretch: CGFloat = 0
    @State private var idleTask: Task<Void, Never>?
    @State private var lastActivity = Date.distantPast
    @State private var hostView: NSView?
    @State private var dragStartOrigin: CGPoint?

    func body(content: Content) -> some View {
        content
            // 关掉系统指示器，避免和我们的胶囊叠在一起画两条。
            .scrollIndicators(.hidden)
            .background { ScrollHostCapture { hostView = $0 } }
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
                guard let scrollView = hostView?.enclosingScrollView else { return }
                let document = scrollView.documentView?.bounds ?? .zero
                let visible = scrollView.contentView.bounds
                if dragStartOrigin == nil { dragStartOrigin = visible.origin }
                guard let start = dragStartOrigin else { return }

                let containerLength = vertical ? scrollView.bounds.height : scrollView.bounds.width
                let contentLength = vertical ? document.height : document.width
                let visibleLength = vertical ? visible.height : visible.width
                let scrollable = contentLength - visibleLength
                let track = containerLength - FloatingScrollIndicator.trackInset * 2
                let thumbLength = min(track, max(FloatingScrollIndicator.minimumLength, track * visibleLength / max(1, contentLength)))
                guard scrollable > 0, track > thumbLength else { return }

                let translation = vertical ? value.translation.height : value.translation.width
                let delta = translation * scrollable / (track - thumbLength)
                var origin = visible.origin
                if vertical {
                    origin.y = min(max(start.y + delta, 0), scrollable)
                } else {
                    origin.x = min(max(start.x + delta, 0), scrollable)
                }
                scrollView.contentView.bounds.origin = origin
                scrollView.reflectScrolledClipView(scrollView.contentView)
            }
            .onEnded { _ in dragStartOrigin = nil }
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

private struct ScrollHostCapture: NSViewRepresentable {
    let onResolve: (NSView) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { onResolve(view) }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
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
}
