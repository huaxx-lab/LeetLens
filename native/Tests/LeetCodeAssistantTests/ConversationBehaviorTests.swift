import XCTest
@testable import LeetCodeAssistant

final class ConversationBehaviorTests: XCTestCase {
    func testAssistantVisualArtifactsDoNotEnterConversationContext() {
        let messages = [
            ConversationTranscriptMessage(
                id: "assistant",
                role: "assistant",
                content: "<think>private chain</think>答案\n\n![结果图](https://example.com/result.png)\n```svg\n<svg></svg>\n```",
                createdAt: .now,
                artifacts: [ConversationArtifact(type: "image", url: "https://example.com/result.png", title: "结果图")]
            )
        ]

        let context = ConversationContextDeriver.derive(messages: messages)
        let managed = ConversationContextManager.build(
            messages: messages,
            contextSummary: "",
            settings: LegacySettingsSnapshot()
        )

        XCTAssertEqual(context.sources.map(\.title), ["结果图"])
        XCTAssertTrue(context.outputs.isEmpty)
        XCTAssertEqual(managed.count, 1)
        XCTAssertFalse(managed[0].content.contains("private chain"))
        XCTAssertFalse(managed[0].content.contains("result.png"))
        XCTAssertFalse(managed[0].content.contains("<svg>"))
        XCTAssertTrue(managed[0].content.contains("视觉内容不回灌上下文"))
    }

    func testOnlyUserImagesContributeToContextUsage() {
        let userImage = ConversationArtifact(type: "image", url: "data:image/png;base64,user", title: "题目截图")
        let assistantImage = ConversationArtifact(type: "image", url: "https://example.com/output.png", title: "输出图")
        let messages = [
            ConversationTranscriptMessage(id: "user", role: "user", content: "看图", createdAt: .now, artifacts: [userImage]),
            ConversationTranscriptMessage(id: "assistant", role: "assistant", content: "完成", createdAt: .now, artifacts: [assistantImage])
        ]

        let usage = ConversationContextEstimator.estimate(
            messages: messages,
            draft: "",
            settings: LegacySettingsSnapshot()
        )

        XCTAssertEqual(usage.imageCount, 1)
    }

    func testManagedContextCompactsToFirstQuestionSummaryAndRecentTail() {
        let long = String(repeating: "算法上下文", count: 80)
        let messages = (0..<14).map { index in
            ConversationTranscriptMessage(
                id: "m\(index)",
                role: index.isMultiple(of: 2) ? "user" : "assistant",
                content: "\(index)-\(long)",
                createdAt: .now
            )
        }
        var settings = LegacySettingsSnapshot()
        settings.contextWindowTokens = 1_200
        settings.reservedOutputTokens = 200
        settings.compressionThreshold = 0.5
        settings.postCompressionRatio = 0.5
        settings.recentMessages = 6

        let managed = ConversationContextManager.build(
            messages: messages,
            contextSummary: "历史结论",
            settings: settings
        )

        XCTAssertEqual(managed.first?.content, messages.first?.content)
        XCTAssertTrue(managed.contains { $0.content.contains("历史结论") })
        XCTAssertTrue(managed.contains { $0.content.contains("较早消息已按上下文预算压缩") })
        XCTAssertTrue(managed.contains { $0.content.hasPrefix("13-") })
        XCTAssertLessThan(managed.count, messages.count)
    }

    func testEmptyConversationHasNoContextItems() {
        let context = ConversationContextDeriver.derive(messages: [])

        XCTAssertTrue(context.sources.isEmpty)
        XCTAssertTrue(context.outputs.isEmpty)
        XCTAssertTrue(context.isEmpty)
    }

    func testBrowserSelectionWithoutURLIsNotInventedAsSource() {
        let message = ConversationTranscriptMessage(
            id: "m1",
            role: "user",
            content: "【任务】解释复杂度\n\n【用户输入】为什么是 O(n)？\n\n【浏览器当前选区】双指针只向前移动",
            createdAt: .now,
            artifacts: [
                ConversationArtifact(type: "image", url: "https://example.com/window.png", title: "滑动窗口图")
            ]
        )

        let context = ConversationContextDeriver.derive(messages: [message])

        XCTAssertEqual(context.sources.map(\.title), ["滑动窗口图"])
        XCTAssertTrue(context.outputs.isEmpty)
    }

    func testBrowserSelectionWithURLBecomesNavigableSource() {
        let message = ConversationTranscriptMessage(
            id: "m1",
            role: "user",
            content: "【用户输入】解释这段代码\n\n【浏览器页面】https://leetcode.cn/problems/two-sum/\n\n【浏览器当前选区】class Solution {}",
            createdAt: .now
        )

        let context = ConversationContextDeriver.derive(messages: [message])

        XCTAssertEqual(context.sources.map(\.title), ["浏览器当前选区"])
        XCTAssertEqual(context.sources.first?.url, "https://leetcode.cn/problems/two-sum/")
    }

    func testContextUsageMatchesLegacyEstimatorShape() {
        let messages = [
            ConversationTranscriptMessage(id: "m1", role: "user", content: "你好 abc", createdAt: .now)
        ]
        let settings = LegacySettingsSnapshot(
            contextWindowTokens: 1_024,
            reservedOutputTokens: 256,
            compressionThreshold: 0.5
        )

        let usage = ConversationContextEstimator.estimate(messages: messages, draft: "", settings: settings)

        XCTAssertEqual(usage.availableInputTokens, 768)
        XCTAssertEqual(usage.compressionTriggerTokens, 384)
        XCTAssertGreaterThan(usage.estimatedInputTokens, 0)
        XCTAssertEqual(usage.messageCount, 1)
        XCTAssertEqual(usage.imageCount, 0)
    }

    func testResponsesReasoningDeltaIsNotRenderedAsAnswerText() {
        let chunks = ChatService.chunks(
            from: ["delta": "正在分析"],
            eventName: "response.reasoning_summary_text.delta"
        )

        XCTAssertEqual(chunks, [.reasoning("正在分析")])
    }

    func testResponsesToolEventProducesToolCall() {
        let chunks = ChatService.chunks(
            from: ["name": "web_search"],
            eventName: "response.function_call_arguments.delta"
        )

        XCTAssertEqual(chunks, [.toolCall("web_search")])
    }

    func testRuntimeModelIdentityOverridesHistoricalAssistantClaims() {
        let identity = ConversationRuntimeIdentity(
            providerID: "opencode-go",
            providerName: "OpenCode Go",
            model: "deepseek-v4-flash"
        )

        XCTAssertTrue(identity.systemPrompt.contains("deepseek-v4-flash"))
        XCTAssertTrue(identity.systemPrompt.contains("历史回答"))
        XCTAssertTrue(identity.systemPrompt.contains("不得沿用"))
    }

    func testStoredGenerationPreservesReasoningAndTools() {
        let snapshot = ConversationGenerationSnapshot(
            conversationID: "c1",
            messageID: "m1",
            content: "结论",
            phase: .generating,
            reasoning: "推理",
            toolCalls: ["web_search"]
        )

        XCTAssertTrue(snapshot.storedContent.contains("<think duration="))
        XCTAssertEqual(snapshot.toolCalls, ["web_search"])
    }

    func testMemoryRAGRetrievesRelevantOldConversationWithMessageSources() async {
        let oldConversation = ConversationSummary(
            id: "old",
            title: "滑动窗口边界",
            summary: "",
            updatedAt: .now,
            messageCount: 2,
            messages: [
                ConversationTranscriptMessage(id: "u1", role: "user", content: "最长无重复子串怎么处理左边界？", createdAt: .now),
                ConversationTranscriptMessage(id: "a1", role: "assistant", content: "用哈希表记录字符上次出现位置，左指针只向前移动。", createdAt: .now)
            ]
        )
        let unrelated = ConversationSummary(
            id: "other",
            title: "macOS 工具栏",
            summary: "",
            updatedAt: .now,
            messageCount: 1,
            messages: [
                ConversationTranscriptMessage(id: "u2", role: "user", content: "SwiftUI Toolbar 如何布局", createdAt: .now)
            ]
        )

        let matches = await ConversationMemoryIndex.search(
            query: "我们之前说的最长无重复子串左指针怎么移动？",
            currentConversationID: "current",
            conversations: [unrelated, oldConversation]
        )

        XCTAssertEqual(matches.first?.conversationID, "old")
        XCTAssertEqual(matches.first?.messageIDs, ["u1", "a1"])
        XCTAssertTrue(ConversationMemoryIndex.prompt(for: matches)?.contains("检索来源") == true)
        XCTAssertTrue(ConversationMemoryIndex.prompt(for: matches)?.contains("当前运行模型身份") == true)
    }

    func testMemoryRAGNeverRetrievesCurrentConversation() async {
        let current = ConversationSummary(
            id: "current",
            title: "当前会话",
            summary: "",
            updatedAt: .now,
            messageCount: 1,
            messages: [
                ConversationTranscriptMessage(id: "m1", role: "user", content: "二分搜索边界", createdAt: .now)
            ]
        )

        let matches = await ConversationMemoryIndex.search(
            query: "二分搜索边界",
            currentConversationID: "current",
            conversations: [current]
        )

        XCTAssertTrue(matches.isEmpty)
    }

    func testMemoryRAGRejectsLowConfidenceShortReply() async {
        let oldConversation = ConversationSummary(
            id: "old",
            title: "普通问答",
            summary: "用户问过一个问题",
            updatedAt: .now,
            messageCount: 1,
            messages: [ConversationTranscriptMessage(id: "m1", role: "user", content: "你问过这个问题", createdAt: .now)]
        )

        let matches = await ConversationMemoryIndex.search(
            query: "是的，你问过。",
            currentConversationID: "current",
            conversations: [oldConversation]
        )

        XCTAssertTrue(matches.isEmpty)
    }

    func testMemoryRAGRejectsShortGreetingEvenWhenHistoryContainsExactGreeting() async {
        let oldConversation = ConversationSummary(
            id: "old",
            title: "Greeting",
            summary: "hello",
            updatedAt: .now,
            messageCount: 1,
            messages: [ConversationTranscriptMessage(id: "m1", role: "user", content: "hello", createdAt: .now)]
        )

        let matches = await ConversationMemoryIndex.search(
            query: "hello",
            currentConversationID: "current",
            conversations: [oldConversation]
        )

        XCTAssertTrue(matches.isEmpty)
        XCTAssertNil(ConversationMemoryIndex.prompt(for: matches))
    }

    func testConversationTemplateHasNoAnswerBadgeAndKeepsThinkingCollapsed() throws {
        let url = try XCTUnwrap(
            Bundle.module.url(forResource: "conversation", withExtension: "html", subdirectory: "RichContent")
                ?? Bundle.module.url(forResource: "conversation", withExtension: "html")
        )
        let html = try String(contentsOf: url, encoding: .utf8)

        XCTAssertFalse(html.contains("<header class=\"answer-head\""))
        XCTAssertFalse(html.contains("<details class=\"think-block\" open"))
        XCTAssertTrue(html.contains("<details class=\"think-block\">"))
    }

    func testMemoryIndexIncrementallyAddsUpdatesAndDeletesConversations() async {
        let firstVersion = ConversationSummary(
            id: "old",
            title: "滑动窗口",
            summary: "",
            updatedAt: Date(timeIntervalSince1970: 1),
            messageCount: 1,
            messages: [ConversationTranscriptMessage(id: "m1", role: "user", content: "最长无重复子串", createdAt: .now)]
        )
        var secondVersion = firstVersion
        secondVersion = ConversationSummary(
            id: firstVersion.id,
            title: firstVersion.title,
            summary: firstVersion.summary,
            updatedAt: Date(timeIntervalSince1970: 2),
            messageCount: 2,
            messages: firstVersion.messages + [
                ConversationTranscriptMessage(id: "m2", role: "assistant", content: "用哈希表和左指针", createdAt: .now)
            ]
        )

        let index = ConversationMemoryIndex()
        let inserted = await index.synchronize(conversations: [firstVersion])
        let updated = await index.synchronize(conversations: [secondVersion])
        let removed = await index.synchronize(conversations: [])

        XCTAssertEqual(inserted.inserted, Set(["old"]))
        XCTAssertEqual(updated.updated, Set(["old"]))
        XCTAssertEqual(removed.removed, Set(["old"]))
        let indexedIDs = await index.indexedConversationIDs
        let documentCount = await index.documentCount
        let residual = await index.search(query: "最长无重复子串", currentConversationID: "current")
        XCTAssertTrue(indexedIDs.isEmpty)
        XCTAssertEqual(documentCount, 0)
        XCTAssertTrue(residual.isEmpty)
    }

    func testMemoryIndexUsesLocalSemanticEmbeddingWhenAvailable() async throws {
        let index = ConversationMemoryIndex()
        guard await index.usesSemanticEmbeddings else {
            throw XCTSkip("This macOS installation has no Simplified Chinese sentence embedding.")
        }
        let relevant = ConversationSummary(
            id: "semantic",
            title: "区间维护",
            summary: "",
            updatedAt: .now,
            messageCount: 1,
            messages: [
                ConversationTranscriptMessage(
                    id: "m1",
                    role: "assistant",
                    content: "用双指针维护满足约束的连续区间，条件失效时移动左边界。",
                    createdAt: .now
                )
            ]
        )
        let unrelated = ConversationSummary(
            id: "other",
            title: "B 站登录",
            summary: "",
            updatedAt: .now,
            messageCount: 1,
            messages: [ConversationTranscriptMessage(id: "m2", role: "user", content: "扫码登录视频账号", createdAt: .now)]
        )
        await index.synchronize(conversations: [unrelated, relevant])

        let matches = await index.search(query: "滑动窗口收缩时左端怎么调整", currentConversationID: "current")

        XCTAssertEqual(matches.first?.conversationID, "semantic")
    }

    func testDurationThinkingAndBareURLAreHandled() {
        let messages = [
            ConversationTranscriptMessage(
                id: "a1",
                role: "assistant",
                content: "<think duration=\"14\">内部过程</think>查看 https://example.com/weather",
                createdAt: .now
            )
        ]

        let managed = ConversationContextManager.build(
            messages: messages,
            contextSummary: "",
            settings: LegacySettingsSnapshot()
        )
        let context = ConversationContextDeriver.derive(messages: messages)

        XCTAssertFalse(managed[0].content.contains("内部过程"))
        XCTAssertEqual(context.sources.first?.url, "https://example.com/weather")
    }

    func testContextSourcesAreClassifiedForRightPanelSections() {
        let web = ContextItem(
            id: "web", title: "Apple", subtitle: "apple.com", systemImage: "globe",
            tool: .browser, url: "https://apple.com"
        )
        let image = ContextItem(
            id: "image", title: "小猫", subtitle: "images.unsplash.com", systemImage: "globe",
            tool: .browser, url: "https://images.unsplash.com/photo-cat"
        )
        let video = ContextItem(
            id: "video", title: "讲解", subtitle: "bilibili.com", systemImage: "play.rectangle",
            tool: .video, url: "https://www.bilibili.com/video/BV1"
        )

        XCTAssertEqual(web.sourceCategory, .web)
        XCTAssertEqual(image.sourceCategory, .image)
        XCTAssertEqual(video.sourceCategory, .video)
        XCTAssertEqual(ContextSourceGrouping.groups(for: [web, image, video]).map(\.category), [.web, .image, .video])
    }

    func testConversationTemplateSupportsIncrementalVisualPreview() throws {
        let url = try XCTUnwrap(
            Bundle.module.url(forResource: "conversation", withExtension: "html", subdirectory: "RichContent")
                ?? Bundle.module.url(forResource: "conversation", withExtension: "html")
        )
        let html = try String(contentsOf: url, encoding: .utf8)

        XCTAssertTrue(html.contains("renderStreamingVisualPreview"))
        XCTAssertTrue(html.contains("streaming-svg-preview"))
        XCTAssertTrue(html.contains("streaming-mermaid-preview"))
        XCTAssertTrue(html.contains("buildInlineImageGalleries"))
        XCTAssertTrue(html.contains("inline-image-gallery"))
        XCTAssertTrue(html.contains("const candidates=[...body.children].filter(imageOnlyNode)"))
        XCTAssertTrue(html.contains("gallery-many"))
        XCTAssertFalse(html.contains("SVG/Mermaid 先按普通代码块渲染"))
    }

    @MainActor
    func testStreamBatcherCoalescesUpdatesUntilFlush() async {
        var updates: [ConversationStreamDelta] = []
        let batcher = ConversationStreamBatcher(interval: .seconds(10)) { updates.append($0) }

        batcher.append(.text("a"))
        batcher.append(.text("b"))
        batcher.append(.reasoning("r"))
        batcher.append(.toolCall("memory_search"))

        XCTAssertTrue(updates.isEmpty)
        batcher.flush()
        XCTAssertEqual(
            updates,
            [ConversationStreamDelta(content: "ab", reasoning: "r", toolCalls: ["memory_search"])]
        )
    }

    @MainActor
    func testStreamBatcherAutomaticallyFlushesNearFiftyMilliseconds() async {
        let flushed = expectation(description: "batched stream update")
        var updates: [ConversationStreamDelta] = []
        let batcher = ConversationStreamBatcher { delta in
            updates.append(delta)
            flushed.fulfill()
        }

        batcher.append(.text("a"))
        batcher.append(.text("b"))
        await fulfillment(of: [flushed], timeout: 0.5)

        XCTAssertEqual(updates, [ConversationStreamDelta(content: "ab")])
    }

    func testContextBaselineAddsDraftWithoutRescanningMessages() {
        let messages = [ConversationTranscriptMessage(id: "m1", role: "user", content: "hello", createdAt: .now)]
        let baseline = ConversationContextEstimator.baseline(messages: messages)
        let withoutDraft = ConversationContextEstimator.estimate(
            baseline: baseline,
            draft: "",
            settings: LegacySettingsSnapshot()
        )
        let withDraft = ConversationContextEstimator.estimate(
            baseline: baseline,
            draft: "world",
            settings: LegacySettingsSnapshot()
        )

        XCTAssertEqual(withoutDraft.messageCount, 1)
        XCTAssertEqual(withDraft.messageCount, 2)
        XCTAssertGreaterThan(withDraft.estimatedInputTokens, withoutDraft.estimatedInputTokens)
    }

    func testQueuedContinuationPersistsOnlyRealUserContent() {
        let drafts = [
            QueuedConversationDraft(text: "哈哈哈", artifacts: []),
            QueuedConversationDraft(text: "再补一个边界用例", artifacts: [])
        ]

        let visible = ConversationQueueContent.userContent(for: drafts)
        let hidden = ConversationQueueContent.continuityPrompt()

        XCTAssertEqual(visible, "哈哈哈\n\n再补一个边界用例")
        XCTAssertFalse(visible.contains("衔接任务"))
        XCTAssertTrue(hidden.contains("内部连续性说明"))
        XCTAssertFalse(hidden.contains("哈哈哈"), "隐藏说明不应复制用户内容")
    }

    func testLegacyQueuedTemplateIsCleanedWithoutChangingOrdinaryMessages() {
        let legacy = """
        【衔接任务】请结合上一条回答，继续处理下面的用户新增要求。

        【用户新增要求】
        【补充 1】
        哈哈哈

        【补充 2】
        再补一个边界用例
        """
        let ordinary = "请解释【用户新增要求】这个标签"

        XCTAssertEqual(
            ConversationQueueContent.visibleContent(fromStored: legacy),
            "哈哈哈\n\n再补一个边界用例"
        )
        XCTAssertEqual(ConversationQueueContent.visibleContent(fromStored: ordinary), ordinary)
    }
}
