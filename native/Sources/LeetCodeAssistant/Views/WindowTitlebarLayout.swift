import AppKit

/// 把系统红绿灯挪到与三列列头同一条中线上，并且不再贴着窗口顶边框。
///
/// **为什么只能直接改 frame**：AppKit 把三颗按钮钉在 32pt 标题栏的正中（距顶 16pt），
/// 没有任何公开接口能改这条线。scratchpad 的 `titlebar-harness.swift` 实测过三条路：
/// ① 基线：`centerFromTop = 16`；
/// ② `NSTitlebarAccessoryViewController(layoutAttribute: .top)` 加 20pt——按钮**纹丝不动**；
/// ③ 把 `NSTitlebarContainerView` 一起加高再手动居中——有效，但**下一次窗口重排就被打回 16**。
/// unified toolbar 能加高标题栏，可它会多排一整行系统工具栏，正是本项目一路在拆的东西。
/// 所以做法是 ③ + 盯着 frame 变化补写，见 `WindowTrafficLightPositioner`。
enum WindowTitlebarLayout {
    /// 按钮在（加高后的）标题栏容器里的 y。AppKit 这层坐标未翻转，原点在左下角。
    static func buttonOriginY(
        bandHeight: CGFloat,
        buttonHeight: CGFloat,
        centerFromTop: CGFloat
    ) -> CGFloat {
        bandHeight - centerFromTop - buttonHeight / 2
    }

    /// 三颗按钮整体要平移多少。系统默认贴到左边 9pt，这里统一挪到
    /// `trafficLightLeadingInset`，按钮之间的间距原样保留（不自己造节奏）。
    /// 用「当前最左那颗」算增量，所以重复调用是幂等的。
    static func horizontalShift(currentLeading: CGFloat, targetLeading: CGFloat) -> CGFloat {
        targetLeading - currentLeading
    }

    /// 加高后的标题栏容器在 `NSThemeFrame` 里的位置。
    static func containerFrame(themeFrame: CGRect, bandHeight: CGFloat) -> CGRect {
        CGRect(
            x: 0,
            y: themeFrame.height - bandHeight,
            width: themeFrame.width,
            height: bandHeight
        )
    }
}

/// 盯着窗口的红绿灯，一旦被 AppKit 放回系统默认位置就重新落位。
///
/// 同时监听容器与三颗按钮的 `frameDidChange`：容器的变化覆盖窗口缩放，
/// 按钮自己的变化覆盖「容器没动、只有按钮被重排」（切 key 窗口、外观切换）。
/// 重入用 `isApplying` 挡住——我们自己写 frame 也会再发一次通知。
@MainActor
final class WindowTrafficLightPositioner {
    private weak var window: NSWindow?
    private var observers: [NSObjectProtocol] = []
    private var isApplying = false

    func attach(to window: NSWindow?) {
        guard self.window !== window else { return }
        detach()
        self.window = window
        guard let window else { return }
        observe(window)
        apply()
    }

    func detach() {
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        window = nil
    }

    /// 全屏由系统自己收起红绿灯，这里一律不碰；退出全屏时 `apply()` 会被再调一次。
    func apply() {
        guard !isApplying, let window, !window.styleMask.contains(.fullScreen) else { return }
        guard let close = window.standardWindowButton(.closeButton),
              let titlebar = close.superview,
              let container = titlebar.superview,
              let themeFrame = container.superview
        else { return }

        isApplying = true
        defer { isApplying = false }

        let band = ToolHeaderLayoutPolicy.titlebarBandHeight(isFullScreen: false)
        let target = WindowTitlebarLayout.containerFrame(themeFrame: themeFrame.bounds, bandHeight: band)
        if !container.frame.equalTo(target) { container.frame = target }
        if !titlebar.frame.equalTo(container.bounds) { titlebar.frame = container.bounds }

        let center = ToolHeaderLayoutPolicy.headerCenterY(isFullScreen: false)
        let buttons = [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton]
            .compactMap { window.standardWindowButton($0) }
        let shift = WindowTitlebarLayout.horizontalShift(
            currentLeading: buttons.map(\.frame.origin.x).min() ?? 0,
            targetLeading: AppDesign.Size.trafficLightLeadingInset
        )
        for button in buttons {
            let y = WindowTitlebarLayout.buttonOriginY(
                bandHeight: band,
                buttonHeight: button.frame.height,
                centerFromTop: center
            )
            var frame = button.frame
            if abs(frame.origin.y - y) > 0.5 { frame.origin.y = y }
            if abs(shift) > 0.5 { frame.origin.x += shift }
            if !frame.equalTo(button.frame) { button.frame = frame }
        }
    }

    private func observe(_ window: NSWindow) {
        var watched: [NSView] = []
        if let close = window.standardWindowButton(.closeButton), let titlebar = close.superview {
            watched.append(contentsOf: [titlebar, titlebar.superview].compactMap { $0 })
        }
        for kind in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            if let button = window.standardWindowButton(kind) { watched.append(button) }
        }
        for view in watched {
            view.postsFrameChangedNotifications = true
            observers.append(NotificationCenter.default.addObserver(
                forName: NSView.frameDidChangeNotification,
                object: view,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.apply() }
            })
        }

        for name in [
            NSWindow.didResizeNotification,
            NSWindow.didBecomeKeyNotification,
            NSWindow.didExitFullScreenNotification
        ] {
            observers.append(NotificationCenter.default.addObserver(
                forName: name,
                object: window,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.apply() }
            })
        }
    }
}
