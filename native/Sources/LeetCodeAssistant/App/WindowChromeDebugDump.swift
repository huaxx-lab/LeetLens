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

/// `LC_DUMP_SCROLL=1` 时每 50ms 扫一遍主窗口里所有滚动容器与 NSScroller，
/// 只在状态发生变化时打一行。用来抓「展开列时闪一下的黑色滚动条是谁画的」——
/// 这种东西活不过一秒，截图抓不稳，只能靠高频快照做 diff。
enum ScrollerDebugDump {
    nonisolated(unsafe) private static var last = ""

    static func startIfRequested() {
        guard ProcessInfo.processInfo.environment["LC_DUMP_SCROLL"] == "1" else { return }
        Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { _ in
            guard Thread.isMainThread else { return }
            MainActor.assumeIsolated {
                var lines: [String] = []
                for window in NSApp.windows where window.isVisible {
                    guard let root = window.contentView else { continue }
                    collect(root, into: &lines)
                }
                let snapshot = lines.joined(separator: "\n")
                guard snapshot != last else { return }
                last = snapshot
                FileHandle.standardError.write(Data(
                    "\n--- scroll \(Date().timeIntervalSince1970) ---\n\(snapshot)\n".utf8
                ))
            }
        }
    }

    private static func collect(_ view: NSView, into lines: inout [String]) {
        let name = String(describing: type(of: view))
        if let scrollView = view as? NSScrollView {
            lines.append(
                "SCROLLVIEW \(name) \(rect(scrollView.frame)) v=\(scrollView.hasVerticalScroller) "
                + "h=\(scrollView.hasHorizontalScroller) style=\(scrollView.scrollerStyle.rawValue) "
                + "autohide=\(scrollView.autohidesScrollers)"
            )
        }
        if let scroller = view as? NSScroller {
            lines.append(
                "  SCROLLER \(name) \(rect(scroller.frame)) alpha=\(String(format: "%.2f", scroller.alphaValue)) "
                + "hidden=\(scroller.isHidden) knob=\(scroller.knobStyle.rawValue) "
                + "style=\(scroller.scrollerStyle.rawValue)"
            )
        }
        for child in view.subviews { collect(child, into: &lines) }
    }

    private static func rect(_ value: NSRect) -> String {
        String(
            format: "(%.0f,%.0f,%.0fx%.0f)",
            value.origin.x, value.origin.y, value.size.width, value.size.height
        )
    }
}
