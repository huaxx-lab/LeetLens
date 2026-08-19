import XCTest
@testable import LeetCodeAssistant

final class WorkspaceStateTests: XCTestCase {
    func testFloatingContextPanelDoesNotInsetPrimaryWorkspace() {
        XCTAssertEqual(
            ContextPanelOverlayPolicy.primaryTrailingInset(isVisible: true),
            0
        )
        XCTAssertEqual(
            ContextPanelOverlayPolicy.primaryTrailingInset(isVisible: false),
            0
        )
        XCTAssertEqual(
            ContextPanelOverlayPolicy.contentTrailingInset(
                isVisible: true,
                panelWidth: 312
            ),
            336
        )
        XCTAssertEqual(
            ContextPanelOverlayPolicy.contentTrailingInset(
                isVisible: false,
                panelWidth: 312
            ),
            0
        )
    }

    /// 面板宽度必须按档位量化。它会一路传成 webview 的 CSS 变量，
    /// 跟着窗口宽度连续变的话，第三列展开时每一帧都要整页重排（表现为卡死）。
    func testContextPanelWidthIsQuantizedSoItDoesNotChurnEveryFrame() {
        // 相邻若干像素的窗口宽度必须落在同一档，否则逐帧重排还会回来。
        let widths: [CGFloat] = [1_400, 1_403, 1_407, 1_412]
        let panels = widths.map { width -> CGFloat in
            let raw = min(max(width * 0.18, AppDesign.Size.contextPanelMinimum), AppDesign.Size.contextPanelMaximum)
            let quantized = (raw / 40).rounded(.down) * 40
            return min(max(quantized, AppDesign.Size.contextPanelMinimum), AppDesign.Size.contextPanelMaximum)
        }
        XCTAssertEqual(Set(panels).count, 1, "相邻窗口宽度应落在同一档，避免逐帧重排")
    }

    /// 「按钮亮着」和「面板看得见」必须同进同退——否则会出现启动时按钮
    /// 已是打开态、却根本没有悬浮窗。
    func testContextButtonHighlightMatchesActualPanelVisibility() {
        // 不在对话页：即使请求过、也有内容，面板不显示，按钮就不该亮。
        XCTAssertFalse(ContextPanelPresentationPolicy.isVisible(
            contextPresented: true, section: .leetCode, hasContext: true
        ))
        // 没有上下文内容时同理。
        XCTAssertFalse(ContextPanelPresentationPolicy.isVisible(
            contextPresented: true, section: .conversation, hasContext: false
        ))
        XCTAssertTrue(ContextPanelPresentationPolicy.isVisible(
            contextPresented: true, section: .conversation, hasContext: true
        ))
    }

    /// 同一个链接点第二次要回到已开的那个标签，而不是一直堆新标签。
    func testSameDocumentMatchingIgnoresCosmeticURLDifferences() {
        func url(_ value: String) -> URL { URL(string: value)! }
        // scheme、www.、末尾斜杠、fragment 都不影响"是不是同一篇"。
        XCTAssertTrue(BrowserSession.sameDocument(
            url("https://www.bilibili.com/video/BV1XoLPz9EmM/"),
            url("http://bilibili.com/video/BV1XoLPz9EmM#reply")
        ))
        // 查询串要保留：B 站分 P、力扣入口参数都是不同页面。
        XCTAssertFalse(BrowserSession.sameDocument(
            url("https://www.bilibili.com/video/BV1XoLPz9EmM?p=1"),
            url("https://www.bilibili.com/video/BV1XoLPz9EmM?p=2")
        ))
        XCTAssertFalse(BrowserSession.sameDocument(
            url("https://www.bilibili.com/video/BV1XoLPz9EmM"),
            url("https://www.bilibili.com/video/BV1mbFrzyEkj")
        ))
        XCTAssertFalse(BrowserSession.sameDocument(nil, url("https://leetcode.cn/")))
    }

    /// 收起第三列时 B 站的声音要真的停。`pauseAllMediaPlayback` 只管主 frame，
    /// 而播放器在 <iframe> 里，所以必须另有一段脚本遍历子 frame。
    @MainActor
    func testSuspendScriptReachesMediaInsideChildFrames() {
        let script = BrowserMediaLifecycle.pauseInAllFramesScript
        XCTAssertTrue(script.contains("iframe"))
        XCTAssertTrue(script.contains("contentDocument"))
        XCTAssertTrue(script.contains("video,audio"))
        XCTAssertTrue(script.contains("pause()"))
    }

    /// 从放大还原后，第三列必须还在。原来会按 1850 断点重算可见性，
    /// 于是 1470 这种常见窗口一还原就把第三列整个收掉——点"还原"却等于"关闭"。
    @MainActor
    func testRestoringFromFocusKeepsToolColumnVisible() {
        let (preferences, suiteName) = makePreferences()
        defer { preferences.removePersistentDomain(forName: suiteName) }
        let workspace = WorkspaceState(preferences: preferences)
        workspace.handleWindowWidth(1_470)
        workspace.isToolWorkspacePresented = true
        workspace.focusToolWorkspace()
        XCTAssertTrue(workspace.isToolWorkspaceFocused)

        workspace.restoreToolWorkspace()
        XCTAssertFalse(workspace.isToolWorkspaceFocused, "还原后不应再是放大态")
        XCTAssertTrue(workspace.isToolWorkspacePresented, "还原是回到分栏，第三列不该消失")
    }

    func testToolTabsShareTheSameHeaderBaselineAsTheOtherColumns() {
        // 三列列头共用一条中线。侧栏和中间列都往上提去对齐红绿灯，
        // 这一列原来反而下推 8pt，于是标签条明显低于左边两列。
        XCTAssertEqual(ToolHeaderLayoutPolicy.topInset(isFullScreen: false), -6)
        // 全屏没有红绿灯要让位，三列都不偏移。
        XCTAssertEqual(ToolHeaderLayoutPolicy.topInset(isFullScreen: true), 0)
    }

    func testContextCapsuleKeepsShortSourceListsCompact() {
        let short = ContextPanelSizingPolicy.height(
            outputCount: 0,
            sourceCount: 2,
            expandedOutputCount: 0
        )
        let long = ContextPanelSizingPolicy.height(
            outputCount: 8,
            sourceCount: 8,
            expandedOutputCount: 8
        )

        XCTAssertLessThan(short, 210)
        XCTAssertGreaterThan(long, short)
        XCTAssertLessThanOrEqual(long, ContextPanelSizingPolicy.maximumHeight)
    }

    func testQuestionRailRequiresSixQuestionsAndWideConversationWorkspace() {
        XCTAssertFalse(
            QuestionRailPresentationPolicy.isVisible(
                section: .conversation,
                windowWidth: 1_500,
                questionCount: 5
            )
        )
        XCTAssertTrue(
            QuestionRailPresentationPolicy.isVisible(
                section: .conversation,
                windowWidth: 1_500,
                questionCount: 6
            )
        )
        XCTAssertFalse(
            QuestionRailPresentationPolicy.isVisible(
                section: .conversation,
                windowWidth: 1_100,
                questionCount: 8
            )
        )
        XCTAssertFalse(
            QuestionRailPresentationPolicy.isVisible(
                section: .knowledge,
                windowWidth: 1_500,
                questionCount: 8
            )
        )
    }

    func testQuestionRailUsesCompactFixedDensity() {
        XCTAssertEqual(
            QuestionRailPresentationPolicy.railHeight(questionCount: 20, availableHeight: 1_000),
            309,
            accuracy: 0.001
        )
    }

    @MainActor
    func testFocusedToolReplacesPrimaryUntilRestoredOrClosed() {
        let (preferences, suiteName) = makePreferences()
        defer { preferences.removePersistentDomain(forName: suiteName) }
        let state = WorkspaceState(preferences: preferences)
        state.handleWindowWidth(1_900)
        state.isToolWorkspacePresented = true

        state.focusToolWorkspace()
        XCTAssertTrue(state.isToolWorkspaceFocused)

        state.restoreToolWorkspace()
        XCTAssertFalse(state.isToolWorkspaceFocused)
        XCTAssertTrue(state.isToolWorkspacePresented)

        state.focusToolWorkspace()
        state.isToolWorkspacePresented = false
        XCTAssertFalse(state.isToolWorkspaceFocused)
        XCTAssertFalse(state.isToolWorkspaceExpanded)
    }

    @MainActor
    func testRestoringFocusedToolAtCompactWidthRecomputesPanelVisibility() {
        let (preferences, suiteName) = makePreferences()
        defer { preferences.removePersistentDomain(forName: suiteName) }
        let state = WorkspaceState(preferences: preferences)
        state.handleWindowWidth(1_900)
        state.presentTool(.browser)
        state.focusToolWorkspace()
        state.handleWindowWidth(800)

        XCTAssertTrue(state.isToolWorkspaceFocused)
        state.restoreToolWorkspace()

        XCTAssertFalse(state.isToolWorkspaceExpanded)
        XCTAssertFalse(state.isToolWorkspacePresented)
    }

    @MainActor
    func testPresentingSettingsRestoresFocusedToolToInspector() {
        let (preferences, suiteName) = makePreferences()
        defer { preferences.removePersistentDomain(forName: suiteName) }
        let state = WorkspaceState(preferences: preferences)
        state.handleWindowWidth(1_900)
        state.isToolWorkspacePresented = true
        state.focusToolWorkspace()

        state.presentSettings()

        XCTAssertTrue(state.isSettingsPresented)
        XCTAssertTrue(state.isToolWorkspacePresented)
        XCTAssertFalse(state.isToolWorkspaceFocused)
    }

    @MainActor
    func testLeavingSettingsRestoresFocusedToolToInspector() {
        let (preferences, suiteName) = makePreferences()
        defer { preferences.removePersistentDomain(forName: suiteName) }
        let state = WorkspaceState(preferences: preferences)
        state.handleWindowWidth(1_900)
        state.isToolWorkspacePresented = true
        state.presentSettings()
        state.focusToolWorkspace()

        state.dismissSettings()

        XCTAssertFalse(state.isSettingsPresented)
        XCTAssertTrue(state.isToolWorkspacePresented)
        XCTAssertFalse(state.isToolWorkspaceFocused)
    }

    @MainActor
    func testRepeatedQuestionRailClickCreatesANewScrollRequest() {
        let (preferences, suiteName) = makePreferences()
        defer { preferences.removePersistentDomain(forName: suiteName) }
        let state = WorkspaceState(preferences: preferences)

        state.scrollToQuestion("q1")
        let firstVersion = state.questionScrollRequestVersion
        state.scrollToQuestion("q1")

        XCTAssertEqual(state.questionScrollTargetID, "q1")
        XCTAssertEqual(state.questionScrollRequestVersion, firstVersion + 1)
    }

    @MainActor
    func testQuestionRailOnlyRevealsForUserInitiatedScrolling() {
        let (preferences, suiteName) = makePreferences()
        defer { preferences.removePersistentDomain(forName: suiteName) }
        let state = WorkspaceState(preferences: preferences)

        state.updateQuestionNavigation(activeID: "q1", userIsScrolling: false)
        let passivePulse = state.questionRailPulse
        state.updateQuestionNavigation(activeID: "q2", userIsScrolling: false)
        XCTAssertEqual(state.questionRailPulse, passivePulse)

        state.updateQuestionNavigation(activeID: "q3", userIsScrolling: true)
        XCTAssertEqual(state.questionRailPulse, passivePulse + 1)

        state.updateQuestionNavigation(activeID: "q3", userIsScrolling: true)
        XCTAssertEqual(state.questionRailPulse, passivePulse + 1, "同一活动问题的滚动回调不应重复触发全局 pulse")
    }

    @MainActor
    func testConversationGenerationAndQueueSurviveSectionNavigation() {
        let (preferences, suiteName) = makePreferences()
        defer { preferences.removePersistentDomain(forName: suiteName) }
        let state = WorkspaceState(preferences: preferences)
        state.selectedConversationID = "c1"
        state.conversationGeneration = ConversationGenerationSnapshot(
            conversationID: "c1",
            messageID: "a1",
            content: "partial",
            phase: .generating,
            detail: nil
        )
        state.queuedConversationID = "c1"
        state.queuedConversationDrafts = [QueuedConversationDraft(text: "follow up", artifacts: [])]

        state.selectedSection = .knowledge
        state.selectedSection = .conversation

        XCTAssertEqual(state.conversationGeneration?.content, "partial")
        XCTAssertEqual(state.queuedConversationDrafts.map(\.text), ["follow up"])
        XCTAssertEqual(state.queuedConversationID, "c1")
    }

    @MainActor
    func testStopGenerationOnlyCancelsAnActiveGeneration() {
        let (preferences, suiteName) = makePreferences()
        defer { preferences.removePersistentDomain(forName: suiteName) }
        let state = WorkspaceState(preferences: preferences)
        XCTAssertFalse(state.stopConversationGeneration())

        state.conversationGeneration = ConversationGenerationSnapshot(
            conversationID: "c1",
            messageID: "a1",
            content: "partial",
            phase: .generating,
            detail: nil
        )
        let task = Task<Void, Never> { try? await Task.sleep(for: .seconds(10)) }
        state.conversationGenerationTask = task

        XCTAssertTrue(state.stopConversationGeneration())
        XCTAssertTrue(task.isCancelled)
    }

    @MainActor
    func testConversationDerivationCachesInvalidateWithRevision() {
        let (preferences, suiteName) = makePreferences()
        defer { preferences.removePersistentDomain(forName: suiteName) }
        let state = WorkspaceState(preferences: preferences)
        let first = ConversationSummary(
            id: "c1",
            title: "question",
            summary: "",
            updatedAt: Date(timeIntervalSince1970: 1),
            messageCount: 1,
            messages: [ConversationTranscriptMessage(id: "q1", role: "user", content: "第一个问题？", createdAt: .now)]
        )
        let second = ConversationSummary(
            id: "c1",
            title: "question",
            summary: "",
            updatedAt: Date(timeIntervalSince1970: 2),
            messageCount: 2,
            messages: first.messages + [ConversationTranscriptMessage(id: "q2", role: "user", content: "第二个问题？", createdAt: .now)]
        )

        XCTAssertEqual(state.questionRailItems(for: first).map(\.id), ["q1"])
        XCTAssertEqual(state.questionRailItems(for: second).map(\.id), ["q1", "q2"])
    }

    @MainActor
    func testAutomaticToolEventDoesNotInventConversationContext() {
        let (preferences, suiteName) = makePreferences()
        defer { preferences.removePersistentDomain(forName: suiteName) }
        let state = WorkspaceState(preferences: preferences)
        state.handleWindowWidth(1_900)
        state.isContextPanelPresented = false
        state.toolRequested = false

        state.presentTool(.video, automatically: true)

        XCTAssertFalse(state.isContextPanelPresented)
        XCTAssertTrue(state.isToolWorkspacePresented)
        XCTAssertEqual(state.activeTool, .video)
        XCTAssertTrue(state.sources.isEmpty)
    }

    @MainActor
    func testViewAllSourcesPresentsCategorizedRightTool() {
        let (preferences, suiteName) = makePreferences()
        defer { preferences.removePersistentDomain(forName: suiteName) }
        let state = WorkspaceState(preferences: preferences)
        let items = [
            ContextItem(
                id: "source", title: "网页", subtitle: "example.com", systemImage: "globe",
                tool: .browser, url: "https://example.com"
            )
        ]

        state.presentSources(items)

        XCTAssertEqual(state.activeTool, .sources)
        XCTAssertEqual(state.presentedSources, items)
        XCTAssertTrue(state.isToolWorkspacePresented)
    }

    @MainActor
    func testLocalArtifactOpensPreviewWithPayloadInsteadOfLeavingTheApp() {
        let (preferences, suiteName) = makePreferences()
        defer { preferences.removePersistentDomain(forName: suiteName) }
        let state = WorkspaceState(preferences: preferences)
        let item = ContextItem(
            id: "artifact",
            title: "运行报告",
            subtitle: "本次任务输出",
            systemImage: "doc",
            tool: .preview,
            url: "file:///tmp/report.html"
        )

        state.openContextItem(item)

        XCTAssertEqual(state.activeTool, .preview)
        XCTAssertEqual(state.selectedToolItems[.preview], item)
        XCTAssertTrue(state.openToolTabs.contains(.preview))
    }

    @MainActor
    func testOpeningBrowserKeepsSourcesAvailableAsAToolTab() {
        let (preferences, suiteName) = makePreferences()
        defer { preferences.removePersistentDomain(forName: suiteName) }
        let state = WorkspaceState(preferences: preferences)
        let source = ContextItem(
            id: "source", title: "网页", subtitle: "example.com", systemImage: "globe",
            tool: .browser, url: "https://example.com"
        )

        state.presentSources([source])
        state.presentTool(.browser)

        XCTAssertEqual(state.activeTool, .browser)
        XCTAssertTrue(state.openToolTabs.contains(.sources))
        XCTAssertTrue(state.openToolTabs.contains(.browser))
    }

    @MainActor
    func testRepeatedViewAllAndOpeningALinkKeepsOneReusableSourcesTab() {
        let (preferences, suiteName) = makePreferences()
        defer { preferences.removePersistentDomain(forName: suiteName) }
        let state = WorkspaceState(preferences: preferences)
        let source = ContextItem(
            id: "source", title: "Unsplash", subtitle: "unsplash.com", systemImage: "globe",
            tool: .browser, url: "https://unsplash.com/s/photos/kitten"
        )

        state.presentSources([source])
        state.presentSources([source])
        state.openContextItem(source)

        XCTAssertEqual(state.openToolTabs.filter { $0 == .sources }.count, 1)
        XCTAssertTrue(state.openToolTabs.contains(.browser))
        XCTAssertEqual(state.activeTool, .browser)
        state.selectToolTab(.sources)
        XCTAssertEqual(state.activeTool, .sources)
    }

    @MainActor
    func testClosingNonBrowserToolTabReturnsToBrowserWithoutClosingPanel() {
        let (preferences, suiteName) = makePreferences()
        defer { preferences.removePersistentDomain(forName: suiteName) }
        let state = WorkspaceState(preferences: preferences)
        state.presentTool(.evidence)

        state.closeToolTab(.evidence)

        XCTAssertEqual(state.activeTool, .browser)
        XCTAssertEqual(state.openToolTabs, [.browser])
        XCTAssertTrue(state.isToolWorkspacePresented)
    }

    @MainActor
    func testManualToolCloseSuppressesAutomaticReopenForCurrentTask() {
        let (preferences, suiteName) = makePreferences()
        defer { preferences.removePersistentDomain(forName: suiteName) }
        let state = WorkspaceState(preferences: preferences)
        state.isToolWorkspacePresented = false

        state.presentTool(.video, automatically: true)

        XCTAssertFalse(state.isToolWorkspacePresented)
        XCTAssertTrue(state.hasPendingToolActivity)
        XCTAssertEqual(state.activeTool, .video)
    }

    @MainActor
    func testChangingWorkspaceAllowsAutomaticToolOpenAgain() {
        let (preferences, suiteName) = makePreferences()
        defer { preferences.removePersistentDomain(forName: suiteName) }
        let state = WorkspaceState(preferences: preferences)
        state.isToolWorkspacePresented = false
        state.selectedSection = .leetCode

        state.presentTool(.video, automatically: true)

        XCTAssertTrue(state.isToolWorkspacePresented)
        XCTAssertFalse(state.hasPendingToolActivity)
    }

    @MainActor
    func testCompactWidthTemporarilyHidesColumnsWithoutForgettingPreference() {
        let (preferences, suiteName) = makePreferences()
        defer { preferences.removePersistentDomain(forName: suiteName) }
        let state = WorkspaceState(preferences: preferences)
        state.sidebarRequested = true
        state.toolRequested = true

        state.handleWindowWidth(840)
        state.updateSidebarVisibilityFromContainer(false)
        state.updateToolVisibilityFromContainer(false)
        XCTAssertFalse(state.isSidebarPresented)
        XCTAssertFalse(state.isToolWorkspacePresented)
        XCTAssertTrue(state.sidebarRequested)
        XCTAssertTrue(state.toolRequested)

        state.handleWindowWidth(1_900)
        XCTAssertTrue(state.isSidebarPresented)
        XCTAssertTrue(state.isToolWorkspacePresented)
    }

    /// Drains one main-queue turn so deferred layout effects are observable.
    @MainActor
    private func settleMainQueue() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
    }

    @MainActor
    func testManualToolPresentationProtectsPrimaryWorkspaceAtMediumWidth() async {
        let (preferences, suiteName) = makePreferences()
        defer { preferences.removePersistentDomain(forName: suiteName) }
        let state = WorkspaceState(preferences: preferences)
        state.handleWindowWidth(1_100)

        state.isToolWorkspacePresented = true

        XCTAssertTrue(state.isToolWorkspacePresented)
        XCTAssertFalse(state.isContextPanelPresented)

        // Sidebar compaction is deliberately deferred one runloop so presenting the
        // inspector and collapsing a NavigationSplitView column never land in the
        // same frame. Assert the settled state rather than the intermediate one.
        XCTAssertTrue(state.isSidebarPresented)
        await settleMainQueue()
        XCTAssertFalse(state.isSidebarPresented)
    }

    @MainActor
    func testContextPanelCanBeShownWithoutCollapsingTheSidebar() {
        let (preferences, suiteName) = makePreferences()
        defer { preferences.removePersistentDomain(forName: suiteName) }
        let state = WorkspaceState(preferences: preferences)
        state.handleWindowWidth(1_400)

        state.isToolWorkspacePresented = true
        XCTAssertFalse(state.isContextPanelPresented)

        state.isContextPanelPresented = true
        state.updateSidebarVisibilityFromContainer(false)

        XCTAssertTrue(state.isToolWorkspacePresented)
        XCTAssertTrue(state.isContextPanelPresented)
        XCTAssertTrue(state.isSidebarPresented, "悬浮上下文只覆盖内容，不应修改第一列的显隐状态")
    }

    @MainActor
    func testOpeningSourceFromVisibleContextPanelKeepsPanelVisible() {
        let (preferences, suiteName) = makePreferences()
        defer { preferences.removePersistentDomain(forName: suiteName) }
        let state = WorkspaceState(preferences: preferences)
        state.handleWindowWidth(1_400)
        state.isContextPanelPresented = true
        let source = ContextItem(
            id: "source",
            title: "Unsplash",
            subtitle: "unsplash.com",
            systemImage: "globe",
            tool: .browser,
            url: "https://unsplash.com/s/photos/kitten"
        )

        state.openContextItem(source)

        XCTAssertTrue(state.isToolWorkspacePresented)
        XCTAssertEqual(state.activeTool, .browser)
        XCTAssertTrue(state.isContextPanelPresented, "点击来源只应打开右侧标签，不应收起用户已展开的上下文浮层")
    }

    @MainActor
    func testInspectorPresentationAcknowledgementKeepsVisibleContextPanel() {
        let (preferences, suiteName) = makePreferences()
        defer { preferences.removePersistentDomain(forName: suiteName) }
        let state = WorkspaceState(preferences: preferences)
        state.handleWindowWidth(1_400)
        state.isContextPanelPresented = true

        state.presentTool(.browser, preservingContextPanel: true)
        XCTAssertTrue(state.isContextPanelPresented)

        // SwiftUI's inspector binding acknowledges that the already-requested
        // container is visible. That acknowledgement must not be interpreted as
        // a second user presentation, which would recompute adaptive columns.
        state.updateToolVisibilityFromContainer(true)

        XCTAssertTrue(state.isToolWorkspacePresented)
        XCTAssertTrue(state.isContextPanelPresented)
    }

    func testRequestedContextPanelStaysHiddenWithoutRealConversationContext() {
        XCTAssertFalse(
            ContextPanelPresentationPolicy.isVisible(
                contextPresented: true,
                section: .conversation,
                hasContext: false
            )
        )
    }

    func testRequestedContextPanelIsVisibleWhenConversationHasRealContext() {
        XCTAssertTrue(
            ContextPanelPresentationPolicy.isVisible(
                contextPresented: true,
                section: .conversation,
                hasContext: true
            )
        )
    }

    @MainActor
    func testStudyPlanGenerationSurvivesNavigationAndStopsOnlyOnRequest() async {
        let (preferences, suiteName) = makePreferences()
        defer { preferences.removePersistentDomain(forName: suiteName) }
        let state = WorkspaceState(preferences: preferences)
        state.isGeneratingStudyPlan = true
        state.studyPlanGenerationTask = Task {
            try? await Task.sleep(for: .seconds(30))
        }

        state.selectedSection = .conversation
        state.selectedSection = .plan

        XCTAssertTrue(state.isGeneratingStudyPlan)
        XCTAssertNotNil(state.studyPlanGenerationTask)
        XCTAssertTrue(state.stopStudyPlanGeneration())
        await Task.yield()
        XCTAssertTrue(state.studyPlanGenerationTask?.isCancelled == true)
    }

    func testWindowTitleVisibilityUsesHysteresisSoItDoesNotFlickerWhileResizing() {
        // 显示中：一路收窄到 1260 之前都保持显示
        XCTAssertTrue(WindowChromePolicy.showsTitle(current: true, width: 1_300))
        XCTAssertTrue(WindowChromePolicy.showsTitle(current: true, width: 1_260))
        XCTAssertFalse(WindowChromePolicy.showsTitle(current: true, width: 1_259))

        // 已隐藏：回到 1260 还不够，必须越过 1320 才重新显示——1259↔1260 来回拖不再闪
        XCTAssertFalse(WindowChromePolicy.showsTitle(current: false, width: 1_260))
        XCTAssertFalse(WindowChromePolicy.showsTitle(current: false, width: 1_319))
        XCTAssertTrue(WindowChromePolicy.showsTitle(current: false, width: 1_320))
    }

    @MainActor
    func testHeaderLeadingInsetOnlyReservesRoomForTrafficLightsInWindowedMode() {
        let (preferences, suiteName) = makePreferences()
        defer { preferences.removePersistentDomain(forName: suiteName) }
        let state = WorkspaceState(preferences: preferences)

        // 窗口态：最左一列的列头要给红绿灯让位，控件才能与它同处一行
        XCTAssertFalse(state.isWindowFullScreen)
        XCTAssertEqual(state.headerLeadingInset, AppDesign.Size.trafficLightInset)

        // 全屏态：系统收起红绿灯，再留 78pt 就是列头左边一块空洞
        state.handleFullScreenChange(true)
        XCTAssertEqual(state.headerLeadingInset, AppDesign.Spacing.xs)

        state.handleFullScreenChange(false)
        XCTAssertEqual(state.headerLeadingInset, AppDesign.Size.trafficLightInset)
    }

    private func makePreferences() -> (UserDefaults, String) {
        let suiteName = "WorkspaceStateTests.\(UUID().uuidString)"
        return (UserDefaults(suiteName: suiteName)!, suiteName)
    }
}
