import SwiftUI
import UniformTypeIdentifiers

/// 把对话嵌进别的页面时的绑定（目前是刷题页的 AI 浮窗）。
///
/// 嵌入的对话和对话页用**同一条**生成管线：同一个全局生成槽、同一套记忆注入与工具、
/// 写进同一份 conversations.json——在刷题页问过的，对话页最近会话里也能接着聊。
/// 区别只在三处：会话由宿主指定而不是 `workspace.selectedConversationID`；
/// 输入框草稿按宿主分开存；每次发送前可以附带一段宿主现拼的上下文（当前代码等）。
struct ConversationEmbedding {
    /// nil 表示还没开，第一次发送时新建。
    var conversationID: String?
    var draft: Binding<String>
    var placeholder: String
    var newConversationTitle: @MainActor (String) -> String
    var onConversationCreated: @MainActor (String) -> Void
    /// 发送那一刻现拼的 system 上下文。不写进消息记录，见 `LeetCodeAssistantContext`。
    var contextPrompt: @MainActor () -> String?
    /// 还没有消息时显示的内容（建议问题等）。
    var emptyState: AnyView
    /// 输入框上方的一条附件条（附带了哪些上下文）。
    var composerAccessory: AnyView?
    /// 一条回答完整生成完之后回调（刷题页据此把回答里点到的行标到代码上）。
    var onAssistantReply: (@MainActor (String) -> Void)? = nil
}

struct ConversationWorkspaceView: View {
    @Bindable var workspace: WorkspaceState
    @Bindable var dataStore: LegacyDataStore
    var contentTrailingInset: CGFloat = 0
    /// 左侧问题刻度条占掉的一条：正文与输入框都从这里之后开始排。
    var contentLeadingInset: CGFloat = 0
    var embedding: ConversationEmbedding? = nil
    /// 这块视图自己的宽度（量化到 20pt）。输入框按它决定一行排还是两行排。
    @State private var measuredWidth: CGFloat = 0

    private var isEmbedded: Bool { embedding != nil }

    /// 输入框能用的宽度：整列减去两侧让位。
    private var composerAvailableWidth: CGFloat {
        guard measuredWidth > 0 else { return .infinity }
        return measuredWidth - contentLeadingInset - contentTrailingInset - AppDesign.Spacing.lg * 2
    }

    /// 窄到一行排不下「附件 · 输入 · 模型 · 上下文 · 推理 · 发送」时换成两行排法。
    /// 一行排法的控件加起来约 380pt，再给输入区留 140pt。
    private var usesCompactComposer: Bool {
        isEmbedded || composerAvailableWidth < AppDesign.Size.scaledControl(520)
    }

    /// 这块视图正在展示的会话。
    private var activeConversationID: String? {
        if let embedding { return embedding.conversationID }
        return workspace.selectedConversationID
    }

    private var draft: Binding<String> {
        embedding?.draft ?? $workspace.draft
    }

    var body: some View {
        if let embedding {
            embeddedBody(embedding)
        } else {
            primaryBody
        }
    }

    /// 嵌在浮窗里：上面是对话、下面是输入区，**上下排而不是叠在一起**。
    /// 对话页的输入框是浮在正文上的玻璃（正文底部留了位）；浮窗里照搬的话，
    /// 半透明输入框和附件条直接压在回答最后几行上，字透过来叠成一团。
    private func embeddedBody(_ embedding: ConversationEmbedding) -> some View {
        VStack(spacing: 0) {
            ZStack {
                conversationWebView
                    .opacity(isEmptyConversation ? 0 : 1)
                    .allowsHitTesting(!isEmptyConversation)
                if isEmptyConversation {
                    embedding.emptyState
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            VStack(alignment: .leading, spacing: AppDesign.Spacing.xxs) {
                embedding.composerAccessory
                composer
            }
            .padding(.top, AppDesign.Spacing.xs)
            .padding(.bottom, AppDesign.Spacing.compact)
            .background(AppDesign.ColorToken.canvas)
            .overlay(alignment: .top) { Hairline() }
        }
        .onGeometryChange(for: CGFloat.self) { proxy in
            (proxy.size.width / 20).rounded(.down) * 20
        } action: { measuredWidth = $0 }
    }

    private var conversationWebView: some View {
        RichConversationWebView(
            messages: conversationMessages,
            conversationRevision: selectedConversation?.revision,
            generation: visibleGeneration,
            scrollTargetID: nil,
            scrollTargetRevision: 0,
            onQuestionActivity: { _, _ in },
            onOpenURL: { url in workspace.openURL(url) },
            onRetry: retryGeneration,
            onAgentJump: handleAgentJump,
            contentTrailingInset: 0,
            contentLeadingInset: 0
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var primaryBody: some View {
        ZStack(alignment: .bottom) {
            RichConversationWebView(
                messages: conversationMessages,
                conversationRevision: selectedConversation?.revision,
                generation: visibleGeneration,
                scrollTargetID: isEmbedded ? nil : workspace.questionScrollTargetID,
                scrollTargetRevision: isEmbedded ? 0 : workspace.questionScrollRequestVersion,
                onQuestionActivity: { id, isScrolling in
                    // 问题刻度条只属于对话页；嵌入的对话不去改它的焦点。
                    guard !isEmbedded else { return }
                    workspace.updateQuestionNavigation(activeID: id, userIsScrolling: isScrolling)
                },
                onOpenURL: { url in
                    workspace.openURL(url)
                },
                onRetry: retryGeneration,
                onAgentJump: handleAgentJump,
                contentTrailingInset: contentTrailingInset,
                contentLeadingInset: contentLeadingInset
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .opacity(isEmptyConversation ? 0 : 1)
            .allowsHitTesting(!isEmptyConversation)

            if isEmptyConversation {
                ConversationEmptyStateView {
                    composer
                        .padding(.leading, contentLeadingInset)
                        .padding(.trailing, contentTrailingInset)
                }
            } else {
                composer
                    .padding(.leading, contentLeadingInset)
                    .padding(.trailing, contentTrailingInset)
                    .padding(.bottom, AppDesign.Spacing.sm)
            }
        }
        .onGeometryChange(for: CGFloat.self) { proxy in
            (proxy.size.width / 20).rounded(.down) * 20
        } action: { measuredWidth = $0 }
        // 这里**不能**给 inset 变化加动画：它会传进 WKWebView 去改 CSS 变量，
        // 每一帧补间都等于一次整页重排。第三列展开时列宽本来就在逐帧变，
        // 叠上补间就是稳定卡死。位置跳变一次远比卡住半秒好。
        .transaction(value: contentTrailingInset) { $0.animation = nil }
        .task(id: dataStore.isDataReady) {
            guard dataStore.isDataReady, !isEmbedded else { return }
            presentDailyBriefIfNeeded()
        }
    }

    private var isEmptyConversation: Bool {
        conversationMessages.isEmpty && visibleGeneration == nil
    }

    private var composer: some View {
        ComposerView(
            workspace: workspace,
            dataStore: dataStore,
            draft: draft,
            isCompact: usesCompactComposer,
            placeholder: embedding?.placeholder,
            conversation: selectedConversation,
            isGenerating: visibleGeneration?.phase == .generating,
            isBusyElsewhere: workspace.conversationGeneration?.phase == .generating && visibleGeneration == nil,
            queuedDrafts: visibleQueuedDrafts,
            onSend: sendDraft,
            onEnqueue: enqueueDraft,
            onClearQueue: clearQueue,
            onCancel: cancelGeneration,
            onInterruptAndSendQueue: interruptAndSendQueue
        )
        .frame(maxWidth: AppDesign.Size.contentColumnMaximum)
        .padding(.horizontal, isEmbedded ? AppDesign.Spacing.compact : AppDesign.Spacing.lg)
        .frame(maxWidth: .infinity)
    }

    private var selectedConversation: ConversationSummary? {
        guard let id = activeConversationID else { return nil }
        return dataStore.conversations.first { $0.id == id }
    }

    private var conversationMessages: [ConversationTranscriptMessage] {
        selectedConversation?.messages ?? []
    }

    private var visibleGeneration: ConversationGenerationSnapshot? {
        guard let id = activeConversationID, workspace.conversationGeneration?.conversationID == id else { return nil }
        return workspace.conversationGeneration
    }

    private var visibleQueuedDrafts: [QueuedConversationDraft] {
        guard let id = activeConversationID else { return [] }
        return workspace.queuedConversationID == id ? workspace.queuedConversationDrafts : []
    }

    /// 一天只新建一份简报；同一天重启 app 时选中已经存在的那份，而不是复制。
    /// 用户已选中历史会话或已经开始输入时绝不抢焦点。
    private func presentDailyBriefIfNeeded() {
        let snapshot = AgentDataSnapshot.capture(from: dataStore)
        let brief = LearningAgentTools.dailyBrief(snapshot: snapshot)
        guard workspace.presentedDailyBriefDay != brief.dayKey else { return }
        workspace.presentedDailyBriefDay = brief.dayKey
        guard workspace.selectedConversationID == nil,
              workspace.conversationGeneration == nil,
              workspace.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return }

        if let existing = dataStore.conversations.first(where: { conversation in
            conversation.messages.contains { $0.id == brief.messageID }
        }) {
            workspace.selectedConversationID = existing.id
            return
        }

        let message = ConversationTranscriptMessage(
            id: brief.messageID,
            role: "assistant",
            content: brief.content,
            createdAt: .now,
            toolCalls: brief.runs.map(\.name),
            agentRuns: brief.runs,
            providerID: "local-agent",
            model: "deterministic-daily-brief"
        )
        do {
            workspace.selectedConversationID = try dataStore.createConversation(
                title: brief.title,
                firstMessage: message
            )
        } catch {
            // 主动能力不能挡住正常聊天；下次重新进入对话页时仍可再试。
            workspace.presentedDailyBriefDay = ""
            NSLog("Daily learning brief failed: %@", error.localizedDescription)
        }
    }

    private func sendDraft(artifacts: [ConversationArtifact]) {
        let prompt = draft.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty, workspace.conversationGeneration?.phase != .generating else { return }
        draft.wrappedValue = ""

        let userMessage = ConversationTranscriptMessage(
            id: Self.messageID(),
            role: "user",
            content: prompt,
            createdAt: .now,
            artifacts: artifacts
        )
        do {
            let conversationID: String
            if let selected = activeConversationID {
                conversationID = selected
                try dataStore.appendMessage(userMessage, to: selected)
            } else if let embedding {
                conversationID = try dataStore.createConversation(
                    title: embedding.newConversationTitle(prompt),
                    firstMessage: userMessage
                )
                embedding.onConversationCreated(conversationID)
            } else {
                conversationID = try dataStore.createConversation(title: prompt, firstMessage: userMessage)
                workspace.selectedConversationID = conversationID
            }
            startGeneration(conversationID: conversationID, replacingMessageID: nil)
        } catch {
            draft.wrappedValue = prompt
            showLocalFailure(error.localizedDescription, conversationID: activeConversationID ?? "")
        }
    }

    private func retryGeneration() {
        guard let generation = workspace.conversationGeneration, generation.phase == .failed else { return }
        Task {
            let checkpoint = await ConversationRunCheckpointStore.shared.checkpoint(
                threadID: generation.conversationID,
                dataDirectory: dataStore.dataDirectory
            )
            startGeneration(
                conversationID: generation.conversationID,
                replacingMessageID: generation.messageID,
                resumedCheckpoint: checkpoint?.assistantMessageID == generation.messageID ? checkpoint : nil
            )
        }
    }

    private func startGeneration(
        conversationID: String,
        replacingMessageID: String?,
        continuityPrompt: String? = nil,
        resumedCheckpoint: ConversationRunCheckpoint? = nil
    ) {
        // 宿主上下文在点下发送的这一刻拼好：流式任务里再拼，拿到的可能已经是改过的代码。
        // 恢复则复用 checkpoint 冻结值，绝不读取已经变化的编辑器状态。
        let continuityPrompts = resumedCheckpoint?.volatileContextPrompts
            ?? [embedding?.contextPrompt(), continuityPrompt].compactMap { $0 }
        guard let conversation = dataStore.conversations.first(where: { $0.id == conversationID }),
              let userMessageID = conversation.messages.last(where: { $0.role == "user" })?.id
        else {
            showLocalFailure("没有找到本轮用户消息，无法开始生成", conversationID: conversationID)
            return
        }
        // 恢复必须复现原 run 的 ledger 边界；后来追加的消息属于别的 turn，不能混进来。
        let ledgerSequenceAtStart = resumedCheckpoint?.ledgerSequenceAtStart
            ?? ConversationLedger.latestSequence(conversation.ledgerEvents)
        workspace.conversationGenerationTask?.cancel()
        let assistantID = replacingMessageID ?? Self.messageID()
        let runID = "run_\(UUID().uuidString.lowercased())"
        let providerID = resumedCheckpoint?.providerID ?? dataStore.settings.activeProviderID
        let provider = dataStore.providers.first { $0.id == providerID }
        let runtimeIdentity = ConversationRuntimeIdentity(
            providerID: providerID,
            providerName: provider?.name ?? providerID,
            model: resumedCheckpoint?.model ?? provider?.model ?? ""
        )
        workspace.conversationGeneration = ConversationGenerationSnapshot(
            conversationID: conversationID,
            messageID: assistantID,
            content: "",
            phase: .generating,
            detail: nil,
            providerID: runtimeIdentity.providerID,
            model: runtimeIdentity.model
        )

        let service = ChatService(dataDirectory: dataStore.dataDirectory)
        if let snapshot = workspace.conversationGeneration {
            let checkpoint = snapshot.checkpoint(
                runID: runID,
                userMessageID: userMessageID,
                ledgerSequenceAtStart: ledgerSequenceAtStart,
                volatileContextPrompts: continuityPrompts,
                phase: .preparing
            )
            Task {
                await ConversationRunCheckpointStore.shared.checkpoint(
                    checkpoint,
                    dataDirectory: dataStore.dataDirectory,
                    immediately: true
                )
            }
        }
        let batcher = ConversationStreamBatcher { [weak workspace] delta in
            guard let workspace,
                  workspace.conversationGeneration?.conversationID == conversationID,
                  workspace.conversationGeneration?.messageID == assistantID
            else { return }
            workspace.conversationGeneration?.content += delta.content
            workspace.conversationGeneration?.reasoning += delta.reasoning
            for name in delta.toolCalls where workspace.conversationGeneration?.toolCalls.contains(name) == false {
                workspace.conversationGeneration?.toolCalls.append(name)
            }
            for run in delta.agentRuns {
                // 同一次调用会来两条（开始 / 完成），按 id 覆盖。
                if let index = workspace.conversationGeneration?.agentRuns.firstIndex(where: { $0.id == run.id }) {
                    workspace.conversationGeneration?.agentRuns[index] = run
                } else {
                    workspace.conversationGeneration?.agentRuns.append(run)
                }
            }
            guard let snapshot = workspace.conversationGeneration else { return }
            let toolCompleted = delta.agentRuns.contains { !$0.resultJSON.isEmpty }
            let checkpoint = snapshot.checkpoint(
                runID: runID,
                userMessageID: userMessageID,
                ledgerSequenceAtStart: ledgerSequenceAtStart,
                volatileContextPrompts: continuityPrompts,
                phase: toolCompleted ? .toolCompleted : .streaming
            )
            Task {
                await ConversationRunCheckpointStore.shared.checkpoint(
                    checkpoint,
                    dataDirectory: dataStore.dataDirectory,
                    immediately: toolCompleted
                )
            }
        }
        workspace.conversationGenerationTask = Task {
            do {
                // 跨会话检索要计算查询向量（约 200ms），必须留在任务里，
                // 否则点击发送的那一帧会被 embedding 阻塞。
                // 规则 / 模型判定要检索时才发生；歧义轮次先在同一后台任务里消解指代。
                let memory = await memoryPrompts(
                    conversationID: conversationID,
                    userMessageID: userMessageID,
                    ledgerSequenceLimit: ledgerSequenceAtStart,
                    service: service,
                    providerID: runtimeIdentity.providerID
                )
                try Task.checkCancellation()
                guard workspace.conversationGeneration?.conversationID == conversationID,
                      workspace.conversationGeneration?.messageID == assistantID
                else { return }
                if memory.didRetrieve {
                    workspace.conversationGeneration?.toolCalls.append("memory_search")
                }
                let requestMessages = requestHistory(
                    conversationID: conversationID,
                    excluding: replacingMessageID,
                    ledgerSequenceLimit: ledgerSequenceAtStart,
                    stableMemoryPrompts: memory.stable,
                    // 宿主上下文（题面、当前代码、评测结果）和衔接说明同样每轮都变。
                    volatileContextPrompts: memory.volatileContext + continuityPrompts,
                    runtimeIdentity: runtimeIdentity
                )
                // 工具跑在主线程拍下的这份快照上：`LegacyDataStore` 是 @MainActor 的，
                // 而 ReAct 循环在后台任务里；快照也保证一轮对话里模型看到的数据前后一致。
                let toolContext = AgentDataSnapshot.capture(from: dataStore)
                // 工具返回的长度上限由模型窗口推出来，不是写死的 6000 字：
                // 4 轮 × 并行 × 单条长文会一直累积在 wireMessages 里，小窗口必然超窗。
                let settings = dataStore.settings
                let toolLimits = AgentToolBudgetLimits.resolve(
                    availableInputTokens: max(4_096, Int(settings.contextWindowTokens - settings.reservedOutputTokens))
                )
                for try await chunk in service.stream(
                    messages: requestMessages,
                    reasoningLevel: workspace.reasoningLevel,
                    providerID: runtimeIdentity.providerID,
                    modelOverride: runtimeIdentity.model,
                    usageConversationID: conversationID,
                    agentTools: Self.agentToolExecutor(
                        snapshot: toolContext,
                        dataStore: dataStore,
                        conversationID: conversationID,
                        limits: toolLimits
                    )
                ) {
                    try Task.checkCancellation()
                    guard workspace.conversationGeneration?.conversationID == conversationID,
                          workspace.conversationGeneration?.messageID == assistantID
                    else { return }
                    batcher.append(chunk)
                }
                batcher.flush()
                try Task.checkCancellation()
                // 落盘与清除流式快照必须在**同一个同步段**里完成，中间不能有 await。
                // 挂起点会让界面在"消息已入库、快照还没清"的中间态重绘一次，
                // 同一段回答被渲染两遍，回来再清掉——看起来就是答完闪一下。
                try persistGeneratedMessage(conversationID: conversationID, messageID: assistantID)
                let finishedReply = workspace.conversationGeneration?.content ?? ""
                workspace.conversationGenerationTask = nil
                workspace.conversationGeneration = nil
                // checkpoint 只是崩溃恢复点，删晚一点不影响正确性：它带着 runID，
                // 恢复时还会用 ledger 判断本轮是否已经提交。
                await ConversationRunCheckpointStore.shared.remove(
                    threadID: conversationID,
                    runID: runID,
                    dataDirectory: dataStore.dataDirectory
                )
                embedding?.onAssistantReply?(finishedReply)
                if dispatchQueuedFollowUps(conversationID: conversationID) { return }
                await analyzeLearningIfNeeded(conversationID)
                await archiveConversationIfNeeded(conversationID)
            } catch is CancellationError {
                batcher.flush()
                // 先把界面落定，再去动 checkpoint：await 挡在前面会让"已停止"晚一拍才出现。
                let cancelled = finishCancellation(conversationID: conversationID, messageID: assistantID)
                // Task cancellation 是用户点“停止”或新一轮主动取代旧轮，不是崩溃恢复点。
                // 真正的进程中断来不及走这里，之前节流落盘的 streaming checkpoint 会留下。
                await ConversationRunCheckpointStore.shared.remove(
                    threadID: conversationID,
                    runID: runID,
                    dataDirectory: dataStore.dataDirectory
                )
                if cancelled {
                    workspace.conversationGenerationTask = nil
                    _ = dispatchQueuedFollowUps(conversationID: conversationID)
                }
            } catch {
                batcher.flush()
                // 同上：错误提示要立刻出来，checkpoint 落盘排在后面。
                let interrupted = workspace.conversationGeneration.flatMap { snapshot -> ConversationRunCheckpoint? in
                    guard snapshot.conversationID == conversationID,
                          snapshot.messageID == assistantID
                    else { return nil }
                    return snapshot.checkpoint(
                        runID: runID,
                        userMessageID: userMessageID,
                        ledgerSequenceAtStart: ledgerSequenceAtStart,
                        volatileContextPrompts: continuityPrompts,
                        phase: .interrupted
                    )
                }
                let failed = finishFailure(error, conversationID: conversationID, messageID: assistantID)
                if let interrupted {
                    await ConversationRunCheckpointStore.shared.checkpoint(
                        interrupted,
                        dataDirectory: dataStore.dataDirectory,
                        immediately: true
                    )
                }
                if failed {
                    workspace.conversationGenerationTask = nil
                    if dispatchQueuedFollowUps(conversationID: conversationID) { return }
                }
            }
        }
    }

    /// 每 `archiveStride` 条新消息滚动重写一次摘要。以前的守卫是 `aiSummary.isEmpty`，
    /// 摘要一辈子只生成一次：对话一长，早期消息被上下文压缩丢掉，摘要里也没有，
    /// 模型就再也想不起前半场说过什么了。
    private static let archiveStride = 8

    private func archiveConversationIfNeeded(_ conversationID: String) async {
        guard let conversation = dataStore.conversations.first(where: { $0.id == conversationID }),
              conversation.messages.contains(where: { $0.role == "assistant" })
        else { return }
        let isFirstArchive = conversation.aiSummary.isEmpty
        let watermark = isFirstArchive ? 0 : conversation.archivedLedgerSequence
        let latestSequence = ConversationLedger.latestSequence(conversation.ledgerEvents)
        guard isFirstArchive || latestSequence - watermark >= Self.archiveStride else { return }

        // 首次归档喂当前全量投影；之后按 ledger sequence 取增量。修订同一 messageID
        // 也会进入增量，而 tombstone 不会把已删除正文重新喂给摘要器。
        let pending = isFirstArchive
            ? conversation.messages
            : ConversationLedger.changedMessages(after: watermark, in: conversation.ledgerEvents)
        guard !pending.isEmpty else { return }
        let messages = pending.map { ChatRequestMessage(role: $0.role, content: $0.content) }
        let providerID = dataStore.settings.taskRoutes["title"]
        do {
            let archive = try await ChatService(dataDirectory: dataStore.dataDirectory)
                .summarizeConversation(
                    messages: messages,
                    providerID: providerID,
                    conversationID: conversationID,
                    previousContext: isFirstArchive ? "" : conversation.contextSummary
                )
            let applied = try dataStore.applyArchive(
                archive,
                to: conversationID,
                coveredLedgerSequence: latestSequence,
                expectedPreviousSequence: watermark,
                messageCount: conversation.messages.count,
                renames: isFirstArchive
            )
            if applied { await consolidateMemoryFacts() }
        } catch {
            NSLog("Conversation archive failed: %@", error.localizedDescription)
        }
    }

    /// 写入的第二条通道：离线整合。同步那条通道只做"宁可漏不可错"的摘要抽取，
    /// 去重、冲突消解、把零散提及升格成模式都放到这里，不占发送路径。
    private func consolidateMemoryFacts() async {
        let directory = dataStore.dataDirectory
        let store = ConversationMemoryFactStore.shared
        let document = await store.document(dataDirectory: directory)
        let pending = ConversationMemoryFactPrompt.pending(
            conversations: dataStore.conversations,
            consolidated: document.consolidated
        )
        guard !pending.isEmpty else { return }
        let summaries = pending.map { conversation in
            (
                id: conversation.id,
                title: ConversationMemoryDirectory.displayTitle(of: conversation),
                text: conversation.contextSummary.isEmpty ? conversation.aiSummary : conversation.contextSummary
            )
        }
        do {
            let merged = try await ChatService(dataDirectory: directory).consolidateMemoryFacts(
                existing: document.facts,
                summaries: summaries,
                providerID: AITaskRoute.memoryConsolidation.providerID(in: dataStore.settings)
            )
            await store.commit(
                facts: merged,
                consolidated: Dictionary(
                    uniqueKeysWithValues: pending.map { ($0.id, $0.archivedMessageCount) }
                ),
                expectedRevision: document.revision,
                dataDirectory: directory
            )
        } catch {
            NSLog("Memory consolidation failed: %@", error.localizedDescription)
        }
    }

    private func analyzeLearningIfNeeded(_ conversationID: String) async {
        guard let batch = dataStore.pendingLearningAnalysis(for: conversationID) else { return }
        do {
            let result = try await ChatService(dataDirectory: dataStore.dataDirectory).analyzeLearning(
                conversationID: conversationID,
                messages: batch.messages,
                priorContext: batch.context,
                fingerprint: batch.fingerprint,
                messageVersions: batch.versions,
                providerID: dataStore.settings.taskRoutes["learning"]
            )
            try await dataStore.mergeLearningAnalysis(
                conversationID: conversationID,
                result: result,
                messages: batch.messages
            )
        } catch {
            NSLog("Learning analysis failed: %@", error.localizedDescription)
        }
    }

    private func cancelGeneration() {
        workspace.stopConversationGeneration()
    }

    private func enqueueDraft(artifacts: [ConversationArtifact]) {
        let prompt = draft.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty,
              let current = workspace.conversationGeneration,
              current.phase == .generating,
              current.conversationID == activeConversationID
        else { return }
        draft.wrappedValue = ""
        workspace.queuedConversationID = current.conversationID
        workspace.queuedConversationDrafts.append(QueuedConversationDraft(text: prompt, artifacts: artifacts))
    }

    private func clearQueue() {
        workspace.queuedConversationDrafts.removeAll()
        workspace.queuedConversationID = nil
    }

    private func interruptAndSendQueue() {
        guard let current = workspace.conversationGeneration,
              current.phase == .generating,
              current.conversationID == workspace.queuedConversationID,
              !workspace.queuedConversationDrafts.isEmpty
        else { return }
        // Cancellation is finalized by the owning stream task: it first flushes
        // the pending 50ms batch, persists the partial answer, then dispatches queue.
        workspace.conversationGenerationTask?.cancel()
    }

    @discardableResult
    private func dispatchQueuedFollowUps(conversationID: String) -> Bool {
        guard workspace.queuedConversationID == conversationID, !workspace.queuedConversationDrafts.isEmpty else { return false }
        let drafts = workspace.queuedConversationDrafts
        clearQueue()
        let message = ConversationTranscriptMessage(
            id: Self.messageID(),
            role: "user",
            content: ConversationQueueContent.userContent(for: drafts),
            createdAt: .now,
            artifacts: Array(drafts.flatMap(\.artifacts).prefix(Int(dataStore.settings.maxImages)))
        )
        do {
            try dataStore.appendMessage(message, to: conversationID)
            startGeneration(
                conversationID: conversationID,
                replacingMessageID: nil,
                continuityPrompt: ConversationQueueContent.continuityPrompt()
            )
            return true
        } catch {
            workspace.queuedConversationID = conversationID
            workspace.queuedConversationDrafts = drafts
            showLocalFailure(error.localizedDescription, conversationID: conversationID)
            return false
        }
    }

    private func requestHistory(
        conversationID: String,
        excluding messageID: String?,
        ledgerSequenceLimit: Int,
        stableMemoryPrompts: [String],
        volatileContextPrompts: [String],
        runtimeIdentity: ConversationRuntimeIdentity
    ) -> [ChatRequestMessage] {
        // 工具是"能力"，不是"义务"：不把它写成必须调用，否则问"快排怎么写"
        // 也会先去翻一遍题库，白花时间和 token。
        let system = ChatRequestMessage(
            role: "system",
            content: """
            你是一位资深算法工程师和 LeetCode 解题助手。始终使用中文，结论准确、清晰、可执行。            算法题需给出思路、复杂度、完整代码和关键边界。只有用户明确要求时才生成 SVG 或 Mermaid 图解。

            你可以调用工具读取这位用户的本地学习档案——他的学习题库、力扣提交轨迹、            复习排期，以及力扣社区的题解。用与不用由你判断：
            - 问题牵涉到"我"（我以前怎么错的、我掌握得怎么样、我今天该做什么）时先查，不要凭空猜。
            - 讲一道具体题目前，先看他在这道题上的提交轨迹，针对他真实犯过的错来讲。
            - 纯知识性问题（"快排怎么写"）直接回答，不必调用工具。
            - 需要别人的解法时，先 search_leetcode_solutions 拿到 slug，再 read_leetcode_solution 读正文，            不要只看标题就下结论。

            工具返回的是事实数据，据此作答；查不到就直说查不到，不要编造他的学习记录。
            """
        )
        guard let conversation = dataStore.conversations.first(where: { $0.id == conversationID }) else {
            return [system]
        }
        let identity = ChatRequestMessage(role: "system", content: runtimeIdentity.systemPrompt)
        let stableMemory = stableMemoryPrompts.map { ChatRequestMessage(role: "system", content: $0) }
        // 模型窗口只是 append-only ledger 的纯投影。摘要尚未异步完成时 digest 为空，
        // 投影只用 skeleton + verbatim；摘要完成并写入状态后，下一轮才自然进入窗口。
        let ledger = conversation.ledgerEvents.filter { event in
            event.sequence <= ledgerSequenceLimit && event.messageID != messageID
        }
        let managed = ContextProjection.build(
            ledger: ledger,
            digest: conversation.archivedLedgerSequence <= ledgerSequenceLimit
                ? conversation.contextSummary
                : "",
            settings: dataStore.settings
        ).messages
        // 顺序由缓存决定：稳定前缀 → 历史 → 本轮易变块。
        // 检索片段和宿主上下文每轮都不同，排在前面会把整段历史踢出前缀缓存。
        var sections = PromptAssembly.Sections()
        sections.stable = [system, identity] + stableMemory
        sections.history = managed
        sections.volatileContext = volatileContextPrompts
        return sections.messages
    }

    /// 工具卡片上的跳转。`kind` 决定落到哪个页面，`id` 是那个页面要选中的东西。
    private func handleAgentJump(kind: String, id: String) {
        switch kind {
        case "learning":
            if !id.isEmpty { workspace.selectedLearningRecordID = id }
            workspace.selectedSection = .library
        case "graph":
            if !id.isEmpty { workspace.selectedLearningRecordID = id }
            workspace.selectedSection = .knowledge
        case "leetcode":
            if !id.isEmpty { workspace.pendingLeetCodeSlug = id }
            workspace.selectedSection = .leetCode
        case "conversation":
            if !id.isEmpty { workspace.selectedConversationID = id }
            workspace.selectedSection = .conversation
        case "plan":
            workspace.selectedSection = .plan
        case "review":
            workspace.selectedSection = .review
        case "url":
            if let url = URL(string: id) { workspace.openURL(url) }
        default:
            break
        }
    }

    /// ReAct 工具执行器。把 `LearningAgentTools` 需要的三条外部能力接上：
    /// 跨会话检索、题解列表、题解正文。前者走本地 RAG，后两者走力扣公开接口。
    @MainActor
    private static func agentToolExecutor(
        snapshot: AgentDataSnapshot,
        dataStore: LegacyDataStore,
        conversationID: String,
        limits: AgentToolBudgetLimits
    ) -> AgentToolExecutor {
        { name, arguments in
            await LearningAgentTools.run(
                name: name,
                arguments: arguments,
                snapshot: snapshot,
                memorySearch: { query in
                    let matches = await dataStore.searchMemory(
                        query: query,
                        currentConversationID: conversationID
                    )
                    return matches.prefix(4).map { match in
                        AgentDataSnapshot.MemoryMatch(
                            conversationID: match.conversationID,
                            title: match.title,
                            dateCaption: "相关度 \(match.score)",
                            excerpt: String(match.content.prefix(400))
                        )
                    }
                },
                // 这三条外部能力以前一律 `try?`：网络错误被吞成空数组，模型收到
                // 「暂时读不到题解」，就当成"这题没人写题解"，然后放弃或者自己编一篇。
                // 失败必须原样传到模型，由它决定下一步。
                solutionSearch: { slug in
                    do {
                        let page = try await LeetCodeAPIClient.shared.fetchSolutions(titleSlug: slug, first: 20)
                        return .success(page.items.map { item in
                            LearningAgentTools.SolutionHit(
                                slug: item.slug,
                                title: item.title,
                                author: item.authorName,
                                summary: String(item.summary.prefix(240)),
                                views: item.views,
                                isOfficial: item.isOfficial
                            )
                        })
                    } catch {
                        return .failure(AgentToolFailure.from(error))
                    }
                },
                solutionRead: { slug in
                    do {
                        return .success(try await LeetCodeAPIClient.shared.fetchSolutionArticle(slug: slug).markdown)
                    } catch {
                        return .failure(AgentToolFailure.from(error))
                    }
                },
                videoSearch: { query in
                    .success(await BilibiliAPIClient.search(query: query))
                },
                limits: limits
            ).json
        }
    }

    private struct MemoryInjection {
        /// 逐字不变、进稳定前缀：长期事实与会话目录。
        var stable: [String] = []
        /// 每轮都不同、必须排在最后：检索出来的原文片段。
        var volatileContext: [String] = []
        var didRetrieve = false
    }

    /// 固定编排：**指代消解 → 意图识别 → 路线分流 → 按路线执行**。
    ///
    /// 稳定前缀（长期事实 + 会话目录）对所有路线恒定——它们按路线增删会让 prompt
    /// 前缀每轮都变，缓存全废。路线只决定易变段：宿主上下文、检索结果。
    private func memoryPrompts(
        conversationID: String,
        userMessageID: String,
        ledgerSequenceLimit: Int,
        service: ChatService,
        providerID: String
    ) async -> MemoryInjection {
        guard let conversation = dataStore.conversations.first(where: { $0.id == conversationID }) else {
            return MemoryInjection()
        }
        let boundedLedger = conversation.ledgerEvents.filter { $0.sequence <= ledgerSequenceLimit }
        let boundedMessages = ConversationLedger.project(boundedLedger)
        guard let userMessage = boundedMessages.first(where: { $0.id == userMessageID && $0.role == "user" })
        else { return MemoryInjection() }

        var injection = MemoryInjection()
        let facts = await ConversationMemoryFactStore.shared.facts(dataDirectory: dataStore.dataDirectory)
        if let factPrompt = ConversationMemoryFactPrompt.prompt(for: facts) {
            injection.stable.append(factPrompt)
        }
        let directory = frozenDirectory(for: conversationID)
        if let index = ConversationMemoryDirectory.prompt(for: directory) {
            injection.stable.append(index)
        }

        let turn = await resolveTurnPlan(
            conversation: conversation,
            boundedMessages: boundedMessages,
            userMessage: userMessage,
            ledgerSequenceLimit: ledgerSequenceLimit,
            directory: directory,
            service: service,
            providerID: providerID
        )
        workspace.lastConversationRoute[conversationID] = turn.route

        // 按路线执行。每一步都是这条路线声明过的，执行层不再自己判断要不要做。
        for step in turn.plan.steps {
            switch step {
            case .attachHostContext:
                break   // 宿主上下文由 startGeneration 在发送那一刻冻结后传入
            case .retrieveMemory, .rerankMemory, .admitMemory:
                // 检索 / 精排 / 准入是 searchMemory 内部的连续三步，只在第一步触发一次。
                guard step == .retrieveMemory else { continue }
                let matches = await dataStore.searchMemory(
                    query: turn.resolvedQuery,
                    currentConversationID: conversationID
                )
                if let retrieved = ConversationMemoryIndex.prompt(for: matches) {
                    injection.volatileContext.append(retrieved)
                    injection.didRetrieve = true
                }
            }
        }
        return injection
    }

    /// 消解 + 分类 + 分流。规则能定案就不花钱；定不了才问一次便宜模型，
    /// 结果按 `(会话, 消息)` 缓存，重试同一条回答不重复付费。
    private func resolveTurnPlan(
        conversation: ConversationSummary,
        boundedMessages: [ConversationTranscriptMessage],
        userMessage: ConversationTranscriptMessage,
        ledgerSequenceLimit: Int,
        directory: [ConversationMemoryDirectoryEntry],
        service: ChatService,
        providerID: String
    ) async -> ConversationTurnPlan {
        let key = ConversationIntentCacheKey(
            conversationID: conversation.id,
            messageID: userMessage.id
        )
        if let cached = await workspace.conversationTurnPlanCache.value(for: key) { return cached }

        let rerankAvailable = dataStore.settings.cloudMemoryRerankingEnabled
        let rules = ConversationIntentPolicy.classify(
            query: userMessage.content,
            directory: directory,
            hasHostContext: embedding?.contextPrompt() != nil
        )

        func ruleOnly() -> ConversationTurnPlan {
            let route = ConversationRoute.route(for: rules.intent)
            return ConversationTurnPlan(
                resolvedQuery: userMessage.content.trimmingCharacters(in: .whitespacesAndNewlines),
                intent: rules.intent,
                plan: ConversationRoutePlan(route: route, rerankAvailable: rerankAvailable),
                usedModel: false
            )
        }

        var plan = ruleOnly()
        if rules.certainty == .needsModel,
           let context = ConversationIntentContextProjection.build(
            messages: boundedMessages,
            currentMessageID: userMessage.id,
            // 摘要若覆盖到本轮 ledger 上界之后，可能含"未来消息"，恢复时不能用。
            contextSummary: conversation.archivedLedgerSequence <= ledgerSequenceLimit
                ? conversation.contextSummary
                : "",
            directory: directory,
            availableInputTokens: ChatService.availableInputTokens(dataDirectory: dataStore.dataDirectory)
           ) {
            do {
                let resolved = try await service.resolveConversationTurn(
                    context: context,
                    // 固定跟随本轮主对话供应商：不把历史投影扩散到另一家服务。
                    providerID: providerID,
                    conversationID: conversation.id
                )
                plan = ConversationTurnPlan(
                    resolvedQuery: resolved.resolvedQuery,
                    intent: resolved.intent,
                    plan: ConversationRoutePlan(
                        route: ConversationRoute.route(for: resolved.intent),
                        rerankAvailable: rerankAvailable
                    ),
                    usedModel: true
                )
            } catch is CancellationError {
                return plan
            } catch {
                // 路由是优化不是单点故障：模型不可用就按规则先验走，并把这个降级结果
                // 一并缓存，避免同一条消息反复重试制造失败风暴。
                NSLog("Turn routing unavailable; using rule classification: %@", error.localizedDescription)
            }
        }
        await workspace.conversationTurnPlanCache.insert(plan, for: key)
        return plan
    }

    /// 会话目录在进入会话时冻结。
    ///
    /// 它本来按"最近更新"排序，别的会话一动就重排——前缀里放一个会变的东西，
    /// 等于每轮把它后面的全部内容踢出缓存。冻结不损语义：目录只是一张地图。
    private func frozenDirectory(for conversationID: String) -> [ConversationMemoryDirectoryEntry] {
        if let cached = workspace.frozenMemoryDirectory[conversationID] { return cached }
        let entries = ConversationMemoryDirectory.entries(
            from: dataStore.conversations,
            excluding: conversationID
        )
        workspace.frozenMemoryDirectory[conversationID] = entries
        return entries
    }

    private func persistGeneratedMessage(conversationID: String, messageID: String) throws {
        guard let current = workspace.conversationGeneration,
              current.conversationID == conversationID,
              current.messageID == messageID,
              !current.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { throw ChatServiceError.emptyResponse }
        try dataStore.upsertMessage(
            ConversationTranscriptMessage(
                id: messageID,
                role: "assistant",
                content: current.storedContent,
                createdAt: .now,
                toolCalls: current.toolCalls,
                agentRuns: current.agentRuns,
                providerID: current.providerID,
                model: current.model
            ),
            in: conversationID
        )
    }

    @discardableResult
    private func finishCancellation(conversationID: String, messageID: String) -> Bool {
        guard workspace.conversationGeneration?.conversationID == conversationID,
              workspace.conversationGeneration?.messageID == messageID
        else { return false }
        if let snapshot = workspace.conversationGeneration, !snapshot.content.isEmpty {
            try? dataStore.upsertMessage(
                ConversationTranscriptMessage(
                    id: messageID,
                    role: "assistant",
                    content: snapshot.storedContent,
                    createdAt: .now,
                    toolCalls: snapshot.toolCalls,
                    agentRuns: snapshot.agentRuns,
                    providerID: snapshot.providerID,
                    model: snapshot.model
                ),
                in: conversationID
            )
        }
        workspace.conversationGeneration?.phase = .cancelled
        workspace.conversationGeneration?.detail = "已停止生成"
        return true
    }

    @discardableResult
    private func finishFailure(_ error: Error, conversationID: String, messageID: String) -> Bool {
        guard workspace.conversationGeneration?.conversationID == conversationID,
              workspace.conversationGeneration?.messageID == messageID
        else { return false }
        if let snapshot = workspace.conversationGeneration, !snapshot.content.isEmpty {
            try? dataStore.upsertMessage(
                ConversationTranscriptMessage(
                    id: messageID,
                    role: "assistant",
                    content: snapshot.storedContent,
                    createdAt: .now,
                    toolCalls: snapshot.toolCalls,
                    agentRuns: snapshot.agentRuns,
                    providerID: snapshot.providerID,
                    model: snapshot.model
                ),
                in: conversationID
            )
        }
        workspace.conversationGeneration?.phase = .failed
        workspace.conversationGeneration?.detail = error.localizedDescription
        return true
    }

    private func showLocalFailure(_ message: String, conversationID: String) {
        workspace.conversationGeneration = ConversationGenerationSnapshot(
            conversationID: conversationID,
            messageID: Self.messageID(),
            content: "",
            phase: .failed,
            detail: message
        )
    }

    private static func messageID() -> String {
        "m_\(Int(Date.now.timeIntervalSince1970 * 1_000))_\(UUID().uuidString.prefix(7).lowercased())"
    }

}

private struct ConversationEmptyStateView<Composer: View>: View {
    @ViewBuilder let composer: Composer

    var body: some View {
        GeometryReader { proxy in
            let compactHeight = proxy.size.height < 560
            let clockDiameter = min(
                max(proxy.size.height * (compactHeight ? 0.29 : 0.30), compactHeight ? 112 : 180),
                320
            )
            let horizontalInset = min(max(proxy.size.width * 0.035, 24), 56)
            let composerReserve: CGFloat = compactHeight ? 90 : 114

            ZStack {
                VStack(spacing: 0) {
                    Spacer(minLength: compactHeight ? 8 : 20)

                    ZStack {
                        RoundedRectangle(cornerRadius: clockDiameter * 0.28, style: .continuous)
                            .fill(Color.primary.opacity(0.055))
                            .frame(
                                width: min(proxy.size.width * 0.64, 860),
                                height: clockDiameter * 0.72
                            )
                            .blur(radius: 68)
                            .allowsHitTesting(false)

                        Rectangle()
                            .fill(Color.primary.opacity(0.032))
                            .frame(
                                width: min(proxy.size.width * 0.44, 620),
                                height: clockDiameter * 0.30
                            )
                            .offset(y: clockDiameter * 0.08)
                            .blur(radius: 44)
                            .allowsHitTesting(false)

                        BraunClockView()
                            .frame(width: clockDiameter, height: clockDiameter)
                    }
                    .frame(height: clockDiameter)

                    TimelineView(.periodic(from: .now, by: 60)) { timeline in
                        Text(timeline.date.formatted(.dateTime.month(.wide).day().weekday(.wide)))
                            .font(.appScaled(size: 13, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                    .padding(.top, compactHeight ? 10 : 18)

                    Spacer(minLength: compactHeight ? 12 : 24)
                }
                .padding(.bottom, composerReserve)

                composer
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, horizontalInset)
                    .padding(.bottom, compactHeight ? 26 : 38)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct BraunClockView: View {
    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { timeline in
            Canvas { context, size in
                let diameter = min(size.width, size.height)
                let center = CGPoint(x: size.width / 2, y: size.height / 2)
                let radius = diameter / 2

                for index in 0..<60 {
                    let major = index.isMultiple(of: 5)
                    let angle = Double(index) * .pi / 30 - .pi / 2
                    let outer = point(center: center, radius: radius - 8, angle: angle)
                    let inner = point(center: center, radius: radius - (major ? 16 : 12), angle: angle)
                    var tick = Path()
                    tick.move(to: inner)
                    tick.addLine(to: outer)
                    context.stroke(
                        tick,
                        with: .color(.primary.opacity(major ? 0.55 : 0.24)),
                        lineWidth: major ? 1.5 : 0.75
                    )
                }

                for hour in 1...12 {
                    let angle = Double(hour) * .pi / 6 - .pi / 2
                    context.draw(
                        Text("\(hour)")
                            .font(AppDesign.Typography.micro)
                            .foregroundStyle(.secondary),
                        at: point(center: center, radius: radius * 0.73, angle: angle),
                        anchor: .center
                    )
                }

                let components = Calendar.current.dateComponents([.hour, .minute, .second], from: timeline.date)
                let minute = Double(components.minute ?? 0)
                let second = Double(components.second ?? 0)
                let hour = Double((components.hour ?? 0) % 12) + minute / 60
                context.stroke(
                    handPath(center: center, radius: radius * 0.50, angle: hour * .pi / 6 - .pi / 2),
                    with: .color(.primary.opacity(0.88)),
                    lineWidth: 4.4
                )
                context.stroke(
                    handPath(center: center, radius: radius * 0.68, angle: minute * .pi / 30 - .pi / 2),
                    with: .color(.primary.opacity(0.88)),
                    lineWidth: 3.2
                )

                var secondHand = Path()
                secondHand.move(to: point(center: center, radius: radius * 0.11, angle: second * .pi / 30 + .pi / 2))
                secondHand.addLine(to: point(center: center, radius: radius * 0.79, angle: second * .pi / 30 - .pi / 2))
                context.stroke(secondHand, with: .color(Color(nsColor: .systemOrange)), lineWidth: 1.7)
                context.fill(Path(ellipseIn: CGRect(x: center.x - 4, y: center.y - 4, width: 8, height: 8)), with: .color(Color(nsColor: .systemOrange)))
            }
        }
        .background {
            Circle()
                .fill(
                    LinearGradient(
                        colors: [Color.white, Color(nsColor: .controlBackgroundColor)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .shadow(color: .black.opacity(0.16), radius: 22, y: 13)
                .shadow(color: .black.opacity(0.06), radius: 4, y: 2)
                .overlay {
                    Circle().strokeBorder(.white.opacity(0.7), lineWidth: 1)
                }
        }
        .accessibilityLabel("当前时间")
    }

    private func point(center: CGPoint, radius: CGFloat, angle: Double) -> CGPoint {
        CGPoint(
            x: center.x + CGFloat(cos(angle)) * radius,
            y: center.y + CGFloat(sin(angle)) * radius
        )
    }

    private func handPath(
        center: CGPoint,
        radius: CGFloat,
        angle: Double
    ) -> Path {
        var hand = Path()
        hand.move(to: center)
        hand.addLine(to: point(center: center, radius: radius, angle: angle))
        return hand
    }
}

private struct ComposerView: View {
    @Bindable var workspace: WorkspaceState
    @Bindable var dataStore: LegacyDataStore
    @Binding var draft: String
    /// 嵌在浮窗里：窄，收起上下文占用环，模型芯片用最窄一档。
    var isCompact = false
    var placeholder: String?
    let conversation: ConversationSummary?
    let isGenerating: Bool
    let isBusyElsewhere: Bool
    let queuedDrafts: [QueuedConversationDraft]
    let onSend: ([ConversationArtifact]) -> Void
    let onEnqueue: ([ConversationArtifact]) -> Void
    let onClearQueue: () -> Void
    let onCancel: () -> Void
    let onInterruptAndSendQueue: () -> Void
    @FocusState private var isComposerFocused: Bool
    @State private var showsReasoning = false
    @State private var showsContextUsage = false
    @State private var showsImageImporter = false
    @State private var pendingArtifacts: [ConversationArtifact] = []
    @State private var contextDismissTask: Task<Void, Never>?
    @State private var showsModelList = false
    /// 全局缓存 + 落盘，见 `ModelCatalog`：不再每次打开会话都重拉模型列表。
    private var catalog: ModelCatalog { .shared }

    private var activeProvider: ProviderRecord? {
        dataStore.providers.first { $0.id == dataStore.settings.activeProviderID }
    }

    private var contextUsage: ContextUsageSnapshot {
        workspace.contextUsage(
            for: conversation,
            draft: draft,
            settings: dataStore.settings
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            if !queuedDrafts.isEmpty {
                queueStatus
                Divider().padding(.horizontal, 10)
            }

            if isCompact {
                // 浮窗里宽度只有三四百点：一行排不下输入框 + 模型 + 推理 + 发送，
                // 硬塞的结果是输入框被挤成一条竖缝、占位文字折成三行。
                // 改成两行：上面整行给输入，下面一排控件（和 Codex 窄窗口的输入框一样）。
                VStack(alignment: .leading, spacing: 4) {
                    inputField
                        .padding(.horizontal, 4)
                    HStack(spacing: 6) {
                        attachButton
                        modelPicker
                        reasoningButton
                        Spacer(minLength: 0)
                        sendButton
                    }
                }
                .padding(.horizontal, 8)
                .padding(.top, 8)
                .padding(.bottom, 6)
            } else {
                HStack(alignment: .center, spacing: 9) {
                    attachButton
                    inputField
                    // 把右侧操作组贴近发送键，空余宽度全部留给输入区；
                    // 模型选择不再停在输入框中段。
                    Spacer(minLength: AppDesign.Spacing.xs)
                    modelPicker
                    contextMeter
                    reasoningButton
                    sendButton
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
            }
        }
        .frame(minHeight: AppDesign.Size.composerMinimumHeight)
        .background { composerSurface }
        .animation(AppDesign.Motion.selection, value: showsReasoning)
        .animation(AppDesign.Motion.selection, value: isGenerating)
        .fileImporter(
            isPresented: $showsImageImporter,
            allowedContentTypes: [.image],
            allowsMultipleSelection: true,
            onCompletion: receiveImages
        )
        .task(id: providerCatalogSignature) {
            await refreshModelCatalog(force: false)
        }
        .onDisappear {
            contextDismissTask?.cancel()
            contextDismissTask = nil
        }
    }

    /// 对话页的输入框浮在正文上，用玻璃；嵌在浮窗里时浮窗本身已经是一层，
    /// 再叠一层玻璃就是"框里套框"，改成一块安静的实底 + 发丝边。
    @ViewBuilder
    private var composerSurface: some View {
        if isCompact {
            RoundedRectangle(cornerRadius: AppDesign.Radius.card + 2, style: .continuous)
                .fill(Color.primary.opacity(isComposerFocused ? 0.035 : 0.025))
                .overlay {
                    RoundedRectangle(cornerRadius: AppDesign.Radius.card + 2, style: .continuous)
                        .strokeBorder(Color.primary.opacity(isComposerFocused ? 0.16 : 0.08))
                }
        } else {
            Color.clear.navigationGlass(cornerRadius: AppDesign.Radius.composer, interactive: true)
        }
    }

    private var attachButton: some View {
        Button { showsImageImporter = true } label: {
            ZStack(alignment: .topTrailing) {
                Image(systemName: "plus")
                    .frame(width: 28, height: 28)
                if !pendingArtifacts.isEmpty {
                    Text("\(pendingArtifacts.count)")
                        .font(.appScaled(size: 8, weight: .bold).monospacedDigit())
                        .foregroundStyle(.white)
                        .frame(minWidth: 13, minHeight: 13)
                        .background(Color.accentColor, in: Circle())
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .help(pendingArtifacts.isEmpty ? "添加图片" : "已添加 \(pendingArtifacts.count) 张图片")
        .disabled(isBusyElsewhere)
    }

    private var inputField: some View {
        TextField(composerPlaceholder, text: $draft, axis: .vertical)
            .font(AppDesign.Typography.body)
            .textFieldStyle(.plain)
            .lineLimit(isCompact ? 2...8 : 1...5)
            .floatingTextScrollIndicators()
            .focused($isComposerFocused)
            .padding(.vertical, 5)
            .onSubmit { primaryAction() }
            .disabled(isBusyElsewhere)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var reasoningButton: some View {
        Button { showsReasoning.toggle() } label: {
            HStack(spacing: 5) {
                Text(workspace.reasoningLevel.title)
                Image(systemName: "chevron.down")
                    .font(AppDesign.Typography.micro)
                    .rotationEffect(.degrees(showsReasoning ? 180 : 0))
            }
            .font(isCompact ? AppDesign.Typography.aux : AppDesign.Typography.body)
            .foregroundStyle(isCompact ? .secondary : .primary)
            .frame(minWidth: 44, minHeight: 28)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .popover(isPresented: $showsReasoning, arrowEdge: .bottom) {
            ReasoningPopover(workspace: workspace)
        }
        .help("推理强度")
    }

    private var sendButton: some View {
        Button(action: primaryAction) {
            Image(systemName: sendButtonSymbol)
                .font(.appScaled(size: sendButtonSymbol == "stop.fill" ? 10 : 13, weight: .semibold))
                .contentTransition(.symbolEffect(.replace))
                .foregroundStyle(.white)
                .frame(width: isCompact ? 26 : 30, height: isCompact ? 26 : 30)
                .background(sendButtonColor, in: Circle())
        }
        .buttonStyle(.plain)
        .disabled(sendButtonDisabled)
        .help(sendButtonHelp)
        .keyboardShortcut(.return, modifiers: .command)
    }

    private var queueStatus: some View {
        HStack(spacing: 8) {
            Image(systemName: "text.badge.plus")
                .font(.appScaled(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
            Text("待发送 \(queuedDrafts.count) 条")
                .font(AppDesign.Typography.micro.weight(.semibold))
            Text(queuedDrafts.map(\.text).joined(separator: " · "))
                .font(AppDesign.Typography.micro)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer(minLength: 8)
            Button(action: onClearQueue) {
                Image(systemName: "xmark")
                    .font(.appScaled(size: 10, weight: .semibold))
                    .frame(width: 22, height: 22)
            }
            .buttonStyle(.plain)
            .help("清空待发送队列")
        }
        .padding(.leading, 13)
        .padding(.trailing, 7)
        .padding(.vertical, 7)
    }

    private var hasDraft: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var composerPlaceholder: String {
        if isBusyElsewhere { return "另一对话正在生成…" }
        if isGenerating { return "输入补充，发送后进入队列…" }
        return placeholder ?? "给 AI 发送消息"
    }

    private var sendButtonSymbol: String {
        if isGenerating && hasDraft { return "text.badge.plus" }
        if isGenerating && !queuedDrafts.isEmpty { return "forward.end.fill" }
        if isGenerating { return "stop.fill" }
        return "arrow.up"
    }

    private var sendButtonHelp: String {
        if isBusyElsewhere { return "另一对话正在生成" }
        if isGenerating && hasDraft { return "加入发送队列" }
        if isGenerating && !queuedDrafts.isEmpty { return "打断当前回答并处理队列" }
        if isGenerating { return "停止生成" }
        return "发送"
    }

    private var sendButtonDisabled: Bool {
        isBusyElsewhere || (!isGenerating && !hasDraft)
    }

    private func primaryAction() {
        if isBusyElsewhere { return }
        if isGenerating {
            if hasDraft {
                onEnqueue(pendingArtifacts)
                pendingArtifacts.removeAll()
            } else if !queuedDrafts.isEmpty {
                onInterruptAndSendQueue()
            } else {
                onCancel()
            }
        } else {
            submit()
        }
    }

    /// 模型芯片。
    ///
    /// **为什么不用 `Menu`**：`.menuStyle(.borderlessButton)` 的 Menu 完全不理会 label 的尺寸——
    /// 实测（GeometryReader）无论菜单里 3 条还是 120 条，它都把自己排成「可用宽度 × 512」，
    /// `fixedSize()` 还会变成 572×512。显式 frame 能钉住外框，但钉不住它自己画的那层底：
    /// 28pt 的可视带里露出来的就是那条黑条，label 被挤到带外，表现为"换个供应商图标和名字全没了"。
    /// 同一段 label 用 ImageRenderer 离屏渲染是完全正常的，所以问题在控件不在内容。
    /// 换成普通 Button + popover，自绘列表，尺寸和绘制都由我们说了算。
    private var modelPicker: some View {
        Button {
            showsModelList.toggle()
        } label: {
            HStack(spacing: 5) {
                // 图标只认活跃供应商，绝不从模型名推断；芯片只展示图标 + 模型名，
                // 供应商身份由图标承担（按用户要求不重复显示供应商名字）。
                if showsModelIcon {
                    ProviderMark(assetName: activeProvider?.assetName, size: 13)
                        .frame(width: 13, height: 13)
                }
                Text(activeProvider?.model ?? "选择模型")
                    .font(isCompact ? AppDesign.Typography.aux : .appScaled(size: 12, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .layoutPriority(-1)
                Image(systemName: "chevron.down").font(AppDesign.Typography.micro)
            }
            .foregroundStyle(isCompact ? .secondary : .primary)
            // 浮窗里模型芯片挨着附件键往左排，宽度随名字、给个上限；对话页仍是右对齐的定宽。
            .frame(
                minWidth: isCompact ? nil : modelPickerWidth,
                maxWidth: isCompact ? AppDesign.Size.scaledControl(150) : modelPickerWidth,
                minHeight: 28,
                maxHeight: 28,
                alignment: isCompact ? .leading : .trailing
            )
            .fixedSize(horizontal: isCompact, vertical: false)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("切换模型与供应商")
        .popover(isPresented: $showsModelList, arrowEdge: .top) {
            modelListPopover
        }
    }

    private var modelListPopover: some View {
        VStack(spacing: 0) {
            ScrollView {
                // 不用 LazyVStack + pinnedViews：选中后列表重建时吸顶标题的
                // 重排偶尔会在列表中间留一块空白洞。列表只有几十行，普通 VStack
                // 一次排完更稳，标题作为普通行参与布局。
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(dataStore.providers.filter(\.isConfigured)) { provider in
                        HStack(spacing: 6) {
                            ProviderMark(assetName: provider.assetName, size: 13)
                                .frame(width: 13, height: 13)
                            Text(provider.name)
                                .font(AppDesign.Typography.micro.weight(.semibold))
                                .foregroundStyle(.secondary)
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 10)
                        .frame(height: 26)
                        ForEach(models(for: provider), id: \.self) { model in
                            modelRow(model, provider: provider)
                        }
                        if catalog.loadingProviderIDs.contains(provider.id) {
                            HStack(spacing: 6) {
                                ProgressView().controlSize(.small).scaleEffect(0.6)
                                Text("正在获取模型…")
                                    .font(AppDesign.Typography.micro)
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.horizontal, 10)
                            .frame(height: 26)
                        }
                    }
                }
                .padding(.vertical, 4)
            }
            .floatingScrollIndicators()
            .frame(maxHeight: 360)

            Divider()

            Button {
                showsModelList = false
                Task { await refreshModelCatalog(force: true) }
            } label: {
                Label("刷新全部模型", systemImage: "arrow.clockwise")
                    .font(AppDesign.Typography.aux)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 10)
                    .frame(height: 30)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(catalog.isLoading)
        }
        .frame(width: 260)
    }

    private func modelRow(_ model: String, provider: ProviderRecord) -> some View {
        let isActive = provider.id == dataStore.settings.activeProviderID && model == provider.model
        return Button {
            selectModel(model, provider: provider)
            showsModelList = false
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "checkmark")
                    .font(.appScaled(size: 10, weight: .bold))
                    .foregroundStyle(Color.accentColor)
                    .opacity(isActive ? 1 : 0)
                    .frame(width: 12)
                Text(model)
                    .font(AppDesign.Typography.aux)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .frame(height: 26)
            .contentShape(Rectangle())
        }
        .buttonStyle(ModelRowButtonStyle())
    }

    private var showsModelIcon: Bool { isCompact || workspace.windowWidth >= 1_050 }

    private var modelPickerWidth: CGFloat {
        if isCompact || workspace.windowWidth < 980 { return 92 }
        if workspace.windowWidth < 1_260 { return 116 }
        return 142
    }

    private var providerCatalogSignature: String {
        dataStore.providers
            .filter(\.isConfigured)
            .map { "\($0.id)|\($0.apiBase)|\($0.model)" }
            .joined(separator: ";")
    }

    private func models(for provider: ProviderRecord) -> [String] {
        var seen = Set<String>()
        return ([provider.model] + catalog.models(for: provider.id))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    private func selectModel(_ model: String, provider: ProviderRecord) {
        do {
            try dataStore.selectProviderModel(provider.id, model: model)
        } catch {
            NSLog("Switch model failed: %@", error.localizedDescription)
        }
    }

    @MainActor
    private func refreshModelCatalog(force: Bool) async {
        catalog.restore(dataDirectory: dataStore.dataDirectory)
        let providers = dataStore.providers.filter(\.isConfigured)
        catalog.prune(keeping: Set(providers.map(\.id)))
        let service = ChatService(dataDirectory: dataStore.dataDirectory)
        let ids = providers.map(\.id)
        let fetch: (String) async throws -> [String] = { try await service.listModels(providerID: $0) }
        if force {
            await catalog.refresh(providerIDs: ids, using: fetch)
        } else {
            // 只补没缓存过的：打开会话不再触发整轮网络请求，更新交给「刷新全部模型」。
            await catalog.loadMissing(providerIDs: ids, using: fetch)
        }
    }

    private var sendButtonColor: Color {
        if isGenerating { return .primary }
        return draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? .secondary : .accentColor
    }

    private var contextMeter: some View {
        ZStack {
            Circle().stroke(.quaternary, lineWidth: 2)
            Circle()
                .trim(from: 0, to: CGFloat(contextUsage.utilization))
                .stroke(contextUsage.shouldCompress ? Color.orange : Color.accentColor, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .frame(width: 16, height: 16)
        .frame(width: 28, height: 30)
        .contentShape(Rectangle())
        .onHover { hovering in setContextUsageHover(hovering) }
        .popover(isPresented: $showsContextUsage, arrowEdge: .bottom) {
            ContextUsagePopover(usage: contextUsage) { hovering in
                setContextUsageHover(hovering)
            }
        }
        .help("上下文占用 \(Int(contextUsage.utilization * 100))%")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("当前上下文占用 \(Int(contextUsage.utilization * 100))%")
    }

    private func setContextUsageHover(_ hovering: Bool) {
        if hovering {
            contextDismissTask?.cancel()
            contextDismissTask = nil
            if !showsContextUsage { showsContextUsage = true }
        } else {
            guard showsContextUsage, contextDismissTask == nil else { return }
            contextDismissTask = Task {
                try? await Task.sleep(for: .milliseconds(280))
                guard !Task.isCancelled else { return }
                showsContextUsage = false
                contextDismissTask = nil
            }
        }
    }

    private func submit() {
        let hasPrompt = !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        onSend(pendingArtifacts)
        if hasPrompt {
            pendingArtifacts.removeAll()
        }
    }

    private func receiveImages(_ result: Result<[URL], Error>) {
        guard case .success(let urls) = result else { return }
        let remaining = max(0, Int(dataStore.settings.maxImages) - pendingArtifacts.count)
        for url in urls.prefix(remaining) {
            let accessing = url.startAccessingSecurityScopedResource()
            defer { if accessing { url.stopAccessingSecurityScopedResource() } }
            guard let data = try? Data(contentsOf: url), data.count <= 12 * 1_024 * 1_024 else { continue }
            let type = UTType(filenameExtension: url.pathExtension)
            let mime = type?.preferredMIMEType ?? "image/png"
            pendingArtifacts.append(
                ConversationArtifact(
                    type: "image",
                    url: "data:\(mime);base64,\(data.base64EncodedString())",
                    title: url.lastPathComponent
                )
            )
        }
    }
}

private struct ContextUsagePopover: View {
    let usage: ContextUsageSnapshot
    let onHover: (Bool) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("上下文").font(AppDesign.Typography.headline)
                Spacer()
                Text(usage.utilization, format: .percent.precision(.fractionLength(0)))
                    .font(AppDesign.Typography.headline.monospacedDigit())
            }
            ProgressView(value: usage.utilization)
                .tint(usage.shouldCompress ? .orange : .accentColor)
            metric("输入估算", usage.estimatedInputTokens, suffix: " Token")
            metric("可用预算", usage.availableInputTokens, suffix: " Token")
            HStack {
                Text("距自动压缩")
                Spacer()
                Text(usage.shouldCompress ? "已触发" : "\(usage.tokensUntilCompression.formatted()) Token")
                    .monospacedDigit()
            }
            HStack {
                Text("消息")
                Spacer()
                Text("\(usage.messageCount) 条\(usage.imageCount > 0 ? " · 图 \(usage.imageCount)" : "")")
                    .monospacedDigit()
            }
        }
        .font(AppDesign.Typography.micro)
        .padding(16)
        .frame(width: 300)
        .onHover(perform: onHover)
    }

    private func metric(_ title: String, _ value: Int, suffix: String) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(value.formatted() + suffix).monospacedDigit()
        }
    }
}

private struct ReasoningPopover: View {
    @Bindable var workspace: WorkspaceState

    private var sliderValue: Binding<Double> {
        Binding(
            get: { Double(workspace.reasoningLevel.rawValue) },
            set: { newValue in
                workspace.reasoningLevel = ReasoningLevel(rawValue: Int(newValue.rounded())) ?? .high
            }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("推理强度").font(AppDesign.Typography.headline)
                Spacer()
                Text(workspace.reasoningLevel.title).foregroundStyle(.secondary)
            }
            Slider(value: sliderValue, in: 0...3, step: 1)
                .accessibilityLabel("推理强度")
                .accessibilityValue(workspace.reasoningLevel.title)
            HStack {
                ForEach(ReasoningLevel.allCases) { level in
                    Text(level.title)
                        .font(AppDesign.Typography.micro)
                        .foregroundStyle(level == workspace.reasoningLevel ? .primary : .tertiary)
                    if level != ReasoningLevel.allCases.last { Spacer() }
                }
            }
        }
        .padding(16)
        .frame(width: 300)
    }
}

/// 弹出列表里的一行：悬停有底色、按下更深。用 ButtonStyle 而不是 .onHover + @State，
/// 免得每行都挂一份状态。
private struct ModelRowButtonStyle: ButtonStyle {
    @State private var isHovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                configuration.isPressed
                    ? Color.primary.opacity(0.10)
                    : (isHovering ? Color.primary.opacity(0.06) : .clear),
                in: RoundedRectangle(cornerRadius: 6, style: .continuous)
            )
            .padding(.horizontal, 4)
            .onHover { isHovering = $0 }
    }
}
