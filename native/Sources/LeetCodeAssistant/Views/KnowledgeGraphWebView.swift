import AppKit
import SwiftUI
import WebKit

/// 脑图画布。渲染在 WebView 里自绘（DOM 卡片 + SVG 连线 + 自己算的 tidy 布局），
/// Swift 这边只管喂数据和收事件。
///
/// 卡片正文是 Markdown，用的是项目里已有的 markdown-it + highlight.js + DOMPurify，
/// 和聊天、题解同一套，所以同一段讲解在哪儿看都是一个样子。
struct KnowledgeGraphWebView: NSViewRepresentable {
    let elements: KnowledgeGraphElements
    /// 父节点 → 子节点顺序（人工排过的分支才有）。
    let childOrder: [String: [String]]
    let collapsed: [String]
    /// 挂在节点上的笔记。复盘评论也是笔记——只有一种东西，
    /// 不再让人先决定"这段话算笔记还是算评论"。
    let noteCards: [KnowledgeGraphOverlay.NoteCard]
    /// 正在生成 AI 讲解的节点，画布拿它显示「生成中…」。
    let busyNodes: [String]
    let searchText: String
    let isLinking: Bool
    let linkDirected: Bool
    /// 单调递增；外部想强制重推一次图时 +1。
    let reloadToken: Int
    let focusRequest: String?
    /// 与 `focusRequest` 配套的递增票据：目标 id 没变也要能再对焦一次。
    let focusToken: Int
    let fitRequest: Int

    var onSelect: (String) -> Void
    var onActivate: (String) -> Void
    var onAction: (String, String) -> Void
    var onReorder: (String, [String]) -> Void
    var onLinkCreated: (String, String, Bool) -> Void
    var onNoteAdded: (String, String) -> Void
    var onNoteUpdated: (String, String) -> Void
    var onNoteRemoved: (String) -> Void
    var onLessonRequested: (String, Bool) -> Void
    var onLinkRemoved: (String) -> Void
    var onCollapseChanged: ([String]) -> Void
    var onLayoutReset: () -> Void
    var onLinkModeExited: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeNSView(context: Context) -> WKWebView {
        let controller = WKUserContentController()
        for name in [
            "bridgeReady", "graphReady", "nodeSelected", "nodeActivated", "nodeAction",
            "nodeReordered", "linkCreated", "linkRemoved",
            "noteAdded", "noteUpdated", "noteRemoved", "lessonRequested",
            "collapseChanged", "layoutReset", "linkModeExited", "copyCode"
        ] {
            controller.add(context.coordinator, name: name)
        }
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.userContentController = controller
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        // 不能透明：底下没有不透明层，缩放时会直接透出桌面。
        // 底色必须和 HTML 里的纸张色一致，否则加载瞬间和橡皮筋回弹时会闪白。
        webView.underPageBackgroundColor = NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                ? NSColor(srgbRed: 0.137, green: 0.137, blue: 0.122, alpha: 1)
                : NSColor(srgbRed: 0.914, green: 0.898, blue: 0.855, alpha: 1)
        }
        context.coordinator.webView = webView
        if let url = Bundle.module.url(forResource: "graph", withExtension: "html", subdirectory: "KnowledgeGraph"),
           let resourceURL = Bundle.module.resourceURL {
            webView.loadFileURL(url, allowingReadAccessTo: resourceURL)
        } else if let url = Bundle.module.url(forResource: "graph", withExtension: "html"),
                  let resourceURL = Bundle.module.resourceURL {
            webView.loadFileURL(url, allowingReadAccessTo: resourceURL)
        }
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.synchronize()
    }

    @MainActor
    final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
        var parent: KnowledgeGraphWebView
        weak var webView: WKWebView?
        private var isReady = false
        private var lastSignature = ""
        private var lastSearch = ""
        private var lastCollapsed: [String] = []
        private var lastBusy: [String] = []
        private var lastMode = ""
        private var lastFocus: String?
        private var lastFocusToken = 0
        private var lastFitRequest = 0
        private var lastReloadToken = -1

        init(parent: KnowledgeGraphWebView) {
            self.parent = parent
        }

        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            let body = message.body as? [String: Any] ?? [:]
            switch message.name {
            case "bridgeReady":
                isReady = true
                lastSignature = ""
                synchronize()
            case "nodeSelected":
                parent.onSelect(body["id"] as? String ?? "")
            case "nodeActivated":
                guard let id = body["id"] as? String, !id.isEmpty else { return }
                parent.onActivate(id)
            case "nodeAction":
                guard let id = body["id"] as? String, let action = body["action"] as? String else { return }
                parent.onAction(id, action)
            case "nodeReordered":
                guard let parentID = body["parent"] as? String,
                      let order = body["order"] as? [String]
                else { return }
                parent.onReorder(parentID, order)
            case "linkCreated":
                guard let source = body["source"] as? String, let target = body["target"] as? String else { return }
                parent.onLinkCreated(source, target, body["directed"] as? Bool ?? false)
            case "noteAdded":
                guard let anchor = body["anchorID"] as? String, let text = body["text"] as? String else { return }
                parent.onNoteAdded(anchor, text)
            case "noteUpdated":
                guard let id = body["id"] as? String, let text = body["text"] as? String else { return }
                parent.onNoteUpdated(id, text)
            case "lessonRequested":
                guard let id = body["id"] as? String else { return }
                parent.onLessonRequested(id, body["force"] as? Bool ?? false)
            case "linkRemoved":
                guard let id = body["id"] as? String else { return }
                parent.onLinkRemoved(id)
            case "noteRemoved":
                guard let id = body["id"] as? String else { return }
                parent.onNoteRemoved(id)
            case "collapseChanged":
                parent.onCollapseChanged(body["collapsed"] as? [String] ?? [])
            case "layoutReset":
                parent.onLayoutReset()
            case "linkModeExited":
                parent.onLinkModeExited()
            case "copyCode":
                guard let code = body["code"] as? String, !code.isEmpty else { return }
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(code, forType: .string)
            default:
                break
            }
        }



        func synchronize() {
            guard isReady, let webView else { return }

            // 只有内容真的变了才重推。否则每次 SwiftUI 重绘都会重建整张图，
            // 视口和选中状态跟着抖。讲解和笔记也算内容——它们决定卡片多高。
            let signature = "\(parent.reloadToken)|"
                + parent.elements.nodes
                    .map { "\($0.id)#\($0.title)#\($0.detail)#\($0.lesson.count)" }
                    .joined(separator: ",")
                + "|" + parent.elements.edges.map { "\($0.id)#\($0.directed)" }.joined(separator: ",")
                + "|" + parent.noteCards.map { "\($0.id)#\($0.text.hashValue)" }.joined(separator: ",")
            if signature != lastSignature || parent.reloadToken != lastReloadToken {
                lastSignature = signature
                lastReloadToken = parent.reloadToken
                // 整图 payload 里已经带了 collapsed，这里同步记下，
                // 免得紧接着再推一次 setCollapsed，把刚算好的首屏视图又冲掉。
                lastCollapsed = parent.collapsed
                pushGraph(webView)
            }

            if parent.collapsed != lastCollapsed {
                lastCollapsed = parent.collapsed
                pushCollapsed(webView)
            }
            if parent.busyNodes != lastBusy {
                lastBusy = parent.busyNodes
                push(webView, "setBusy", array: parent.busyNodes)
            }
            if parent.searchText != lastSearch {
                lastSearch = parent.searchText
                call(webView, "setSearch", argument: parent.searchText)
            }
            let mode = parent.isLinking ? (parent.linkDirected ? "link-directed" : "link") : "select"
            if mode != lastMode {
                lastMode = mode
                call(webView, "setMode", argument: mode)
            }
            if let focus = parent.focusRequest, focus != lastFocus || parent.focusToken != lastFocusToken {
                lastFocus = focus
                lastFocusToken = parent.focusToken
                call(webView, "focus", argument: focus)
            }
            if parent.fitRequest != lastFitRequest {
                lastFitRequest = parent.fitRequest
                webView.evaluateJavaScript("window.graphBridge.fit()")
            }
        }

        private func pushGraph(_ webView: WKWebView) {
            let payload: [String: Any] = [
                "collapsed": parent.collapsed,
                "noteCards": parent.noteCards.map { note -> [String: Any] in
                    [
                        "id": note.id,
                        "anchorID": note.anchorID,
                        "text": note.text,
                        "createdAt": Int(note.createdAt.timeIntervalSince1970 * 1_000)
                    ]
                },
                "nodes": parent.elements.nodes.map { node -> [String: Any] in
                    var value: [String: Any] = [
                        "id": node.id,
                        "title": node.title,
                        "kind": node.kind,
                        "detail": node.detail,
                        "lesson": node.lesson,
                        "haystack": node.haystack
                    ]
                    if let score = node.score { value["score"] = score }
                    return value
                },
                "edges": parent.elements.edges.map { edge -> [String: Any] in
                    [
                        "id": edge.id,
                        "source": edge.source,
                        "target": edge.target,
                        "type": edge.type,
                        "label": edge.label,
                        "directed": edge.directed
                    ]
                },
                "childOrder": parent.childOrder
            ]
            guard let data = try? JSONSerialization.data(withJSONObject: payload),
                  let json = String(data: data, encoding: .utf8)
            else { return }
            webView.evaluateJavaScript("window.graphBridge.setGraph(\(json))")
        }

        private func pushCollapsed(_ webView: WKWebView) {
            push(webView, "setCollapsed", array: parent.collapsed)
        }

        private func push(_ webView: WKWebView, _ function: String, array: [String]) {
            guard let data = try? JSONSerialization.data(withJSONObject: array),
                  let json = String(data: data, encoding: .utf8)
            else { return }
            webView.evaluateJavaScript("window.graphBridge.\(function)(\(json))")
        }

        func expandAll() { webView?.evaluateJavaScript("window.graphBridge.expandAll()") }
        func collapseAll() { webView?.evaluateJavaScript("window.graphBridge.collapseAll()") }
        func relayout() { webView?.evaluateJavaScript("window.graphBridge.relayout()") }


        func zoom(_ factor: Double) {
            webView?.evaluateJavaScript("window.graphBridge.zoomBy(\(factor))")
        }

        private func call(_ webView: WKWebView, _ function: String, argument: String) {
            webView.evaluateJavaScript("window.graphBridge.\(function)(\(quoted(argument)))")
        }

        private func quoted(_ value: String) -> String {
            let data = (try? JSONSerialization.data(withJSONObject: [value])) ?? Data("[\"\"]".utf8)
            let text = String(data: data, encoding: .utf8) ?? "[\"\"]"
            return String(text.dropFirst().dropLast())
        }
    }
}
