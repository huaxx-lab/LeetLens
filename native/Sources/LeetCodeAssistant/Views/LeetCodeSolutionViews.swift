import SwiftUI
import WebKit

/// 题面底部现有胶囊：点赞、题解、收藏、浏览器打开、提示与实时在线人数。
struct LeetCodeQuestionActionBar: View {
    let meta: LeetCodeQuestionMeta
    let titleSlug: String
    let dataDirectory: URL
    var onOpenSolutions: () -> Void
    var onOpenInBrowser: (URL) -> Void

    @State private var showsHints = false
    @State private var onlineCount: Int?
    @State private var chineseHints: [String] = []
    @State private var hintError = ""
    @State private var isTranslatingHints = false

    var body: some View {
        HStack(spacing: AppDesign.Spacing.xs) {
            metric(
                systemImage: meta.isLiked == true ? "hand.thumbsup.fill" : "hand.thumbsup",
                text: Self.compactCount(meta.likes),
                tint: meta.isLiked == true ? Color.accentColor : .secondary
            )

            Button(action: onOpenSolutions) {
                chipLabel(systemImage: "bubble.left", text: Self.compactCount(meta.solutionCount), tint: .secondary)
            }
            .buttonStyle(.plain)
            .help("查看题解")

            Divider().frame(height: 14)

            metric(
                systemImage: meta.isFavorite ? "star.fill" : "star",
                text: nil,
                tint: meta.isFavorite ? .orange : .secondary
            )

            Button {
                guard let url = URL(string: "https://leetcode.cn/problems/\(titleSlug)/") else { return }
                onOpenInBrowser(url)
            } label: {
                chipLabel(systemImage: "arrow.up.forward.square", text: nil, tint: .secondary)
            }
            .buttonStyle(.plain)
            .help("在浏览器中打开")

            if !meta.hints.isEmpty {
                Button {
                    showsHints.toggle()
                    if showsHints && chineseHints.isEmpty {
                        Task { await loadChineseHints() }
                    }
                } label: {
                    chipLabel(systemImage: "questionmark.circle", text: nil, tint: showsHints ? Color.accentColor : .secondary)
                }
                .buttonStyle(.plain)
                .help("查看提示（\(meta.hints.count) 条）")
                .popover(isPresented: $showsHints, arrowEdge: .top) {
                    hintsPopover
                }
            }

            Spacer(minLength: AppDesign.Spacing.sm)
                .frame(width: AppDesign.Spacing.sm)

            if let onlineCount, onlineCount > 0 {
                HStack(spacing: 6) {
                    Circle()
                        .fill(AppDesign.ColorToken.success)
                        .frame(width: 7, height: 7)
                    Text("\(onlineCount) 人在线")
                        .font(AppDesign.Typography.aux.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .padding(.horizontal, 8)
                .frame(height: 24)
                .help("当前正在查看这道题的人数")
            }
        }
        // 胶囊浮层，不是撑满一行的工具条——力扣官网就是这么摆的，
        // 题面照旧铺满窗格，这条压在它上面。
        .padding(.horizontal, 4)
        .frame(height: 32)
        .fixedSize(horizontal: true, vertical: false)
        .navigationGlass(cornerRadius: 16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .task(id: titleSlug) { await receiveOnlineCount() }
        .onChange(of: titleSlug) { _, _ in
            chineseHints = []
            hintError = ""
            isTranslatingHints = false
        }
    }

    private var hintsPopover: some View {
        VStack(alignment: .leading, spacing: AppDesign.Spacing.xs) {
            Text("官方提示")
                .font(AppDesign.Typography.auxEmphasis)
            if isTranslatingHints {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("正在准备中文提示…")
                        .font(AppDesign.Typography.aux)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } else if !hintError.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text(hintError)
                        .font(AppDesign.Typography.aux)
                        .foregroundStyle(.secondary)
                    Button("重试") { Task { await loadChineseHints() } }
                        .buttonStyle(.borderless)
                }
            } else {
                ForEach(Array(chineseHints.enumerated()), id: \.offset) { index, hint in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("\(index + 1)")
                            .font(AppDesign.Typography.micro.monospacedDigit().weight(.semibold))
                            .foregroundStyle(.secondary)
                            .frame(width: 16, height: 16)
                            .background(Color.primary.opacity(0.06), in: Circle())
                        Text(LeetCodeQuestionActionBar.plainText(hint))
                            .font(AppDesign.Typography.aux)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
        .padding(14)
        .frame(width: 320)
    }

    private func metric(systemImage: String, text: String?, tint: Color) -> some View {
        chipLabel(systemImage: systemImage, text: text, tint: tint)
    }

    private func chipLabel(systemImage: String, text: String?, tint: Color) -> some View {
        HStack(spacing: 5) {
            Image(systemName: systemImage)
                .font(AppDesign.Typography.iconCompact)
            if let text {
                Text(text)
                    .font(AppDesign.Typography.aux.monospacedDigit())
            }
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 8)
        .frame(height: 24)
        .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    }

    /// 21243 → "21.2K"，与力扣官网口径一致。
    static func compactCount(_ value: Int) -> String {
        if value < 1_000 { return "\(value)" }
        if value < 1_000_000 {
            let scaled = Double(value) / 1_000
            return scaled < 10
                ? String(format: "%.1fK", scaled)
                : "\(Int(scaled.rounded()))K"
        }
        return String(format: "%.1fM", Double(value) / 1_000_000)
    }

    static func plainText(_ html: String) -> String {
        html.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func receiveOnlineCount() async {
        onlineCount = nil
        guard titleSlug.range(of: #"^[a-z0-9][a-z0-9-]{0,99}$"#, options: [.regularExpression, .caseInsensitive]) != nil,
              let url = URL(string: "wss://collaboration-ws.leetcode.cn/problems/\(titleSlug)")
        else { return }
        for attempt in 0..<5 {
            let socket = URLSession.shared.webSocketTask(with: url)
            socket.resume()
            do {
                while !Task.isCancelled {
                    let message = try await socket.receive()
                    let raw: String
                    switch message {
                    case let .string(value): raw = value
                    case let .data(value): raw = String(decoding: value, as: UTF8.self)
                    @unknown default: continue
                    }
                    if let value = Int(raw), value > 0, value != onlineCount {
                        onlineCount = value
                    }
                }
                socket.cancel(with: .normalClosure, reason: nil)
                return
            } catch {
                socket.cancel(with: .goingAway, reason: nil)
                guard !Task.isCancelled else { return }
                if attempt < 4 {
                    try? await Task.sleep(for: .seconds(attempt + 1))
                }
            }
        }
        onlineCount = nil
    }

    private func loadChineseHints() async {
        isTranslatingHints = true
        hintError = ""
        defer { isTranslatingHints = false }
        do {
            let translator = LeetCodeHintTranslator(dataDirectory: dataDirectory)
            let translated = try await translator.chineseHints(titleSlug: titleSlug, hints: meta.hints)
            guard !Task.isCancelled else { return }
            chineseHints = translated
        } catch {
            hintError = "中文提示暂时不可用，请检查「模型供应商」中的 LeetCode 分析模型。"
        }
    }
}

/// 题解正文。Markdown 交给 `solution.html` 渲染——
/// 图集切换、多语言代码标签页、复制按钮都在那边，SwiftUI 侧只负责喂数据。
struct LeetCodeSolutionWebView: NSViewRepresentable {
    let article: LeetCodeSolutionArticle
    let onOpenURL: (URL) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onOpenURL: onOpenURL) }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        configuration.userContentController.add(context.coordinator, name: "copyCode")
        WebViewPresentation.applyFloatingScrollbars(in: configuration)
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator.popups
        webView.setValue(false, forKey: "drawsBackground")
        context.coordinator.pending = article
        if let url = Bundle.module.url(forResource: "solution", withExtension: "html", subdirectory: "RichContent")
            ?? Bundle.module.url(forResource: "solution", withExtension: "html") {
            webView.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        }
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        guard context.coordinator.pending != article else { return }
        context.coordinator.pending = article
        context.coordinator.flush(into: webView)
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        var pending: LeetCodeSolutionArticle?
        private var isLoaded = false
        let popups = WebViewPopupBridge()
        let onOpenURL: (URL) -> Void

        init(onOpenURL: @escaping (URL) -> Void) {
            self.onOpenURL = onOpenURL
            popups.createWebViewHandler = { _, action, _ in
                guard let url = action.request.url else { return nil }
                onOpenURL(url)
                return nil
            }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            isLoaded = true
            flush(into: webView)
        }

        func userContentController(
            _ userContentController: WKUserContentController,
            didReceive message: WKScriptMessage
        ) {
            guard message.name == "copyCode",
                  let code = message.body as? String,
                  !code.isEmpty
            else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(code, forType: .string)
        }

        /// 题解正文里链接很多，点了应该去系统浏览器，而不是把渲染页面本身导航走。
        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction
        ) async -> WKNavigationActionPolicy {
            guard navigationAction.navigationType == .linkActivated,
                  let url = navigationAction.request.url
            else { return .allow }
            onOpenURL(url)
            return .cancel
        }

        func flush(into webView: WKWebView) {
            guard isLoaded, let article = pending else { return }
            Task { @MainActor [weak webView] in
                guard let webView else { return }
                _ = try? await webView.callAsyncJavaScript(
                    "window.__renderSolution(markdown, videos)",
                    arguments: [
                        "markdown": article.markdown,
                        "videos": article.videos.map(\.javaScriptValue)
                    ],
                    in: nil,
                    contentWorld: .page
                )
            }
        }
    }
}

/// 刷题时的上一题 / 下一题。在**当前筛选后的列表**里走，
/// 用户看到的顺序和跳转顺序必须一致——否则按下一题会跳到列表里根本没显示的题。
enum LeetCodeProblemNavigator {
    struct Position: Equatable {
        var index: Int
        var total: Int
        var previousSlug: String?
        var nextSlug: String?

        var display: String { "\(index + 1) / \(total)" }
    }

    static func position(of slug: String?, in slugs: [String]) -> Position? {
        guard let slug, let index = slugs.firstIndex(of: slug) else { return nil }
        return Position(
            index: index,
            total: slugs.count,
            previousSlug: index > 0 ? slugs[index - 1] : nil,
            nextSlug: index + 1 < slugs.count ? slugs[index + 1] : nil
        )
    }
}

/// 上一题 / 下一题。一对胶囊按钮夹着进度，禁用态只降透明度不换形状，
/// 免得到头时按钮尺寸跳变、整条工具栏跟着抖。
struct LeetCodeProblemNavBar: View {
    let position: LeetCodeProblemNavigator.Position
    let onSelect: (String) -> Void

    var body: some View {
        HStack(spacing: 2) {
            step(systemImage: "chevron.left", slug: position.previousSlug, help: "上一题")
            Text(position.display)
                .font(AppDesign.Typography.micro.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(minWidth: 46)
            step(systemImage: "chevron.right", slug: position.nextSlug, help: "下一题")
        }
        .padding(.horizontal, 3)
        .frame(height: 26)
        .inlineGlass(cornerRadius: 13)
    }

    private func step(systemImage: String, slug: String?, help: String) -> some View {
        Button {
            if let slug { onSelect(slug) }
        } label: {
            Image(systemName: systemImage)
                .font(.system(size: 11, weight: .semibold))
                .frame(width: 22, height: 22)
                .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(slug == nil)
        .opacity(slug == nil ? 0.3 : 1)
        .help(help)
    }
}

/// 题解浏览：左边列表、右边正文。正文渲染在 `solution.html` 里，
/// 图集切换 / 多语言标签页 / 复制都在那边。
struct LeetCodeSolutionsBrowser: View {
    let titleSlug: String
    let title: String
    let onOpenURL: (URL) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var page = LeetCodeSolutionPage()
    @State private var selected: LeetCodeSolutionSummary?
    @State private var article: LeetCodeSolutionArticle?
    @State private var listError = ""
    @State private var articleError = ""
    @State private var isLoadingList = true
    @State private var isLoadingArticle = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: AppDesign.Spacing.xs) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(article?.title ?? title).font(AppDesign.Typography.rowTitleEmphasis).lineLimit(1)
                    Text(article == nil && page.total > 0 ? "\(page.total) 篇题解" : (selected?.authorName ?? "题解"))
                        .font(AppDesign.Typography.micro)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: AppDesign.Spacing.xs)
                Button { dismiss() } label: {
                    Image(systemName: "xmark")
                        .font(AppDesign.Typography.iconCompact)
                        .frame(width: 26, height: 26)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("关闭")
            }
            .padding(.horizontal, AppDesign.Spacing.rowInset)
            .frame(height: 46)

            Divider()

            HStack(spacing: 0) {
                solutionList
                    .frame(width: 248)
                Divider()
                solutionDetail
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: 980, idealWidth: 1180, maxWidth: 1440)
        .frame(minHeight: 700, idealHeight: 800, maxHeight: 1040)
        .background(AppDesign.ColorToken.canvas)
        .task { await loadList() }
        .task(id: selected?.slug) { await loadArticle() }
    }

    private var solutionList: some View {
        Group {
            if isLoadingList {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if !listError.isEmpty {
                ContentUnavailableView("题解读取失败", systemImage: "exclamationmark.triangle", description: Text(listError))
            } else {
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(page.items) { item in
                            Button { selected = item } label: { row(item) }
                                .buttonStyle(.plain)
                        }
                    }
                    .padding(6)
                }
                .floatingScrollIndicators()
            }
        }
    }

    private func row(_ item: LeetCodeSolutionSummary) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(item.title)
                .font(AppDesign.Typography.bodyEmphasis)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
            HStack(spacing: 6) {
                // 官方题解（作者 LeetCode-Solution）单独标出来——列表里最该先看的就是它。
                if item.isOfficial {
                    Text("官方")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 3, style: .continuous))
                }
                Text(item.authorName).lineLimit(1)
                Spacer(minLength: 4)
                Image(systemName: "eye").font(.system(size: 9))
                Text(LeetCodeQuestionActionBar.compactCount(item.views)).monospacedDigit()
            }
            .font(AppDesign.Typography.micro)
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, AppDesign.Spacing.compact)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            selected?.id == item.id ? Color.primary.opacity(0.06) : .clear,
            in: RoundedRectangle(cornerRadius: AppDesign.Radius.medium, style: .continuous)
        )
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private var solutionDetail: some View {
        if isLoadingArticle {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if !articleError.isEmpty {
            ContentUnavailableView(
                "题解正文读取失败",
                systemImage: "exclamationmark.triangle",
                description: Text(articleError)
            )
        } else if let article {
            LeetCodeSolutionWebView(article: article, onOpenURL: onOpenURL)
        } else {
            ContentUnavailableView("选择一篇题解", systemImage: "doc.text")
        }
    }

    private func loadList() async {
        isLoadingList = true
        defer { isLoadingList = false }
        do {
            page = try await LeetCodeAPIClient.shared.fetchSolutions(titleSlug: titleSlug)
            selected = page.items.first(where: \.isOfficial) ?? page.items.first
        } catch {
            listError = error.localizedDescription
        }
    }

    private func loadArticle() async {
        guard let slug = selected?.slug else { return }
        isLoadingArticle = true
        articleError = ""
        defer { isLoadingArticle = false }
        do {
            article = try await LeetCodeAPIClient.shared.fetchSolutionArticle(slug: slug)
        } catch {
            article = nil
            articleError = error.localizedDescription
        }
    }
}
