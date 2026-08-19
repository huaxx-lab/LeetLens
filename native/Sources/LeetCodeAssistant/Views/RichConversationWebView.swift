import AppKit
import SwiftUI
import WebKit

/// 聊天代码块的统一视觉与行为规范。
///
/// 其他只读代码渲染器（SwiftUI 卡片、题解、脑图）从这里取同一组尺寸、圆角和颜色，
/// Web 侧则使用同名 `.code-block/.code-head` DOM 契约。这样不是“看起来差不多”，而是
/// 以后聊天调一处，其他入口有一个明确的同步源。
enum ConversationCodeBlockStyle {
    static let cornerRadius: CGFloat = 6
    static let headerHeight: CGFloat = 40
    static let copyControlSize: CGFloat = 32
    static let fontSize: CGFloat = 12
    static let lineSpacing: CGFloat = 2
    static let horizontalPadding: CGFloat = 16
    static let topPadding: CGFloat = 6
    static let bottomPadding: CGFloat = 18

    static var background: Color { Color.primary.opacity(0.052) }
    static var secondaryForeground: Color { Color.secondary.opacity(0.82) }
}

struct RichConversationWebView: NSViewRepresentable {
    let messages: [ConversationTranscriptMessage]
    let conversationRevision: ConversationRevision?
    let generation: ConversationGenerationSnapshot?
    let scrollTargetID: String?
    let scrollTargetRevision: Int
    let onQuestionActivity: (String, Bool) -> Void
    let onOpenURL: (URL) -> Void
    let onRetry: () -> Void
    /// 工具卡片上的跳转：(kind, id)，由上层决定落到哪个页面。
    let onAgentJump: (String, String) -> Void
    let contentTrailingInset: CGFloat
    /// 左侧问题刻度条占掉的一条，作为正文左内缩的下限下发给页面。
    var contentLeadingInset: CGFloat = 0

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        configuration.userContentController.add(context.coordinator, name: "questionRail")
        configuration.userContentController.add(context.coordinator, name: "conversationAction")
        configuration.userContentController.add(context.coordinator, name: "copyCode")
        configuration.userContentController.add(context.coordinator, name: "agentJump")
        configuration.userContentController.add(context.coordinator, name: "bilibiliView")
        configuration.userContentController.add(context.coordinator, name: "leetcodeSolution")
        WebViewPresentation.applyFloatingScrollbars(in: configuration)

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        webView.underPageBackgroundColor = .clear
        webView.allowsMagnification = true
        webView.magnification = 1
        context.coordinator.webView = webView
        context.coordinator.messages = messages
        context.coordinator.conversationRevision = conversationRevision
        context.coordinator.generation = generation
        context.coordinator.onQuestionActivity = onQuestionActivity
        context.coordinator.onOpenURL = onOpenURL
        context.coordinator.onRetry = onRetry
        context.coordinator.onAgentJump = onAgentJump
        context.coordinator.contentTrailingInset = contentTrailingInset
        context.coordinator.contentLeadingInset = contentLeadingInset
        context.coordinator.loadTemplate()
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        context.coordinator.messages = messages
        context.coordinator.conversationRevision = conversationRevision
        context.coordinator.generation = generation
        context.coordinator.onQuestionActivity = onQuestionActivity
        context.coordinator.onOpenURL = onOpenURL
        context.coordinator.onRetry = onRetry
        context.coordinator.onAgentJump = onAgentJump
        context.coordinator.updateContentTrailingInset(contentTrailingInset)
        context.coordinator.updateContentLeadingInset(contentLeadingInset)
        context.coordinator.renderIfNeeded()
        context.coordinator.scrollToQuestionIfNeeded(scrollTargetID, revision: scrollTargetRevision)
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler {
        weak var webView: WKWebView?
        var messages: [ConversationTranscriptMessage] = []
        var conversationRevision: ConversationRevision?
        var generation: ConversationGenerationSnapshot?
        var onQuestionActivity: ((String, Bool) -> Void)?
        var onOpenURL: ((URL) -> Void)?
        var onRetry: (() -> Void)?
        var onAgentJump: ((String, String) -> Void)?
        var contentTrailingInset: CGFloat = 0
        var contentLeadingInset: CGFloat = 0
        private var appliedContentLeadingInset: CGFloat?
        private var isReady = false
        private var appliedContentTrailingInset: CGFloat?
        private var renderedRevision: ConversationRevision?
        private var renderedGenerationSignature = ""
        private var renderedGenerationID: String?
        private var lastScrollTargetID: String?
        private var lastScrollTargetRevision = -1
        /// 上游已将 SSE token 合并到 50ms；这里只合并同一主队列周期的重复 SwiftUI 更新。
        private var renderWorkItem: DispatchWorkItem?
        private var lastRenderAt: Date = .distantPast

        func loadTemplate() {
            guard let webView else { return }
            let templateURL = Bundle.module.url(
                forResource: "conversation",
                withExtension: "html",
                subdirectory: "RichContent"
            ) ?? Bundle.module.url(forResource: "conversation", withExtension: "html")
            guard let templateURL else { return }
            webView.loadFileURL(
                templateURL,
                allowingReadAccessTo: templateURL.deletingLastPathComponent()
            )
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            isReady = true
            updateContentTrailingInset(contentTrailingInset, force: true)
            updateContentLeadingInset(contentLeadingInset, force: true)
            renderIfNeeded(force: true)
        }

        func updateContentTrailingInset(_ inset: CGFloat, force: Bool = false) {
            contentTrailingInset = inset
            // 阈值取 8pt。这个值会写进 CSS 变量，每次下发都是一次整页重排；
            // 第三列展开时列宽逐帧变化，0.5pt 的阈值等于每帧都重排一次。
            // 8pt 以内的偏移肉眼看不出来，却能把重排次数压到个位数。
            guard isReady,
                  force || appliedContentTrailingInset.map({ abs($0 - inset) > 8 }) != false,
                  let webView
            else { return }
            appliedContentTrailingInset = inset
            Task { @MainActor in
                _ = try? await webView.callAsyncJavaScript(
                    "document.documentElement.style.setProperty('--context-panel-inset', `${pixels}px`)",
                    arguments: ["pixels": Double(inset)],
                    in: nil,
                    contentWorld: .page
                )
            }
        }

        /// 刻度条的让位。和 trailing 一样是 CSS 变量，同样要防抖——
        /// 它只有"有/没有"两种值，但列宽逐帧变化时上层可能反复下发同一个数。
        func updateContentLeadingInset(_ inset: CGFloat, force: Bool = false) {
            contentLeadingInset = inset
            guard isReady,
                  force || appliedContentLeadingInset.map({ abs($0 - inset) > 0.5 }) != false,
                  let webView
            else { return }
            appliedContentLeadingInset = inset
            Task { @MainActor in
                _ = try? await webView.callAsyncJavaScript(
                    "document.documentElement.style.setProperty('--conversation-rail-inset', `${pixels}px`)",
                    arguments: ["pixels": Double(inset)],
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
            guard navigationAction.navigationType == .linkActivated,
                  let url = navigationAction.request.url
            else {
                decisionHandler(.allow)
                return
            }
            if ["http", "https"].contains(url.scheme?.lowercased() ?? "") {
                onOpenURL?(url)
            }
            decisionHandler(.cancel)
        }

        func webView(
            _ webView: WKWebView,
            createWebViewWith configuration: WKWebViewConfiguration,
            for navigationAction: WKNavigationAction,
            windowFeatures: WKWindowFeatures
        ) -> WKWebView? {
            guard let url = navigationAction.request.url,
                  ["http", "https"].contains(url.scheme?.lowercased() ?? "")
            else { return nil }
            onOpenURL?(url)
            return nil
        }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            if message.name == "conversationAction", message.body as? String == "retry" {
                onRetry?()
                return
            }
            if message.name == "copyCode", let code = message.body as? String, !code.isEmpty {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(code, forType: .string)
                return
            }
            if message.name == "agentJump",
               let payload = message.body as? [String: Any],
               let kind = payload["kind"] as? String, !kind.isEmpty {
                onAgentJump?(kind, payload["id"] as? String ?? "")
                return
            }
            if message.name == "bilibiliView",
               let payload = message.body as? [String: Any],
               let bvid = payload["bvid"] as? String {
                let webView = self.webView
                Task { @MainActor in
                    guard let info = await BilibiliAPIClient.view(bvid: bvid) else { return }
                    _ = try? await webView?.callAsyncJavaScript(
                        "window.__applyBilibiliView(info)",
                        arguments: ["info": info.bridgePayload],
                        in: nil,
                        contentWorld: .page
                    )
                }
                return
            }
            if message.name == "leetcodeSolution",
               let payload = message.body as? [String: Any],
               let problemSlug = payload["problemSlug"] as? String,
               let articleSlug = payload["articleSlug"] as? String {
                let webView = self.webView
                Task { @MainActor in
                    guard let info = await LeetCodeAPIClient.shared.solutionCard(
                        problemSlug: problemSlug,
                        articleSlug: articleSlug
                    ) else { return }
                    _ = try? await webView?.callAsyncJavaScript(
                        "window.__applyLeetCodeSolution(info)",
                        arguments: ["info": info],
                        in: nil,
                        contentWorld: .page
                    )
                }
                return
            }
            guard
                message.name == "questionRail",
                let payload = message.body as? [String: Any],
                let id = payload["id"] as? String
            else { return }
            onQuestionActivity?(id, payload["scrolling"] as? Bool ?? false)
        }

        func scrollToQuestionIfNeeded(_ id: String?, revision: Int) {
            guard isReady, let id, revision != lastScrollTargetRevision, let webView else { return }
            lastScrollTargetID = id
            lastScrollTargetRevision = revision
            Task { @MainActor in
                _ = try? await webView.callAsyncJavaScript(
                    "scrollToQuestion(id)",
                    arguments: ["id": id],
                    in: nil,
                    contentWorld: .page
                )
            }
        }

        func renderIfNeeded(force: Bool = false) {
            guard isReady else { return }
            renderWorkItem?.cancel()
            let work = DispatchWorkItem { [weak self] in
                self?.performRender(force: force)
            }
            renderWorkItem = work
            let elapsed = Date().timeIntervalSince(lastRenderAt)
            if force || elapsed >= 0.05 {
                DispatchQueue.main.async(execute: work)
            } else {
                DispatchQueue.main.asyncAfter(deadline: .now() + (0.05 - elapsed), execute: work)
            }
        }

        private func performRender(force: Bool) {
            guard let webView else { return }
            lastRenderAt = Date()
            let generationSignature = generation.map(Self.generationSignature) ?? ""
            let baseChanged = force || renderedRevision != conversationRevision
            guard baseChanged || generationSignature != renderedGenerationSignature else { return }
            let previousGenerationID = renderedGenerationID
            renderedRevision = conversationRevision
            renderedGenerationSignature = generationSignature
            renderedGenerationID = generation?.messageID
            Task { @MainActor in
                do {
                    if baseChanged {
                        var payload = messages.map(Self.messagePayload)
                        if let generation {
                            let rendered = Self.generationPayload(generation)
                            if let index = payload.firstIndex(where: { $0["id"] == generation.messageID }) {
                                payload[index] = rendered
                            } else {
                                payload.append(rendered)
                            }
                        }
                        _ = try await webView.callAsyncJavaScript(
                            "await renderConversation(messages)",
                            arguments: ["messages": payload],
                            in: nil,
                            contentWorld: .page
                        )
                    } else if let generation {
                        _ = try await webView.callAsyncJavaScript(
                            "await updateConversationMessage(message, previousID)",
                            arguments: [
                                "message": Self.generationPayload(generation),
                                "previousID": previousGenerationID ?? ""
                            ],
                            in: nil,
                            contentWorld: .page
                        )
                    } else if let previousGenerationID {
                        _ = try await webView.callAsyncJavaScript(
                            "removeConversationMessage(id)",
                            arguments: ["id": previousGenerationID],
                            in: nil,
                            contentWorld: .page
                        )
                    }
                } catch {
                    NSLog("Rich conversation render failed: %@", error.localizedDescription)
                }
            }
        }

        private static func messagePayload(_ message: ConversationTranscriptMessage) -> [String: String] {
            [
                "id": message.id,
                "role": message.role,
                "content": message.content,
                "state": "",
                "detail": "",
                "reasoning": "",
                "tools": message.toolCalls.map(\.conversationToolDisplayName).joined(separator: ","),
                "agentRuns": agentRunsJSON(message.agentRuns),
                "artifacts": artifactsJSON(message.artifacts)
            ]
        }

        private static func generationPayload(_ generation: ConversationGenerationSnapshot) -> [String: String] {
            [
                "id": generation.messageID,
                "role": "assistant",
                "content": generation.content,
                "state": generation.phase.rawValue,
                "detail": generation.detail ?? "",
                "reasoning": generation.reasoning,
                "tools": generation.toolCalls.map(\.conversationToolDisplayName).joined(separator: ","),
                "agentRuns": agentRunsJSON(generation.agentRuns),
                "elapsed": "\(generation.elapsedSeconds)",
                "artifacts": "[]"
            ]
        }

        private static func generationSignature(_ generation: ConversationGenerationSnapshot) -> String {
            "\(generation.messageID):\(generation.content.hashValue):\(generation.reasoning.hashValue):\(generation.phase.rawValue):\(generation.detail ?? ""):\(generation.toolCalls.hashValue):\(generation.agentRuns.hashValue):\(generation.elapsedSeconds)"
        }

        /// 工具卡片的数据。`result` 本身就是工具产出的那份 JSON 字符串，
        /// 页面侧解析后按 `layout` 选渲染方式——界面看到的和模型看到的是同一份。
        private static func agentRunsJSON(_ runs: [AgentToolRun]) -> String {
            let value = runs.map { run -> [String: String] in
                ["id": run.id, "name": run.name, "arguments": run.arguments, "result": run.resultJSON]
            }
            guard JSONSerialization.isValidJSONObject(value),
                  let data = try? JSONSerialization.data(withJSONObject: value)
            else { return "[]" }
            return String(decoding: data, as: UTF8.self)
        }

        private static func artifactsJSON(_ artifacts: [ConversationArtifact]) -> String {
            let value = artifacts.map { artifact in
                ["type": artifact.type, "url": artifact.url, "title": artifact.title]
            }
            guard JSONSerialization.isValidJSONObject(value),
                  let data = try? JSONSerialization.data(withJSONObject: value),
                  let json = String(data: data, encoding: .utf8)
            else { return "[]" }
            return json
        }
    }
}
