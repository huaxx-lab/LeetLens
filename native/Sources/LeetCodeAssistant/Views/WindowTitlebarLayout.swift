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

    /// 三颗按钮的目标 x：`targetLeading` 加上各自相对最左那颗的间距。
    ///
    /// **必须算成绝对值，不能用「整体平移多少」那种增量**。增量写法在这里是错的：
    /// 我们写完第一颗的 frame，AppKit 可能当场把整条标题栏重排回默认位置，
    /// 剩下两颗再加上同一个增量，结果就是 13 / 31 / 54——间距 18 和 23，
    /// 头一颗挪了、后两颗没挪。绝对值写法重复调用多少次都收敛到同一处。
    ///
    /// `offsets` 是第一次看到这三颗按钮时量下来的系统间距（默认 0 / 23 / 46），
    /// 用量到的而不是写死的数，系统换了节奏也跟得上。
    static func buttonOriginsX(targetLeading: CGFloat, offsets: [CGFloat]) -> [CGFloat] {
        offsets.map { targetLeading + $0 }
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
    private var isVerifying = false
    /// 三颗按钮的系统间距，第一次见到时量一次（那时它们还在默认位置）。
    private var buttonOffsets: [CGFloat] = []
    /// 当前正在盯着的那三个按钮视图。AppKit 换掉其中任何一个（进出设置页时
    /// 缩放键就会被换掉），旧的观察者就成了死信——必须重新挂。
    private var watchedButtons: [ObjectIdentifier] = []

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
        buttonOffsets = []
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
        // 按钮被换掉了：重新挂观察者，否则下一次它被重排我们收不到通知，
        // 只能等窗口缩放之类的事件补救——那就是肉眼可见的"跳一下再回位"。
        let identities = buttons.map(ObjectIdentifier.init)
        if identities != watchedButtons {
            observe(window)
        }
        if buttonOffsets.count != buttons.count {
            let leading = buttons.map(\.frame.origin.x).min() ?? 0
            buttonOffsets = buttons.map { $0.frame.origin.x - leading }
        }
        let targets = WindowTitlebarLayout.buttonOriginsX(
            targetLeading: AppDesign.Size.trafficLightLeadingInset,
            offsets: buttonOffsets
        )
        var didWrite = false
        for (button, x) in zip(buttons, targets) {
            let y = WindowTitlebarLayout.buttonOriginY(
                bandHeight: band,
                buttonHeight: button.frame.height,
                centerFromTop: center
            )
            var frame = button.frame
            if abs(frame.origin.y - y) > 0.5 { frame.origin.y = y }
            if abs(frame.origin.x - x) > 0.5 { frame.origin.x = x }
            if !frame.equalTo(button.frame) {
                button.frame = frame
                didWrite = true
            }
        }

        // AppKit 有时在我们写完之后当场把标题栏重排回去——实测最常见的是缩放键，
        // 于是三颗里两颗在新位置、一颗还在系统默认位置。下一个 runloop 再核一次，
        // 不对就再写一遍。只在真写过之后排一次，写完发现已经对了就不再排，不会打转。
        guard didWrite, !isVerifying else { return }
        isVerifying = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.isVerifying = false
            self.apply()
        }
    }

    private func observe(_ window: NSWindow) {
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        var watched: [NSView] = []
        if let close = window.standardWindowButton(.closeButton), let titlebar = close.superview {
            watched.append(contentsOf: [titlebar, titlebar.superview].compactMap { $0 })
        }
        var buttons: [NSView] = []
        for kind in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            if let button = window.standardWindowButton(kind) { buttons.append(button) }
        }
        watched.append(contentsOf: buttons)
        watchedButtons = buttons.map(ObjectIdentifier.init)
        // `queue: nil` 是关键：给了队列就是**异步投递**，修正要等到下一轮 runloop，
        // 中间那一帧按钮就停在系统默认位置上——进设置页时看到的"先跳一下再回位"
        // 就是这一帧。nil 表示在发通知的那个线程上同步跑，AppKit 刚把按钮重排回去，
        // 我们当场改回来，落在同一轮布局里，没有中间态。
        for view in watched {
            view.postsFrameChangedNotifications = true
            observers.append(NotificationCenter.default.addObserver(
                forName: NSView.frameDidChangeNotification,
                object: view,
                queue: nil
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.apply() }
            })
        }

        for name in [
            NSWindow.didResizeNotification,
            NSWindow.didBecomeKeyNotification,
            NSWindow.didExitFullScreenNotification,
            // 兜底：窗口每轮事件处理结束都会发这条。进出设置页时 AppKit 可能
            // 直接换掉按钮视图而不是改 frame，那条路一个通知都不发。
            NSWindow.didUpdateNotification
        ] {
            observers.append(NotificationCenter.default.addObserver(
                forName: name,
                object: window,
                queue: nil
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.apply() }
            })
        }
    }
}
