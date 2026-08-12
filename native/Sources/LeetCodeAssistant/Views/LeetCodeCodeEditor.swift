import AppKit
import SwiftUI
import WebKit

struct LeetCodeEditorIssue: Hashable, Sendable {
    let line: Int
    let message: String
}

struct LeetCodeEditorDiagnostics: Hashable, Sendable {
    var issues: [LeetCodeEditorIssue] = []

    var statusText: String {
        issues.isEmpty ? "基础语法检查通过" : "发现 \(issues.count) 处基础语法问题"
    }
}

enum LeetCodeEditorLoadStatus: Hashable, Sendable {
    case loading
    case ready
    case failed(String)
}

enum LeetCodeCompletionStatus: Hashable, Sendable {
    case localOnly
    case connecting
    case online(String)
    case offline(String)

    var title: String {
        switch self {
        case .localOnly: "补全：本地"
        case .connecting: "补全：连接中"
        case .online: "补全：语义就绪"
        case .offline: "补全：本地兜底"
        }
    }

    var detail: String {
        switch self {
        case .localOnly: "未配置远程 Java 语义服务"
        case .connecting: "正在连接远程 Java 语义服务"
        case .online(let engine): engine
        case .offline(let reason): reason
        }
    }

    var isOnline: Bool {
        if case .online = self { return true }
        return false
    }
}

enum LeetCodeEditorLanguage {
    static func normalized(_ slug: String) -> String {
        switch slug.lowercased() {
        case "java": "java"
        case "cpp", "c++": "cpp"
        case "c": "c"
        case "python", "python3": "python3"
        case "javascript", "js": "javascript"
        case "typescript", "ts": "typescript"
        default: "java"
        }
    }
}

struct LeetCodeCodeEditor: NSViewRepresentable {
    @Binding var code: String
    let language: String
    @Binding var diagnostics: LeetCodeEditorDiagnostics
    @Binding var loadStatus: LeetCodeEditorLoadStatus
    @Binding var completionStatus: LeetCodeCompletionStatus
    let formatRequest: Int
    let undoRequest: Int
    let redoRequest: Int
    /// 想按内容自适应高度的宿主传这个；刷题页那种固定分栏不用传。
    var contentHeight: Binding<CGFloat>? = nil

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeNSView(context: Context) -> WKWebView {
        let controller = WKUserContentController()
        controller.add(context.coordinator, name: "editorReady")
        controller.add(context.coordinator, name: "editorFailed")
        controller.add(context.coordinator, name: "editorChanged")
        controller.add(context.coordinator, name: "editorDiagnostics")
        controller.add(context.coordinator, name: "remoteCompletionRequested")
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.userContentController = controller
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        WebViewPresentation.applyFloatingScrollbars(in: configuration)
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.underPageBackgroundColor = .clear
        context.coordinator.webView = webView
        context.coordinator.updateCompletionStatus(
            RemoteCodeCompletionService.shared.isConfigured ? .offline("远程服务等待首次补全请求") : .localOnly
        )
        if let editorURL = Bundle.module.url(forResource: "editor", withExtension: "html"),
           let resourceURL = Bundle.module.resourceURL {
            webView.loadFileURL(editorURL, allowingReadAccessTo: resourceURL)
        } else {
            context.coordinator.updateLoadStatus(.failed("代码编辑器资源未打包"))
            webView.loadHTMLString("<p style='font:13px -apple-system;padding:16px'>代码编辑器资源缺失</p>", baseURL: nil)
        }
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.synchronize()
    }

    static func dismantleNSView(_ webView: WKWebView, coordinator: Coordinator) {
        let controller = webView.configuration.userContentController
        ["editorReady", "editorFailed", "editorChanged", "editorDiagnostics", "remoteCompletionRequested"]
            .forEach(controller.removeScriptMessageHandler(forName:))
        coordinator.completionTask?.cancel()
        webView.navigationDelegate = nil
    }

    @MainActor
    final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
        var parent: LeetCodeCodeEditor
        weak var webView: WKWebView?
        private var isReady = false
        private var lastWebCode = ""
        private var lastLanguage = ""
        private var lastFormatRequest = 0
        private var lastUndoRequest = 0
        private var lastRedoRequest = 0
        var completionTask: Task<Void, Never>?

        init(parent: LeetCodeCodeEditor) {
            self.parent = parent
        }

        /// CodeMirror 报上来的内容总高度。抖动小于 1pt 就不写回，
        /// 免得每次按键都推一轮布局。
        private func updateContentHeight(_ value: Any?) {
            guard let binding = parent.contentHeight,
                  let number = value as? NSNumber
            else { return }
            let next = CGFloat(number.doubleValue)
            guard next > 0, abs(next - binding.wrappedValue) >= 1 else { return }
            binding.wrappedValue = next
        }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            switch message.name {
            case "editorReady":
                isReady = true
                updateLoadStatus(.ready)
                updateContentHeight((message.body as? [String: Any])?["contentHeight"])
                synchronize(force: true)
            case "editorFailed":
                let detail = (message.body as? [String: Any])?["message"] as? String ?? "本地编辑器脚本加载失败"
                updateLoadStatus(.failed(String(detail.prefix(240))))
            case "editorChanged":
                guard let body = message.body as? [String: Any], let value = body["code"] as? String else { return }
                updateContentHeight(body["contentHeight"])
                lastWebCode = value
                if parent.code != value { parent.code = value }
            case "editorDiagnostics":
                guard let body = message.body as? [String: Any], let rawIssues = body["issues"] as? [[String: Any]] else { return }
                let issues = rawIssues.compactMap { item -> LeetCodeEditorIssue? in
                    guard let line = (item["line"] as? NSNumber)?.intValue,
                          let message = item["message"] as? String,
                          !message.isEmpty
                    else { return nil }
                    return LeetCodeEditorIssue(line: line + 1, message: String(message.prefix(160)))
                }
                let value = LeetCodeEditorDiagnostics(issues: issues)
                if parent.diagnostics != value { parent.diagnostics = value }
            case "remoteCompletionRequested":
                handleRemoteCompletion(message.body)
            default:
                break
            }
        }

        func updateLoadStatus(_ status: LeetCodeEditorLoadStatus) {
            if parent.loadStatus != status { parent.loadStatus = status }
        }

        func updateCompletionStatus(_ status: LeetCodeCompletionStatus) {
            if parent.completionStatus != status { parent.completionStatus = status }
        }

        private func handleRemoteCompletion(_ rawBody: Any) {
            guard let body = rawBody as? [String: Any],
                  let requestID = (body["requestID"] as? NSNumber)?.intValue,
                  let code = body["code"] as? String,
                  let language = body["language"] as? String,
                  let line = (body["line"] as? NSNumber)?.intValue,
                  let character = (body["character"] as? NSNumber)?.intValue
            else { return }
            completionTask?.cancel()
            guard RemoteCodeCompletionService.shared.isConfigured else {
                updateCompletionStatus(.localOnly)
                deliverRemoteCompletions(requestID: requestID, items: [])
                return
            }
            updateCompletionStatus(.connecting)
            completionTask = Task { @MainActor [weak self] in
                guard let self else { return }
                do {
                    let response = try await RemoteCodeCompletionService.shared.complete(
                        code: code,
                        line: line,
                        character: character,
                        language: language
                    )
                    try Task.checkCancellation()
                    updateCompletionStatus(.online(response.engine))
                    deliverRemoteCompletions(requestID: requestID, items: response.items)
                } catch is CancellationError {
                    return
                } catch {
                    updateCompletionStatus(.offline(error.localizedDescription))
                    deliverRemoteCompletions(requestID: requestID, items: [])
                }
            }
        }

        private func deliverRemoteCompletions(requestID: Int, items: [RemoteCompletionItem]) {
            callJavaScript(
                "window.editorBridge.applyRemoteCompletions(requestID, items)",
                arguments: [
                    "requestID": requestID,
                    "items": items.map {
                        ["label": $0.label, "insertText": $0.insertText, "detail": $0.detail, "kind": $0.kind, "sortText": $0.sortText]
                    }
                ]
            )
        }

        func synchronize(force: Bool = false) {
            guard isReady, webView != nil else { return }
            let normalizedLanguage = LeetCodeEditorLanguage.normalized(parent.language)
            if force || parent.code != lastWebCode || normalizedLanguage != lastLanguage {
                lastLanguage = normalizedLanguage
                callJavaScript(
                    "window.editorBridge.setValue(code, language)",
                    arguments: ["code": parent.code, "language": normalizedLanguage]
                )
            }
            if parent.formatRequest != lastFormatRequest {
                lastFormatRequest = parent.formatRequest
                callJavaScript("window.editorBridge.format()")
            }
            if parent.undoRequest != lastUndoRequest {
                lastUndoRequest = parent.undoRequest
                callJavaScript("window.editorBridge.undo()")
            }
            if parent.redoRequest != lastRedoRequest {
                lastRedoRequest = parent.redoRequest
                callJavaScript("window.editorBridge.redo()")
            }
        }

        private func callJavaScript(_ source: String, arguments: [String: Any] = [:]) {
            guard let webView else { return }
            Task { @MainActor [weak webView] in
                guard let webView else { return }
                _ = try? await webView.callAsyncJavaScript(
                    source,
                    arguments: arguments,
                    in: nil,
                    contentWorld: .page
                )
            }
        }

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void
        ) {
            guard let url = navigationAction.request.url else {
                decisionHandler(.cancel)
                return
            }
            decisionHandler(url.isFileURL ? .allow : .cancel)
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            updateLoadStatus(.failed(error.localizedDescription))
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            updateLoadStatus(.failed(error.localizedDescription))
        }
    }
}
