import XCTest
@testable import LeetCodeAssistant

final class BrowserAddressPolicyTests: XCTestCase {
    func testDraggingBrowserTabReordersContinuouslyAroundHoveredTab() {
        let first = UUID()
        let second = UUID()
        let third = UUID()

        XCTAssertEqual(
            BrowserTabOrderPolicy.reordered(
                [first, second, third],
                dragging: first,
                over: second
            ),
            [second, first, third]
        )
        XCTAssertEqual(
            BrowserTabOrderPolicy.reordered(
                [first, second, third],
                dragging: third,
                over: second
            ),
            [first, third, second]
        )
    }

    func testTrackpadDragCrossesTabMidpointsBeforeChangingPosition() {
        XCTAssertEqual(BrowserTabOrderPolicy.dragMinimumDistance, 6)
        XCTAssertEqual(
            BrowserTabOrderPolicy.targetIndex(
                startIndex: 1,
                translation: 70,
                tabExtent: 172,
                count: 4
            ),
            1
        )
        XCTAssertEqual(
            BrowserTabOrderPolicy.targetIndex(
                startIndex: 1,
                translation: 90,
                tabExtent: 172,
                count: 4
            ),
            2
        )
        XCTAssertEqual(
            BrowserTabOrderPolicy.targetIndex(
                startIndex: 1,
                translation: -190,
                tabExtent: 172,
                count: 4
            ),
            0
        )
        XCTAssertEqual(
            BrowserTabOrderPolicy.targetIndex(
                startIndex: 3,
                translation: 900,
                tabExtent: 172,
                count: 4
            ),
            3
        )
    }

    func testContinuousDragMovesTabToCalculatedIndex() {
        let first = UUID()
        let second = UUID()
        let third = UUID()

        XCTAssertEqual(
            BrowserTabOrderPolicy.moved(
                [first, second, third],
                dragging: first,
                toIndex: 2
            ),
            [second, third, first]
        )
    }

    @MainActor
    func testBrowserPreferencesPersistProjectSpecificBehavior() {
        let suiteName = "BrowserPreferencesTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let preferences = BrowserPreferences(defaults: defaults)
        preferences.linkTarget = .systemBrowser
        preferences.restoresSession = false
        preferences.asksWhereToSaveDownloads = false
        preferences.downloadDirectory = URL(fileURLWithPath: "/tmp/browser-downloads", isDirectory: true)

        let restored = BrowserPreferences(defaults: defaults)
        XCTAssertEqual(restored.linkTarget, .systemBrowser)
        XCTAssertFalse(restored.restoresSession)
        XCTAssertFalse(restored.asksWhereToSaveDownloads)
        XCTAssertEqual(restored.downloadDirectory.path, "/tmp/browser-downloads")
    }

    func testBrowserHistoryStoreDeduplicatesConsecutivePageAndCapsEntries() {
        var history = BrowserHistoryStore(maximumEntries: 2)
        history.record(url: URL(string: "https://example.com/a")!, title: "A", visitedAt: Date(timeIntervalSince1970: 1))
        history.record(url: URL(string: "https://example.com/a")!, title: "A updated", visitedAt: Date(timeIntervalSince1970: 2))
        history.record(url: URL(string: "https://example.com/b")!, title: "B", visitedAt: Date(timeIntervalSince1970: 3))
        history.record(url: URL(string: "https://example.com/c")!, title: "C", visitedAt: Date(timeIntervalSince1970: 4))

        XCTAssertEqual(history.entries.map(\.title), ["C", "B"])
        XCTAssertEqual(history.entries.count, 2)
    }

    func testNormalizeAddsHTTPSWhenSchemeMissing() {
        XCTAssertEqual(BrowserAddressPolicy.normalize("baidu.com"), "https://baidu.com")
        XCTAssertEqual(BrowserAddressPolicy.normalize("  baidu.com  "), "https://baidu.com")
    }

    func testNormalizeKeepsExplicitScheme() {
        XCTAssertEqual(BrowserAddressPolicy.normalize("http://baidu.com"), "http://baidu.com")
        XCTAssertEqual(BrowserAddressPolicy.normalize("https://www.baidu.com/"), "https://www.baidu.com/")
    }

    func testNormalizeRejectsBlankInput() {
        XCTAssertNil(BrowserAddressPolicy.normalize(""))
        XCTAssertNil(BrowserAddressPolicy.normalize("   \n "))
    }

    func testNormalizeRejectsUnsupportedOrMalformedAddresses() {
        XCTAssertNil(BrowserAddressPolicy.normalize("file:///tmp/index.html"))
        XCTAssertNil(BrowserAddressPolicy.normalize("javascript:alert(1)"))
        XCTAssertNil(BrowserAddressPolicy.normalize("https://"))
    }

    func testNavigatesOnlyWhenRequestedAddressChanges() {
        let requested = URL(string: "https://baidu.com")!
        XCTAssertTrue(BrowserAddressPolicy.shouldNavigate(requested: requested, lastRequested: nil))
        XCTAssertFalse(BrowserAddressPolicy.shouldNavigate(requested: requested, lastRequested: requested))
    }

    /// 回归：判定基准必须是"上次请求的地址"。若拿 webView 重定向后的当前地址去比，
    /// 每次视图更新都会重新加载一遍，页面就会一直闪。
    func testRedirectedAddressDoesNotTriggerReload() {
        let requested = URL(string: "https://baidu.com")!
        let redirected = URL(string: "https://www.baidu.com/")!
        XCTAssertNotEqual(requested, redirected)
        XCTAssertFalse(BrowserAddressPolicy.shouldNavigate(requested: requested, lastRequested: requested))
        XCTAssertTrue(BrowserAddressPolicy.shouldNavigate(requested: redirected, lastRequested: requested))
    }

    func testSameAddressCanRetryAfterLoadingStops() {
        let requested = URL(string: "https://example.com")!
        XCTAssertFalse(
            BrowserAddressPolicy.shouldNavigate(
                requested: requested,
                pending: requested,
                isLoading: true
            )
        )
        XCTAssertTrue(
            BrowserAddressPolicy.shouldNavigate(
                requested: requested,
                pending: requested,
                isLoading: false
            )
        )
    }

    func testExternalLinkReusesTheActiveBlankTab() {
        XCTAssertTrue(
            BrowserTabOpeningPolicy.shouldReuseActiveTab(
                requestedNewTab: true,
                activeTabHasPage: false
            )
        )
        XCTAssertFalse(
            BrowserTabOpeningPolicy.shouldReuseActiveTab(
                requestedNewTab: true,
                activeTabHasPage: true
            )
        )
        XCTAssertFalse(
            BrowserTabOpeningPolicy.shouldReuseActiveTab(
                requestedNewTab: false,
                activeTabHasPage: false
            )
        )
    }

    func testTabsShrinkTogetherBeforeTheStripStartsScrolling() {
        let available: CGFloat = 700

        let single = BrowserTabStripSizingPolicy.tabWidth(available: available, count: 1, isFocused: false)
        let few = BrowserTabStripSizingPolicy.tabWidth(available: available, count: 3, isFocused: false)
        let many = BrowserTabStripSizingPolicy.tabWidth(available: available, count: 9, isFocused: false)
        let crowded = BrowserTabStripSizingPolicy.tabWidth(available: available, count: 20, isFocused: false)

        XCTAssertEqual(single, BrowserTabStripSizingPolicy.maximumWidth(isFocused: false))
        XCTAssertEqual(few, BrowserTabStripSizingPolicy.maximumWidth(isFocused: false), "还放得下就别提前缩")
        XCTAssertLessThan(many, few, "放不下时应当一起变窄")
        XCTAssertEqual(crowded, BrowserTabStripSizingPolicy.minimumWidth, "缩到下限就停住，改为滚动")
        XCTAssertGreaterThan(
            BrowserTabStripSizingPolicy.contentWidth(count: 20, tabWidth: crowded),
            available,
            "到下限后内容宽度必须超过可用宽度，标签条才会滚起来"
        )
    }

    func testStripNeverOverflowsTheHeaderNorLeavesASingleTabStranded() {
        let one = BrowserTabStripSizingPolicy.stripWidth(
            headerWidth: 900, count: 1, isFocused: false, showsFocusedChrome: false
        )
        XCTAssertEqual(one, BrowserTabStripSizingPolicy.maximumWidth(isFocused: false))

        let crowded = BrowserTabStripSizingPolicy.stripWidth(
            headerWidth: 900, count: 20, isFocused: false, showsFocusedChrome: false
        )
        XCTAssertEqual(
            crowded,
            BrowserTabStripSizingPolicy.availableWidth(headerWidth: 900, showsFocusedChrome: false)
        )
        XCTAssertLessThan(crowded, 900)
    }

    func testToolAndWebTabsShareOneOrderSoTheyCanInterleave() {
        let first = UUID()
        let second = UUID()

        let fresh = TabStripOrder.items(tools: [.sources], web: [first, second], remembered: [])
        XCTAssertEqual(fresh, [.tool(.sources), .web(first), .web(second)])

        // 记住的顺序说了算，网页标签可以排在「来源」前面。
        let remembered = TabStripOrder.items(
            tools: [.sources],
            web: [first, second],
            remembered: [TabStripItem.web(second).id, TabStripItem.tool(.sources).id]
        )
        XCTAssertEqual(remembered, [.web(second), .tool(.sources), .web(first)])

        // 关掉的标签不会靠记忆复活。
        let closed = TabStripOrder.items(
            tools: [],
            web: [first],
            remembered: [TabStripItem.tool(.sources).id, TabStripItem.web(first).id]
        )
        XCTAssertEqual(closed, [.web(first)])
    }

    func testClosingTheActiveTabFallsToTheNeighbourOnTheRight() {
        let first = UUID()
        let second = UUID()
        let items: [TabStripItem] = [.tool(.sources), .web(first), .web(second)]

        XCTAssertEqual(TabStripOrder.neighbour(of: .tool(.sources), in: items), .web(first))
        XCTAssertEqual(TabStripOrder.neighbour(of: .web(second), in: items), .web(first))
        XCTAssertNil(TabStripOrder.neighbour(of: .web(first), in: [.web(first)]))
    }

    func testDraggedTabLandsWhereThePointerIsEvenAfterTheStripScrolled() {
        let items: [TabStripItem] = [.tool(.sources), .web(UUID()), .web(UUID())]

        XCTAssertEqual(
            TabStripOrder.index(forPointer: 30, contentOrigin: 0, tabWidth: 120, count: items.count),
            0
        )
        XCTAssertEqual(
            TabStripOrder.index(forPointer: 130, contentOrigin: 0, tabWidth: 120, count: items.count),
            1
        )
        // 标签条向左滚了 200pt：同一个屏幕位置对应更靠后的一格。
        XCTAssertEqual(
            TabStripOrder.index(forPointer: 130, contentOrigin: -200, tabWidth: 120, count: items.count),
            2
        )
        XCTAssertEqual(
            TabStripOrder.index(forPointer: 4_000, contentOrigin: 0, tabWidth: 120, count: items.count),
            items.count - 1
        )

        XCTAssertEqual(
            TabStripOrder.moved(items, dragging: items[0], to: 2),
            [items[1], items[2], items[0]]
        )
    }

    func testTabStripGrowsWithNewTabsBeforeItStartsScrolling() {
        let first = BrowserTabStripSizingPolicy.width(
            headerWidth: 620,
            nonBrowserTabCount: 1,
            browserTabCount: 1,
            isFocused: false
        )
        let second = BrowserTabStripSizingPolicy.width(
            headerWidth: 620,
            nonBrowserTabCount: 1,
            browserTabCount: 2,
            isFocused: false
        )

        XCTAssertGreaterThan(second, first, "新建标签时 + 号应跟随标签向右移动")
        XCTAssertLessThanOrEqual(second, 620, "标签条达到右侧控件前应转为滚动，不得遮挡按钮")
    }

    func testOlderBrowserHostCannotReclaimWebViewFromNewHost() {
        XCTAssertTrue(BrowserHostClaimPolicy.accepts(candidateGeneration: 4, activeGeneration: 3))
        XCTAssertTrue(BrowserHostClaimPolicy.accepts(candidateGeneration: 4, activeGeneration: 4))
        XCTAssertFalse(BrowserHostClaimPolicy.accepts(candidateGeneration: 3, activeGeneration: 4))
    }

    func testBlocksSameHostMainFrameHTTPDowngrade() {
        let current = URL(string: "https://www.baidu.com/")!
        let downgrade = URL(string: "http://www.baidu.com/")!

        XCTAssertTrue(
            BrowserAddressPolicy.shouldBlockInsecureDowngrade(
                requested: downgrade,
                current: current,
                isMainFrame: true
            )
        )
        XCTAssertFalse(
            BrowserAddressPolicy.shouldBlockInsecureDowngrade(
                requested: downgrade,
                current: current,
                isMainFrame: false
            )
        )
    }

    func testAllowsHTTPSAndCrossHostNavigation() {
        let current = URL(string: "https://www.baidu.com/")!

        XCTAssertFalse(
            BrowserAddressPolicy.shouldBlockInsecureDowngrade(
                requested: URL(string: "https://www.baidu.com/search"),
                current: current,
                isMainFrame: true
            )
        )
        XCTAssertFalse(
            BrowserAddressPolicy.shouldBlockInsecureDowngrade(
                requested: URL(string: "http://example.com/"),
                current: current,
                isMainFrame: true
            )
        )
    }
}
