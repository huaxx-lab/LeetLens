import AppKit

/// `LC_DUMP_CHROME=1` 时每 4 秒把主窗口的 AppKit 视图树打到 stderr。
/// 只用来定位「那条灰带是谁画的」这类问题——标题栏那一带的层级全是私有类，
/// 靠截图猜不出来。默认完全不启用。
enum WindowChromeDebugDump {
    static func startIfRequested() {
        guard ProcessInfo.processInfo.environment["LC_DUMP_CHROME"] == "1" else { return }
        Timer.scheduledTimer(withTimeInterval: 4, repeats: true) { _ in
            guard Thread.isMainThread else { return }
            MainActor.assumeIsolated {
                for window in NSApp.windows where window.isVisible {
                    let full = window.styleMask.contains(.fullScreen)
                    FileHandle.standardError.write(Data("""
                    \n=== window \(window.frame) fullScreen=\(full) toolbar=\(window.toolbar != nil) \
                    transparentTitlebar=\(window.titlebarAppearsTransparent)\n
                    """.utf8))
                    if let root = window.contentView?.superview ?? window.contentView {
                        dump(root, depth: 0)
                    }
                }
            }
        }
    }

    private static func dump(_ view: NSView, depth: Int) {
        guard depth < 10 else { return }
        let name = String(describing: type(of: view))
        // 只关心顶部那一带：高度小于 90 或纵向靠上的层
        let indent = String(repeating: "  ", count: depth)
        var extra = ""
        if let effect = view as? NSVisualEffectView {
            extra = " material=\(effect.material.rawValue) state=\(effect.state.rawValue)"
        }
        if view.layer?.backgroundColor != nil { extra += " layerBG" }
        FileHandle.standardError.write(Data(
            "\(indent)\(name) \(view.frame) hidden=\(view.isHidden) opaque=\(view.isOpaque)\(extra)\n".utf8
        ))
        for child in view.subviews {
            dump(child, depth: depth + 1)
        }
    }
}
