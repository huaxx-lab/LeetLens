import SwiftUI

/// 刷题页的 AI 助手浮窗。
///
/// **放哪儿**：浮在题面那一栏上。代码在右边始终看得见；关掉浮窗题面原样还在。
/// 不另开一列（笔记本屏上四列根本排不下），也不跳去对话页（跳过去再回来，
/// 以前连代码都会丢）。
///
/// **一个入口两种用法**：
/// - 问答：和对话页同一条管线，发送时自动附带题面、当前代码、选中行与最近一次评测；
///   会话照常进最近会话，可以去对话页接着聊。
/// - 分级提示：原来编辑器工具条上那颗「AI 提示」，一级一级要，不给完整解法。
struct LeetCodeAssistantCard: View {
    @Bindable var workspace: WorkspaceState
    @Bindable var dataStore: LegacyDataStore
    @Bindable var session: LeetCodeCodingSession
    let question: LeetCodeQuestion
    /// 题面数据。可能为 nil（未登录 / 读取失败）：问答照常可用，只是少了题面；
    /// 分级提示依赖题面，这时给出说明而不是整个浮窗打不开。
    let questionWorkspace: LeetCodeQuestionWorkspace?
    let difficultyTitle: String
    /// 挂在标题栏上的拖动手势，由 `FloatingPanelHost` 提供。
    var moveGesture: AnyGesture<DragGesture.Value>? = nil

    private var slug: String { question.titleSlug }

    private var conversationID: String? {
        session.assistantConversationID(for: slug, existing: Set(dataStore.conversations.map(\.id)))
    }

    private var isGeneratingHere: Bool {
        guard let conversationID else { return false }
        return workspace.conversationGeneration?.conversationID == conversationID
            && workspace.conversationGeneration?.phase == .generating
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle().fill(AppDesign.ColorToken.separator).frame(height: 1)
            switch session.assistantMode {
            case .chat: chat
            case .hints: hints
            }
        }
        .background(AppDesign.ColorToken.canvas)
        .clipShape(RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.09))
        }
        .shadow(color: .black.opacity(0.10), radius: 3, y: 1)
        .shadow(color: .black.opacity(0.12), radius: 24, y: 12)
        .onExitCommand {
            guard !isGeneratingHere else { return }
            close()
        }
    }

    // MARK: - 头部

    private static let cornerRadius: CGFloat = 14

    /// 标题栏整条可以拖：按住空白处移动浮窗。按钮和标签照常点击（拖动要先移动 3pt 才触发）。
    private var header: some View {
        HStack(spacing: AppDesign.Spacing.sm) {
            HStack(spacing: AppDesign.Spacing.compact) {
                ForEach(LeetCodeAssistantMode.allCases) { mode in
                    ModeTab(title: mode.title, isSelected: session.assistantMode == mode) {
                        session.assistantMode = mode
                    }
                }
            }

            Spacer(minLength: AppDesign.Spacing.xs)

            if session.assistantMode == .chat, conversationID != nil {
                HeaderIconButton(systemName: "arrow.up.forward.app", help: "在对话页继续这段问答") {
                    guard let conversationID else { return }
                    workspace.selectedConversationID = conversationID
                    workspace.selectedSection = .conversation
                }
                HeaderIconButton(
                    systemName: "square.and.pencil",
                    help: "就这道题新开一段问答",
                    disabled: isGeneratingHere
                ) {
                    session.setAssistantConversationID(nil, for: slug)
                }
            } else if session.assistantMode == .hints, !session.hints(for: slug).isEmpty, let questionWorkspace {
                HeaderIconButton(
                    systemName: "arrow.clockwise",
                    help: "按当前代码重新给一轮提示",
                    disabled: session.isHinting
                ) {
                    session.restartHints()
                    Task { await session.requestHint(question: question, workspace: questionWorkspace, dataStore: dataStore) }
                }
            }
            HeaderIconButton(systemName: "xmark", help: "收起（Esc）") {
                close()
            }
        }
        .padding(.leading, AppDesign.Spacing.md)
        .padding(.trailing, AppDesign.Spacing.xs)
        .frame(height: AppDesign.Size.pageHeader - 4)
        .contentShape(Rectangle())
        .pointerStyle(.grabIdle)
        .gesture(moveGesture ?? AnyGesture(DragGesture(minimumDistance: .infinity)))
        .help("拖动标题栏移动浮窗")
    }

    private func close() {
        withAnimation(AppDesign.Motion.selection) { session.isAssistantPresented = false }
    }

    // MARK: - 问答

    private var chat: some View {
        ConversationWorkspaceView(
            workspace: workspace,
            dataStore: dataStore,
            embedding: ConversationEmbedding(
                conversationID: conversationID,
                draft: Binding(
                    get: { session.assistantDrafts[slug] ?? "" },
                    set: { session.assistantDrafts[slug] = $0 }
                ),
                placeholder: "问这道题，或者问你的代码…",
                newConversationTitle: { prompt in
                    "\(question.frontendID). \(question.title) · \(String(prompt.prefix(24)))"
                },
                onConversationCreated: { id in
                    session.setAssistantConversationID(id, for: slug)
                },
                contextPrompt: contextPrompt,
                emptyState: AnyView(emptyState),
                composerAccessory: AnyView(composerAccessory),
                onAssistantReply: { reply in
                    // 回答里点到了具体行（"第 8 行 p++ 应为 i++"），就把它落到编辑器里：
                    // 标出位置、给出可一键接受的修改，不用自己对着行号去找。
                    guard let questionWorkspace,
                          CodeReviewPolicy.mentionsSpecificLines(reply),
                          session.documentID.hasPrefix(slug + "|")
                    else { return }
                    session.requestReview(.assistantReply(reply), question: question, workspace: questionWorkspace, dataStore: dataStore)
                }
            )
        )
        // 换题时整块重建：WebView 里还渲染着上一题的对话。
        .id(slug)
    }

    private func contextPrompt() -> String? {
        let isOnCurrentDocument = session.documentID.hasPrefix(slug + "|")
        let judge = session.judgeState(for: slug)
        return LeetCodeAssistantContext.prompt(LeetCodeAssistantContext.Input(
            frontendID: question.frontendID,
            title: question.title,
            difficulty: difficultyTitle,
            statement: questionWorkspace.map { LeetCodeQuestionActionBar.plainText($0.htmlContent) } ?? "",
            language: session.language,
            code: session.attachesCode && isOnCurrentDocument ? session.code : nil,
            isPristine: session.isPristine,
            selection: session.attachesSelection && isOnCurrentDocument ? session.selection : nil,
            judgeResult: session.attachesJudgeResult ? judge.result : nil,
            diagnostics: session.attachesCode && isOnCurrentDocument ? session.diagnostics.issues : []
        ))
    }

    /// 还没问过时给几条"这会儿最可能想问的"，按当前状态挑。
    private var suggestions: [(title: String, prompt: String, systemImage: String)] {
        var items: [(String, String, String)] = []
        let judge = session.judgeState(for: slug)
        if let result = judge.result, !result.accepted {
            items.append(("为什么没通过", "我的代码为什么没通过？请结合失败用例指出问题出在哪，先不要给完整代码。", "xmark.octagon"))
        }
        if let selection = session.selection, session.documentID.hasPrefix(slug + "|") {
            items.append(("解释选中的\(selection.lineCaption)", "解释一下我选中的这几行在做什么，有没有问题？", "text.cursor"))
        }
        if session.isPristine {
            items.append(("我该从哪入手", "这道题我还没思路。请只给我一个切入方向和需要想清楚的关键问题，不要给代码。", "signpost.right"))
        } else {
            items.append(("检查我的思路", "帮我检查当前代码的思路是否正确，指出隐藏的 bug 和没考虑到的边界情况，不要直接给答案。", "checklist"))
        }
        items.append(("分析复杂度", "分析我当前代码的时间和空间复杂度，并说明瓶颈在哪一行。", "gauge.with.dots.needle.33percent"))
        items.append(("有哪些边界情况", "这道题需要注意哪些边界情况？给出几个容易出错的测试用例。", "exclamationmark.triangle"))
        return Array(items.prefix(4))
    }

    /// 还没问过：内容贴着输入框往上排（视线本来就在输入框附近），上面留白。
    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 0) {
            Spacer(minLength: AppDesign.Spacing.md)
            Text("关于「\(question.title)」")
                .font(AppDesign.Typography.headline)
                .lineLimit(1)
            Text(questionWorkspace == nil
                 ? "题面还没读到（可能未登录力扣），AI 只能看到题名和你的代码。"
                 : "题面、你的代码和最近一次评测会自动带上。")
                .font(AppDesign.Typography.aux)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 2)
                .padding(.bottom, AppDesign.Spacing.sm)
            ForEach(Array(suggestions.enumerated()), id: \.element.title) { index, item in
                if index > 0 {
                    Rectangle().fill(AppDesign.ColorToken.separator).frame(height: 1)
                }
                SuggestionRow(title: item.title, systemImage: item.systemImage) {
                    session.assistantDrafts[slug] = item.prompt
                }
            }
        }
        .padding(.horizontal, AppDesign.Spacing.md)
        .padding(.bottom, AppDesign.Spacing.xs)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var composerAccessory: some View {
        VStack(alignment: .leading, spacing: AppDesign.Spacing.xxs) {
            reviewStatus
            attachmentBar
        }
    }

    /// 回答被标到代码上之后，在问答这边也给个回音，免得用户不知道编辑器里多了东西。
    @ViewBuilder
    private var reviewStatus: some View {
        let count = session.visibleSuggestions.count
        if session.isReviewing || count > 0 {
            HStack(spacing: 6) {
                if session.isReviewing {
                    ProgressView().controlSize(.mini).frame(width: 12, height: 12)
                    Text("正在把建议标到代码里…")
                } else {
                    Image(systemName: "sparkles").foregroundStyle(Color.accentColor)
                    Text("已在代码中标注 \(count) 处")
                    if !session.isSolving {
                        Button("去作答查看") { session.isSolving = true }
                            .buttonStyle(.plain)
                            .foregroundStyle(Color.accentColor)
                    } else {
                        Button("全部接受") { session.acceptAllSuggestions() }
                            .buttonStyle(.plain)
                            .foregroundStyle(Color.accentColor)
                    }
                }
            }
            .font(AppDesign.Typography.micro)
            .foregroundStyle(.secondary)
            .padding(.horizontal, AppDesign.Spacing.md)
        }
    }

    /// 输入框上方一条"这次会带上什么"。点一下切换，不想附带代码时关掉就行。
    private var attachmentBar: some View {
        let judge = session.judgeState(for: slug)
        let lineCount = session.code.isEmpty ? 0 : session.code.split(separator: "\n", omittingEmptySubsequences: false).count
        return ScrollView(.horizontal) {
            HStack(spacing: 6) {
                AttachmentChip(
                    title: session.isPristine ? "\(languageName) · 初始模板" : "\(languageName) · \(lineCount) 行",
                    systemImage: "chevron.left.forwardslash.chevron.right",
                    isOn: $session.attachesCode
                )
                if let selection = session.selection, session.documentID.hasPrefix(slug + "|") {
                    AttachmentChip(title: "选中\(selection.lineCaption)", systemImage: "text.cursor", isOn: $session.attachesSelection)
                }
                if let result = judge.result {
                    AttachmentChip(
                        title: result.accepted ? "评测 · 通过" : "评测 · \(result.status)",
                        systemImage: result.accepted ? "checkmark.seal" : "xmark.seal",
                        isOn: $session.attachesJudgeResult
                    )
                }
            }
            .padding(.horizontal, AppDesign.Spacing.md)
        }
        .scrollIndicators(.never)
        .help("发送时自动附带的上下文，点击可以关掉")
    }

    private var languageName: String {
        questionWorkspace?.snippets.first { $0.languageSlug == session.language }?.language ?? session.language
    }

    // MARK: - 分级提示
    //
    // 交互刻意做成"一级一级要"：先只给方向，卡住了再点「还想不出来」才给卡点，
    // 最后才给下一步该做什么。每一级都读当前编辑器里的代码，
    // 但提示词禁止给完整解法——直接把答案贴出来，这道题就白做了。

    private var hints: some View {
        let hints = session.hints(for: slug)
        return ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("只给方向和卡点，不给完整解法")
                    .font(AppDesign.Typography.aux)
                    .foregroundStyle(.secondary)
                ForEach(hints) { hint in
                    hintCard(hint)
                }
                if session.isHinting {
                    HStack(spacing: 7) {
                        ProgressView().controlSize(.small)
                        Text(hints.isEmpty ? "正在读你的代码…" : "再想想怎么说更具体…")
                            .font(AppDesign.Typography.aux)
                            .foregroundStyle(.secondary)
                    }
                }
                if !session.hintError.isEmpty {
                    Label(session.hintError, systemImage: "exclamationmark.triangle")
                        .font(AppDesign.Typography.aux)
                        .foregroundStyle(AppDesign.ColorToken.warning)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if questionWorkspace == nil {
                    Label("分级提示要先读到题面。登录力扣后重新加载题目即可使用。", systemImage: "info.circle")
                        .font(AppDesign.Typography.aux)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else if !session.isHinting, hints.count < 3 {
                    Button {
                        guard let questionWorkspace else { return }
                        Task { await session.requestHint(question: question, workspace: questionWorkspace, dataStore: dataStore) }
                    } label: {
                        Label(
                            hints.isEmpty ? "看看我的代码，给个方向" : (hints.count == 1 ? "还想不出来，指一下我卡在哪" : "告诉我下一步做什么"),
                            systemImage: hints.isEmpty ? "lightbulb.max" : "arrow.down.circle"
                        )
                        .font(AppDesign.Typography.bodyEmphasis)
                        .frame(maxWidth: .infinity)
                        .frame(height: AppDesign.Size.fieldHeight + 2)
                        .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .background(Color.accentColor.opacity(0.12), in: Capsule())
                    .foregroundStyle(Color.accentColor)
                }
                if hints.count >= 3 {
                    Text("到此为止。再往下就是替你写了——剩下的自己试。")
                        .font(AppDesign.Typography.aux)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(AppDesign.Spacing.md)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .floatingScrollIndicators()
    }

    private func hintCard(_ hint: CodingHint) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text(hint.levelTitle)
                    .font(AppDesign.Typography.micro.weight(.semibold))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(Color.accentColor.opacity(0.16), in: Capsule())
                    .foregroundStyle(Color.accentColor)
                if !hint.title.isEmpty {
                    Text(hint.title)
                        .font(AppDesign.Typography.auxEmphasis)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Text(InlineMarkdown.attributed(hint.hint, codeFont: AppDesign.Typography.mono))
                .font(AppDesign.Typography.body)
                .foregroundStyle(.primary)
                .lineSpacing(2.5)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            ForEach(hint.checkpoints.filter { !$0.isEmpty }, id: \.self) { point in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: "checkmark.circle")
                        .font(AppDesign.Typography.aux)
                        .foregroundStyle(Color.accentColor.opacity(0.75))
                    Text(InlineMarkdown.attributed(point))
                        .font(AppDesign.Typography.aux)
                        .foregroundStyle(.primary.opacity(0.82))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if !hint.question.isEmpty {
                Text(InlineMarkdown.attributed(hint.question))
                    .font(AppDesign.Typography.aux.italic())
                    .foregroundStyle(Color.accentColor)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .inlineGlass(cornerRadius: AppDesign.Radius.medium)
    }
}

private struct SuggestionRow: View {
    let title: String
    let systemImage: String
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: AppDesign.Spacing.xs) {
                Image(systemName: systemImage)
                    .font(AppDesign.Typography.aux)
                    .foregroundStyle(.secondary)
                    .frame(width: AppDesign.Size.iconSlot - 6)
                Text(title)
                    .font(AppDesign.Typography.body)
                    .foregroundStyle(isHovering ? Color.primary : Color.primary.opacity(0.85))
                    .lineLimit(1)
                Spacer(minLength: 0)
                Image(systemName: "arrow.turn.down.left")
                    .font(AppDesign.Typography.micro)
                    .foregroundStyle(.tertiary)
                    .opacity(isHovering ? 1 : 0)
            }
            .frame(height: AppDesign.Size.compactRow)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .help("填进输入框，改一改再发送")
    }
}

/// 标题栏里的模式切换：纯文字，选中的那个是主色加粗。不是一颗玻璃分段控件——
/// 浮窗本身已经是一层表面，再叠控件底色就花了。
private struct ModeTab: View {
    let title: String
    let isSelected: Bool
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(isSelected ? AppDesign.Typography.bodyEmphasis : AppDesign.Typography.body)
                .foregroundStyle(isSelected ? Color.primary : (isHovering ? Color.primary.opacity(0.75) : Color.secondary))
                .padding(.vertical, 4)
                .overlay(alignment: .bottom) {
                    Capsule()
                        .fill(isSelected ? Color.primary : .clear)
                        .frame(height: 2)
                        .offset(y: 3)
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
    }
}

private struct AttachmentChip: View {
    let title: String
    let systemImage: String
    @Binding var isOn: Bool

    var body: some View {
        Button {
            isOn.toggle()
        } label: {
            HStack(spacing: 4) {
                Image(systemName: isOn ? systemImage : "slash.circle")
                    .font(.appScaled(size: 10, weight: .medium))
                Text(title)
                    .font(AppDesign.Typography.micro)
                    .lineLimit(1)
                    .strikethrough(!isOn, color: .secondary)
            }
            .padding(.horizontal, 8)
            .frame(height: 22)
            .foregroundStyle(isOn ? Color.primary.opacity(0.78) : Color.secondary)
            .background(isOn ? AppDesign.ColorToken.inlineFill : Color.clear, in: Capsule())
            .overlay { Capsule().strokeBorder(Color.primary.opacity(isOn ? 0 : 0.12)) }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .fixedSize()
    }
}
