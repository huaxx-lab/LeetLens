import SwiftUI
import UniformTypeIdentifiers

struct ConversationWorkspaceView: View {
    @Bindable var workspace: WorkspaceState
    @Bindable var dataStore: LegacyDataStore
    var contentTrailingInset: CGFloat = 0
    /// 左侧问题刻度条占掉的一条：正文与输入框都从这里之后开始排。
    var contentLeadingInset: CGFloat = 0

    var body: some View {
        ZStack(alignment: .bottom) {
            RichConversationWebView(
                messages: conversationMessages,
                conversationRevision: selectedConversation?.revision,
                generation: visibleGeneration,
                scrollTargetID: workspace.questionScrollTargetID,
                scrollTargetRevision: workspace.questionScrollRequestVersion,
                onQuestionActivity: { id, isScrolling in
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
        // 这里**不能**给 inset 变化加动画：它会传进 WKWebView 去改 CSS 变量，
        // 每一帧补间都等于一次整页重排。第三列展开时列宽本来就在逐帧变，
        // 叠上补间就是稳定卡死。位置跳变一次远比卡住半秒好。
        .transaction(value: contentTrailingInset) { $0.animation = nil }
        .task(id: dataStore.isDataReady) {
            guard dataStore.isDataReady else { return }
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
        .padding(.horizontal, AppDesign.Spacing.lg)
        .frame(maxWidth: .infinity)
    }

    private var selectedConversation: ConversationSummary? {
        guard let id = workspace.selectedConversationID else { return nil }
        return dataStore.conversations.first { $0.id == id }
    }

    private var conversationMessages: [ConversationTranscriptMessage] {
        selectedConversation?.messages ?? []
    }

    private var visibleGeneration: ConversationGenerationSnapshot? {
        guard workspace.conversationGeneration?.conversationID == workspace.selectedConversationID else { return nil }
        return workspace.conversationGeneration
    }

    private var visibleQueuedDrafts: [QueuedConversationDraft] {
        workspace.queuedConversationID == workspace.selectedConversationID ? workspace.queuedConversationDrafts : []
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
        let prompt = workspace.draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty, workspace.conversationGeneration?.phase != .generating else { return }
        workspace.draft = ""

        let userMessage = ConversationTranscriptMessage(
            id: Self.messageID(),
            role: "user",
            content: prompt,
            createdAt: .now,
            artifacts: artifacts
        )
        do {
            let conversationID: String
            if let selected = workspace.selectedConversationID {
                conversationID = selected
                try dataStore.appendMessage(userMessage, to: selected)
            } else {
                conversationID = try dataStore.createConversation(title: prompt, firstMessage: userMessage)
                workspace.selectedConversationID = conversationID
            }
            startGeneration(conversationID: conversationID, replacingMessageID: nil)
        } catch {
            workspace.draft = prompt
            showLocalFailure(error.localizedDescription, conversationID: workspace.selectedConversationID ?? "")
        }
    }

    private func retryGeneration() {
        guard let generation = workspace.conversationGeneration, generation.phase == .failed else { return }
        startGeneration(conversationID: generation.conversationID, replacingMessageID: generation.messageID)
    }

    private func startGeneration(
        conversationID: String,
        replacingMessageID: String?,
        continuityPrompt: String? = nil
    ) {
        workspace.conversationGenerationTask?.cancel()
        let assistantID = replacingMessageID ?? Self.messageID()
        let providerID = dataStore.settings.activeProviderID
        let provider = dataStore.providers.first { $0.id == providerID }
        let runtimeIdentity = ConversationRuntimeIdentity(
            providerID: providerID,
            providerName: provider?.name ?? providerID,
            model: provider?.model ?? ""
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
        }
        workspace.conversationGenerationTask = Task {
            do {
                // 跨会话检索要计算查询向量（约 200ms），必须留在任务里，
                // 否则点击发送的那一帧会被 embedding 阻塞。
                // 现在这一步只在策略判定为 `.retrieve` 时才发生。
                let memory = await memoryPrompts(conversationID: conversationID)
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
                    memoryPrompts: memory.prompts,
                    continuityPrompt: continuityPrompt,
                    runtimeIdentity: runtimeIdentity
                )
                // 工具跑在主线程拍下的这份快照上：`LegacyDataStore` 是 @MainActor 的，
                // 而 ReAct 循环在后台任务里；快照也保证一轮对话里模型看到的数据前后一致。
                let toolContext = AgentDataSnapshot.capture(from: dataStore)
                for try await chunk in service.stream(
                    messages: requestMessages,
                    reasoningLevel: workspace.reasoningLevel,
                    providerID: runtimeIdentity.providerID,
                    modelOverride: runtimeIdentity.model,
                    usageConversationID: conversationID,
                    agentTools: Self.agentToolExecutor(
                        snapshot: toolContext,
                        dataStore: dataStore,
                        conversationID: conversationID
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
                try persistGeneratedMessage(conversationID: conversationID, messageID: assistantID)
                workspace.conversationGenerationTask = nil
                workspace.conversationGeneration = nil
                if dispatchQueuedFollowUps(conversationID: conversationID) { return }
                await analyzeLearningIfNeeded(conversationID)
                await archiveConversationIfNeeded(conversationID)
            } catch is CancellationError {
                batcher.flush()
                if finishCancellation(conversationID: conversationID, messageID: assistantID) {
                    workspace.conversationGenerationTask = nil
                    _ = dispatchQueuedFollowUps(conversationID: conversationID)
                }
            } catch {
                batcher.flush()
                if finishFailure(error, conversationID: conversationID, messageID: assistantID) {
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
        let watermark = isFirstArchive ? 0 : conversation.archivedMessageCount
        let total = conversation.messages.count
        guard isFirstArchive || total - watermark >= Self.archiveStride else { return }

        // 首次归档喂全量；之后只喂水位线之后的增量，旧内容靠 previousContext 带过去。
        let pending = watermark > 0 && watermark < total
            ? Array(conversation.messages.suffix(total - watermark))
            : conversation.messages
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
            try dataStore.applyArchive(
                archive,
                to: conversationID,
                messageCount: total,
                renames: isFirstArchive
            )
            await consolidateMemoryFacts()
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
        let prompt = workspace.draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty,
              let current = workspace.conversationGeneration,
              current.phase == .generating,
              current.conversationID == workspace.selectedConversationID
        else { return }
        workspace.draft = ""
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
        memoryPrompts: [String],
        continuityPrompt: String?,
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
        let memory = memoryPrompts.map { ChatRequestMessage(role: "system", content: $0) }
        let continuity = continuityPrompt.map {
            [ChatRequestMessage(role: "system", content: $0)]
        } ?? []
        let managed = ConversationContextManager.build(
            messages: conversation.messages.filter { $0.id != messageID },
            contextSummary: conversation.contextSummary,
            settings: dataStore.settings
        )
        return [system, identity] + memory + continuity + managed
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
        conversationID: String
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
                solutionSearch: { slug in
                    guard let page = try? await LeetCodeAPIClient.shared.fetchSolutions(titleSlug: slug, first: 20)
                    else { return [] }
                    return page.items.map { item in
                        LearningAgentTools.SolutionHit(
                            slug: item.slug,
                            title: item.title,
                            author: item.authorName,
                            summary: String(item.summary.prefix(240)),
                            views: item.views,
                            isOfficial: item.isOfficial
                        )
                    }
                },
                solutionRead: { slug in
                    try? await LeetCodeAPIClient.shared.fetchSolutionArticle(slug: slug).markdown
                },
                videoSearch: { query in
                    await BilibiliAPIClient.search(query: query)
                }
            ).json
        }
    }

    private struct MemoryInjection {
        var prompts: [String] = []
        var didRetrieve = false
    }

    /// 分层注入：目录常驻（几百 token），全量检索只在廉价规则命中时才跑。
    /// 以前每轮都无条件跑一次 BM25 + 查询向量，并塞进最多 4 段原文——
    /// 问"快排怎么写"也照跑，既慢又贵，还容易把无关记忆写进回答里。
    private func memoryPrompts(conversationID: String) async -> MemoryInjection {
        guard let conversation = dataStore.conversations.first(where: { $0.id == conversationID }),
              let query = conversation.messages.last(where: { $0.role == "user" })?.content
        else { return MemoryInjection() }

        var injection = MemoryInjection()

        // L0：极小且稳定，每轮都相关，不值得为它做一次判断。
        let facts = await ConversationMemoryFactStore.shared.facts(dataDirectory: dataStore.dataDirectory)
        if let factPrompt = ConversationMemoryFactPrompt.prompt(for: facts) {
            injection.prompts.append(factPrompt)
        }

        let directory = ConversationMemoryDirectory.entries(
            from: dataStore.conversations,
            excluding: conversationID
        )
        let tier = ConversationMemoryPolicy.tier(for: query, directory: directory)
        guard tier != .none else { return injection }

        // L1：目录常驻。模型是在"有地图"的情况下判断，而不是盲猜存过什么。
        if let index = ConversationMemoryDirectory.prompt(for: directory) {
            injection.prompts.append(index)
        }
        guard tier == .retrieve else { return injection }

        let matches = await dataStore.searchMemory(
            query: query,
            currentConversationID: conversationID
        )
        if let retrieved = ConversationMemoryIndex.prompt(for: matches) {
            injection.prompts.append(retrieved)
            injection.didRetrieve = true
        }
        return injection
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
                            .font(.system(size: 13, weight: .medium))
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
            draft: workspace.draft,
            settings: dataStore.settings
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            if !queuedDrafts.isEmpty {
                queueStatus
                Divider().padding(.horizontal, 10)
            }

            HStack(alignment: .center, spacing: 9) {
            Button { showsImageImporter = true } label: {
                ZStack(alignment: .topTrailing) {
                    Image(systemName: "plus")
                        .frame(width: 28, height: 28)
                    if !pendingArtifacts.isEmpty {
                        Text("\(pendingArtifacts.count)")
                            .font(.system(size: 8, weight: .bold).monospacedDigit())
                            .foregroundStyle(.white)
                            .frame(minWidth: 13, minHeight: 13)
                            .background(Color.accentColor, in: Circle())
                    }
                }
            }
            .buttonStyle(.plain)
            .help(pendingArtifacts.isEmpty ? "添加图片" : "已添加 \(pendingArtifacts.count) 张图片")
            .disabled(isBusyElsewhere)

            TextField(composerPlaceholder, text: $workspace.draft, axis: .vertical)
                .font(.body)
                .textFieldStyle(.plain)
                .lineLimit(1...5)
                .floatingTextScrollIndicators()
                .focused($isComposerFocused)
                .padding(.vertical, 5)
                .onSubmit { primaryAction() }
                .disabled(isBusyElsewhere)

            // 把右侧操作组贴近发送键，空余宽度全部留给输入区；
            // 模型选择不再停在输入框中段。
            Spacer(minLength: AppDesign.Spacing.xs)

            modelPicker

            contextMeter

            Button { showsReasoning.toggle() } label: {
                HStack(spacing: 5) {
                    Text(workspace.reasoningLevel.title)
                    Image(systemName: "chevron.down")
                        .font(.caption2)
                        .rotationEffect(.degrees(showsReasoning ? 180 : 0))
                }
                .frame(minWidth: 44, minHeight: 28)
            }
            .buttonStyle(.plain)
            .popover(isPresented: $showsReasoning, arrowEdge: .bottom) {
                ReasoningPopover(workspace: workspace)
            }
            .help("推理强度")

            Button(action: primaryAction) {
                Image(systemName: sendButtonSymbol)
                    .font(.system(size: sendButtonSymbol == "stop.fill" ? 10 : 13, weight: .semibold))
                    .contentTransition(.symbolEffect(.replace))
                    .foregroundStyle(.white)
                    .frame(width: 30, height: 30)
                    .background(sendButtonColor, in: Circle())
            }
            .buttonStyle(.plain)
            .disabled(sendButtonDisabled)
            .help(sendButtonHelp)
            .keyboardShortcut(.return, modifiers: .command)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
        }
        .frame(minHeight: AppDesign.Size.composerMinimumHeight)
        .navigationGlass(cornerRadius: AppDesign.Radius.composer, interactive: true)
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

    private var queueStatus: some View {
        HStack(spacing: 8) {
            Image(systemName: "text.badge.plus")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
            Text("待发送 \(queuedDrafts.count) 条")
                .font(.caption.weight(.semibold))
            Text(queuedDrafts.map(\.text).joined(separator: " · "))
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer(minLength: 8)
            Button(action: onClearQueue) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .semibold))
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
        !workspace.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var composerPlaceholder: String {
        if isBusyElsewhere { return "另一对话正在生成…" }
        if isGenerating { return "输入补充，发送后进入队列…" }
        return "给 AI 发送消息"
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
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .layoutPriority(-1)
                Image(systemName: "chevron.down").font(.caption2)
            }
            .frame(width: modelPickerWidth, height: 28, alignment: .trailing)
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
                    .font(.system(size: 10, weight: .bold))
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

    private var showsModelIcon: Bool { workspace.windowWidth >= 1_050 }

    private var modelPickerWidth: CGFloat {
        if workspace.windowWidth < 980 { return 92 }
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
        return workspace.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? .secondary : .accentColor
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
        let hasPrompt = !workspace.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
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
                Text("上下文").font(.headline)
                Spacer()
                Text(usage.utilization, format: .percent.precision(.fractionLength(0)))
                    .font(.headline.monospacedDigit())
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
        .font(.caption)
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
                Text("推理强度").font(.headline)
                Spacer()
                Text(workspace.reasoningLevel.title).foregroundStyle(.secondary)
            }
            Slider(value: sliderValue, in: 0...3, step: 1)
                .accessibilityLabel("推理强度")
                .accessibilityValue(workspace.reasoningLevel.title)
            HStack {
                ForEach(ReasoningLevel.allCases) { level in
                    Text(level.title)
                        .font(.caption2)
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
