import SwiftUI

/// 浮窗在容器里的位置与大小。按容器**比例**存：窗口缩放、分栏拖动之后，
/// 浮窗仍落在同一个相对位置，而不是被挤出界或者缩在角落里。
struct FloatingPanelPlacement: Codable, Equatable, Sendable {
    var x: Double
    var y: Double
    var width: Double
    var height: Double
}

enum FloatingPanelLayout {
    static let margin: CGFloat = 10
    static let minimumSize = CGSize(width: 320, height: 300)

    /// 默认停靠在容器左侧（刷题页就是题面那一栏），宽度取容器四成、夹在 360–560。
    static func defaultFrame(in container: CGSize) -> CGRect {
        let width = min(max(container.width * 0.4, 360), 560)
        return clamp(
            CGRect(x: margin, y: margin, width: width, height: container.height - margin * 2),
            in: container
        )
    }

    static func frame(for placement: FloatingPanelPlacement?, in container: CGSize) -> CGRect {
        guard let placement, container.width > 0, container.height > 0 else {
            return defaultFrame(in: container)
        }
        return clamp(
            CGRect(
                x: placement.x * container.width,
                y: placement.y * container.height,
                width: placement.width * container.width,
                height: placement.height * container.height
            ),
            in: container
        )
    }

    static func placement(for frame: CGRect, in container: CGSize) -> FloatingPanelPlacement? {
        guard container.width > 0, container.height > 0 else { return nil }
        return FloatingPanelPlacement(
            x: frame.minX / container.width,
            y: frame.minY / container.height,
            width: frame.width / container.width,
            height: frame.height / container.height
        )
    }

    /// 尺寸先夹到 [最小, 容器 − 边距]，再把位置夹进容器：拖到边上时贴边停住，不会拖丢。
    static func clamp(_ frame: CGRect, in container: CGSize) -> CGRect {
        let maxWidth = max(minimumSize.width, container.width - margin * 2)
        let maxHeight = max(minimumSize.height, container.height - margin * 2)
        let width = min(max(frame.width, minimumSize.width), maxWidth)
        let height = min(max(frame.height, minimumSize.height), maxHeight)
        let x = min(max(frame.minX, margin), max(margin, container.width - margin - width))
        let y = min(max(frame.minY, margin), max(margin, container.height - margin - height))
        return CGRect(x: x, y: y, width: width, height: height)
    }
}

/// 可拖动、可缩放的页内浮窗。拖动交给内容自己决定挂在哪（通常是标题栏），
/// 缩放是右下角一枚把手。位置按 `storageKey` 记住。
struct FloatingPanelHost<Content: View>: View {
    let storageKey: String
    @ViewBuilder let content: (_ moveGesture: AnyGesture<DragGesture.Value>) -> Content

    @State private var placement: FloatingPanelPlacement?
    @State private var liveFrame: CGRect?
    @State private var loaded = false

    var body: some View {
        GeometryReader { proxy in
            let container = proxy.size
            let resting = FloatingPanelLayout.frame(for: placement, in: container)
            let frame = liveFrame ?? resting

            content(moveGesture(from: resting, container: container))
                .frame(width: frame.width, height: frame.height)
                .overlay(alignment: .bottomTrailing) {
                    resizeGrip(from: resting, container: container)
                }
                .position(x: frame.midX, y: frame.midY)
        }
        .onAppear(perform: load)
    }

    private func moveGesture(from resting: CGRect, container: CGSize) -> AnyGesture<DragGesture.Value> {
        // 全局坐标：浮窗跟着手指在动，局部坐标系会一起动，位移会抖。
        AnyGesture(
            DragGesture(minimumDistance: 3, coordinateSpace: .global)
                .onChanged { value in
                    liveFrame = FloatingPanelLayout.clamp(
                        resting.offsetBy(dx: value.translation.width, dy: value.translation.height),
                        in: container
                    )
                }
                .onEnded { _ in commit(container: container) }
        )
    }

    private func resizeGrip(from resting: CGRect, container: CGSize) -> some View {
        Image(systemName: "arrow.up.left.and.arrow.down.right")
            .font(.appScaled(size: 8, weight: .semibold))
            .foregroundStyle(.tertiary)
            .frame(width: 18, height: 18)
            .contentShape(Rectangle())
            .padding(2)
            .pointerStyle(.frameResize(position: .bottomTrailing))
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { value in
                        var next = resting
                        next.size.width += value.translation.width
                        next.size.height += value.translation.height
                        // 缩放只动右下角，左上角钉住：先夹尺寸，再按原点夹。
                        let clamped = FloatingPanelLayout.clamp(next, in: container)
                        liveFrame = CGRect(
                            origin: resting.origin,
                            size: CGSize(
                                width: min(clamped.width, container.width - FloatingPanelLayout.margin - resting.minX),
                                height: min(clamped.height, container.height - FloatingPanelLayout.margin - resting.minY)
                            )
                        )
                    }
                    .onEnded { _ in commit(container: container) }
            )
            .help("拖动调整大小")
    }

    private func commit(container: CGSize) {
        guard let liveFrame else { return }
        placement = FloatingPanelLayout.placement(for: liveFrame, in: container)
        self.liveFrame = nil
        if let placement, let data = try? JSONEncoder().encode(placement) {
            UserDefaults.standard.set(data, forKey: storageKey)
        }
    }

    private func load() {
        guard !loaded else { return }
        loaded = true
        if let data = UserDefaults.standard.data(forKey: storageKey) {
            placement = try? JSONDecoder().decode(FloatingPanelPlacement.self, from: data)
        }
    }
}
