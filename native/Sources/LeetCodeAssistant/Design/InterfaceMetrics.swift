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
        case followDisplay
        case compact
        case standard
        case large

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
            case .followDisplay: "自动"
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
    var scale: CGFloat {
        fontScale == .followDisplay ? displayScale : fontScale.multiplier
    }

    /// 屏幕自动缩放的口径：以 1800pt 的工作区对角线为基准（约等于 1440×900 的笔记本屏），
    /// 每超出 1% 放大 0.54%，封顶 1.18×。
    ///
    /// **这条曲线改过两次，别再往陡里调**：
    /// - 原样照搬 Electron 1.x（斜率 1.7、封顶 1.5）时，这台机器的 24" 1920×1080 外接屏
    ///   算出 1.38×，正文 13pt → 18pt，用户当场否掉（"全屏下字太大、很难看"），
    ///   于是 2026-08 把它降级成可选档、默认固定 ×1.0；
    /// - 默认 ×1.0 之后又被反馈"大屏上字很小"——当时 215 处 `.font(.caption)` 不跟档位走、
    ///   对话 / 题面 / 编辑器网页也不跟，自动档开了也只放大了一半界面。
    /// 2026-09 覆盖面补齐后，用户选定"默认温和跟随"：笔记本 ×1.0、1080p 外接屏 ×1.12、
    /// 2K 及以上封顶 ×1.18。字放大时列宽跟着放大（`AppDesign.Size`），不会挤。
    static let baseWorkAreaDiagonal: CGFloat = 1_800
    static let maximumDisplayScale: CGFloat = 1.18
    static let displayScaleSlope: CGFloat = 0.54

    static func displayScale(for screen: NSScreen?) -> CGFloat {
        // 用 visibleFrame 而不是 frame：菜单栏和 Dock 占掉的地方本来就排不了界面，
        // 把它们算进对角线会让缩放偏大。
        guard let area = screen?.visibleFrame else { return 1 }
        return displayScale(workAreaWidth: area.width, height: area.height)
    }

    /// 取到 0.01：窗口在两块屏之间拖动、Dock 自动隐藏时 visibleFrame 会抖几个点，
    /// 不取整的话倍率跟着抖，整棵视图树和网页缩放一起重排。
    static func displayScale(workAreaWidth width: CGFloat, height: CGFloat) -> CGFloat {
        guard width > 0, height > 0 else { return 1 }
        let diagonal = hypot(width, height)
        let proportional = 1 + ((diagonal / baseWorkAreaDiagonal) - 1) * displayScaleSlope
        return (min(maximumDisplayScale, max(1, proportional)) * 100).rounded() / 100
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
        // 没选过就是「自动」。显式选过「标准」的人保留他的选择。
        fontScale = stored.flatMap(FontScale.init(rawValue:)) ?? .followDisplay
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
