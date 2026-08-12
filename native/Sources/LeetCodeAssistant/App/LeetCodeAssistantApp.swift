import AppKit
import SwiftUI

@main
struct LeetCodeAssistantApp: App {
    init() {
        // 共享 JSON 全是 read-modify-write：两个实例同时跑，后写者会静默覆盖前者。
        // 与旧版一致，改为把焦点交给已在运行的实例并退出本次启动。
        SingleInstanceGuard.enforce()
        NSWindow.allowsAutomaticWindowTabbing = false

        // 窗口级滚动条兜底：覆盖主窗口、设置窗口、sheet 与延迟创建的
        // AppKit 滚动容器（List/TextEditor 等不走 .scrollIndicators(.hidden)）。
        Timer.scheduledTimer(withTimeInterval: 0.8, repeats: true) { _ in
            guard Thread.isMainThread else { return }
            MainActor.assumeIsolated {
                for window in NSApp.windows {
                    AppKitScrollNormalizer.normalize(window: window)
                    if let sheet = window.attachedSheet {
                        AppKitScrollNormalizer.normalize(window: sheet)
                    }
                }
            }
        }
    }

    var body: some Scene {
        Window("LeetCode AI 助手", id: "main") {
            RootWorkspaceView()
                .frame(minWidth: 820, minHeight: 620)
        }
        .defaultSize(width: 1_700, height: 960)
        .defaultPosition(.center)
        .windowResizability(.contentMinSize)
        // 不使用 unified toolbar：它会始终保留一层系统标题栏安全区，
        // 结果是红绿灯在第一行、各列自绘头部被挤到第二行。
        // hiddenTitleBar 保留窗口按钮，但让内容真正延伸到它们下面。
        .windowStyle(.hiddenTitleBar)

        .commands {
            SidebarCommands()

            CommandGroup(replacing: .appSettings) {
                Button("设置…") {
                    NotificationCenter.default.post(name: .openInAppSettings, object: nil)
                }
                .keyboardShortcut(",", modifiers: .command)
            }
        }
    }
}

extension Notification.Name {
    static let openInAppSettings = Notification.Name("openInAppSettings")
}
