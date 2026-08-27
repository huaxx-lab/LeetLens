import SwiftUI

/// 界面字号档位。
///
/// **为什么需要它**：`Font.system(size:)` 在 macOS 上是固定 pt——既不跟系统文字尺寸走，
/// 也没有 App 级缩放。界面按点排版，屏幕越大分辨率越高，同一个 13pt 在物理上就越小，
/// 于是"换了大屏，字反而更小"。整套 `AppDesign.Typography` 与 `Font.appScaled(size:)`
/// 都乘上这里的倍率，用户在「设置 ▸ 外观」里选一次就全局生效。
///
/// **为什么是 `@Observable` 而不是一个全局常量**：SwiftUI 的观察按"读取发生的时机"登记，
/// `AppDesign.Typography.body` 是在 View 的 body 求值时才去读 `shared.fontScale` 的，
/// 这次读取正好落在 body 的观察范围内。所以换档位时，只有真正用了字体 token 的视图重绘——
/// 不必给根视图挂 `.id()` 把整棵树连同 WKWebView 一起重建（那会让浏览器列的页面全部重新加载）。
@MainActor
@Observable
final class InterfaceMetrics {
    static let shared = InterfaceMetrics()

    enum FontScale: String, CaseIterable, Identifiable, Sendable {
        case compact
        case standard
        case large
        case followDisplay

        var id: String { rawValue }

        /// 固定档的倍率。档距取 ~1.12：再密就分不出来，再疏则大一档会把三列布局挤到断点以下。
        /// `followDisplay` 不在这里取值——它按屏幕现算，见 `InterfaceMetrics.scale`。
        var multiplier: CGFloat {
            switch self {
            case .compact: 0.92
            case .standard: 1
            case .large: 1.12
            case .followDisplay: 1
            }
        }

        var title: String {
            switch self {
            case .compact: "紧凑"
            case .standard: "标准"
            case .large: "较大"
            case .followDisplay: "跟随屏幕"
            }
        }
    }

    private static let storageKey = "interfaceFontScale"

    /// 用户在设置里选的档位，作用在自动缩放**之上**（相对调整，不是绝对字号）。
    var fontScale: FontScale {
        didSet {
            guard fontScale != oldValue else { return }
            UserDefaults.standard.set(fontScale.rawValue, forKey: Self.storageKey)
        }
    }

    /// 按当前屏幕算出来的自动缩放。
    private(set) var displayScale: CGFloat = 1

    /// 实际生效的倍率。
    ///
    /// **默认不跟屏幕走**：按屏幕自动缩放只在用户明确选了「跟随屏幕」时才生效。
    /// 实测把 Electron 那条曲线原样搬过来，1920×1080 的外接屏上会算出 1.38×——
    /// 正文 13pt 变成 18pt，对原生版这套本来就更密的排版来说太冲了，
    /// 而且列宽没跟着变，侧栏标题反而截得更狠。所以它是一个选项，不是默认值。
    var scale: CGFloat {
        fontScale == .followDisplay ? displayScale : fontScale.multiplier
    }

    /// 屏幕自动缩放的口径，**照搬 Electron 1.x 客户端的 `src/platform/display-profile.js`**：
    /// 以 1800pt 的工作区对角线为基准（约等于 1440×900 的笔记本屏），
    /// 每超出 1% 就多放大 1.7%，封顶 1.5×。
    ///
    /// 为什么要照搬而不是重新拍一组数：老客户端在这台机器的外接屏（1920×1080 @1x，
    /// 对角线约 2200）上算出来是 ~1.37×，用户已经习惯了那个观感；
    /// 原生版重写时把这套整个丢了，同一块屏上字就"忽然变小了"。
    private static let baseWorkAreaDiagonal: CGFloat = 1_800
    /// 封顶从 Electron 的 1.5 收到 1.25：原生版的字体阶梯基准比老客户端大，
    /// 同一条曲线跑到 1.4 以上就明显过头了。
    private static let maximumDisplayScale: CGFloat = 1.25
    private static let displayScaleSlope: CGFloat = 1.7

    static func displayScale(for screen: NSScreen?) -> CGFloat {
        // 用 visibleFrame 而不是 frame：菜单栏和 Dock 占掉的地方本来就排不了界面，
        // 把它们算进对角线会让缩放偏大。
        guard let area = screen?.visibleFrame, area.width > 0, area.height > 0 else { return 1 }
        let diagonal = hypot(area.width, area.height)
        let proportional = 1 + ((diagonal / baseWorkAreaDiagonal) - 1) * displayScaleSlope
        return min(maximumDisplayScale, max(1, proportional))
    }

    /// 窗口所在的那块屏，而不是 `NSScreen.main`——把窗口从笔记本屏拖到外接屏时，
    /// `main` 指的是"有键盘焦点的那块"，跨屏拖动过程中它并不总是跟着走。
    func refreshDisplayScale() {
        let screen = NSApplication.shared.keyWindow?.screen
            ?? NSApplication.shared.windows.first(where: { $0.isVisible })?.screen
            ?? NSScreen.main
        let next = Self.displayScale(for: screen)
        guard abs(next - displayScale) > 0.001 else { return }
        displayScale = next
    }

    /// 这项偏好只影响渲染、不进 `LegacySettingsSnapshot` 那份 JSON：
    /// `AppDesign.Typography` 是静态取值点，拿不到 `LegacyDataStore`，
    /// 再镜像一份就会出现两个真相源。
    private init() {
        let stored = UserDefaults.standard.string(forKey: Self.storageKey)
        fontScale = stored.flatMap(FontScale.init(rawValue:)) ?? .standard
        displayScale = Self.displayScale(for: NSScreen.main)

        // 接显示器、改分辨率、窗口挪到另一块屏——三件事都要重算。
        for name in [
            NSApplication.didChangeScreenParametersNotification,
            NSWindow.didChangeScreenNotification
        ] {
            NotificationCenter.default.addObserver(
                forName: name,
                object: nil,
                queue: .main
            ) { _ in
                MainActor.assumeIsolated { InterfaceMetrics.shared.refreshDisplayScale() }
            }
        }
    }
}

extension Font {
    /// 跟随「界面字号」档位缩放的系统字体。
    ///
    /// View 层不要再直接写 `.system(size:)`：那是固定 pt，调档位不会跟着变。
    /// 能用 `AppDesign.Typography` 里的档位就优先用档位，这里是给确实不在阶梯上的
    /// 一次性字号（角标、chevron、超大数字）留的口子。
    @MainActor
    static func appScaled(
        size: CGFloat,
        weight: Font.Weight = .regular,
        design: Font.Design = .default
    ) -> Font {
        .system(size: size * AppDesign.Typography.scale, weight: weight, design: design)
    }
}
