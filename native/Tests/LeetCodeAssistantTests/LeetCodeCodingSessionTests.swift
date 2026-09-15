import Foundation
import XCTest
@testable import LeetCodeAssistant

@MainActor
final class LeetCodeCodingSessionTests: XCTestCase {
    private var directory: URL!

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory
            .appending(path: "lc-drafts-\(UUID().uuidString)", directoryHint: .isDirectory)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private let javaTemplate = "class Solution {\n    public int[] twoSum(int[] nums, int target) {\n        \n    }\n}"
    private let pythonTemplate = "class Solution:\n    def twoSum(self, nums, target):\n        "

    private func workspace(slug: String = "two-sum") -> LeetCodeQuestionWorkspace {
        LeetCodeQuestionWorkspace(
            titleSlug: slug,
            questionID: "1",
            htmlContent: "<p>给定一个整数数组 nums 和一个目标值 target</p>",
            difficulty: "EASY",
            topicTags: [],
            sampleTestCases: ["[2,7,11,15]\n9"],
            snippets: [
                LeetCodeCodeSnippet(language: "Java", languageSlug: "java", code: javaTemplate),
                LeetCodeCodeSnippet(language: "Python3", languageSlug: "python3", code: pythonTemplate)
            ],
            canRun: true,
            canSubmit: true
        )
    }

    private func openedSession(slug: String = "two-sum") -> LeetCodeCodingSession {
        let session = LeetCodeCodingSession()
        session.attach(dataDirectory: directory)
        session.openQuestion(slug, solving: true)
        session.prepareEditor(for: workspace(slug: slug))
        return session
    }

    // MARK: - 回归：切页面回来代码被重置

    /// 以前刷题页每次出现（切去对话页再回来）都会走 prepareEditor → loadSnippet，
    /// 无条件把代码覆盖成模板。现在同一篇文档再次 prepare 必须什么都不动。
    func testPreparingTheSameDocumentAgainKeepsTypedCode() {
        let session = openedSession()
        let typed = javaTemplate.replacingOccurrences(of: "        \n", with: "        return new int[0];\n")
        session.editorDidChange(typed, documentID: session.documentID)

        session.prepareEditor(for: workspace())

        XCTAssertEqual(session.code, typed)
        XCTAssertFalse(session.isPristine)
    }

    func testDraftSurvivesAFreshSessionAfterFlush() throws {
        let session = openedSession()
        let typed = javaTemplate + "\n// 用哈希表"
        session.editorDidChange(typed, documentID: session.documentID)
        session.drafts.flush()

        let reopened = openedSession()
        XCTAssertEqual(reopened.code, typed, "退出重开后应该回到写了一半的代码")
        XCTAssertEqual(reopened.language, "java")
    }

    func testSwitchingLanguageKeepsEachLanguageDraftAndRemembersChoice() {
        let session = openedSession()
        let javaCode = javaTemplate + "\n// java"
        session.editorDidChange(javaCode, documentID: session.documentID)

        session.switchLanguage(to: "python3", workspace: workspace())
        XCTAssertEqual(session.code, pythonTemplate)
        let pythonCode = pythonTemplate + "return []"
        session.editorDidChange(pythonCode, documentID: session.documentID)

        session.switchLanguage(to: "java", workspace: workspace())
        XCTAssertEqual(session.code, javaCode)

        session.switchLanguage(to: "python3", workspace: workspace())
        session.drafts.flush()
        // 新题默认用最近手动选的语言。
        let other = openedSession(slug: "add-two-numbers")
        XCTAssertEqual(other.language, "python3")
        // 回到这道题落在它上次用的语言上。
        XCTAssertEqual(openedSession().code, pythonCode)
    }

    func testChangeReportedForAPreviousDocumentIsIgnored() {
        let session = openedSession()
        let javaDocument = session.documentID
        session.switchLanguage(to: "python3", workspace: workspace())

        // 换篇前 Java 编辑器发出、换篇后才到的一条消息。
        session.editorDidChange(javaTemplate + "\n// 迟到的", documentID: javaDocument)

        XCTAssertEqual(session.code, pythonTemplate)
        XCTAssertNil(session.drafts.archive.questions["two-sum"]?.codes["python3"])
    }

    // MARK: - 一键重置

    func testResetRestoresTemplateRemovesDraftAndCanBeUndone() {
        let session = openedSession()
        let typed = javaTemplate + "\n// 写了很多"
        session.editorDidChange(typed, documentID: session.documentID)
        XCTAssertNotNil(session.drafts.archive.questions["two-sum"]?.codes["java"])

        session.resetToTemplate()
        XCTAssertEqual(session.code, javaTemplate)
        XCTAssertTrue(session.isPristine)
        XCTAssertNil(session.drafts.archive.questions["two-sum"]?.codes["java"], "回到模板就不再是草稿")
        XCTAssertEqual(session.discardedCode?.code, typed)

        session.undoReset()
        XCTAssertEqual(session.code, typed)
        XCTAssertNil(session.discardedCode)
        XCTAssertEqual(session.drafts.archive.questions["two-sum"]?.codes["java"]?.code, typed)
    }

    func testResetIsANoOpOnPristineCodeAndUndoDoesNotCrossDocuments() {
        let session = openedSession()
        session.resetToTemplate()
        XCTAssertNil(session.discardedCode)

        session.editorDidChange(javaTemplate + "\n// x", documentID: session.documentID)
        session.resetToTemplate()
        session.switchLanguage(to: "python3", workspace: workspace())
        session.undoReset()
        XCTAssertEqual(session.code, pythonTemplate, "撤销只作用于被重置的那一篇")
    }

    // MARK: - 草稿规则

    func testPristineComparisonIgnoresTrailingWhitespaceAndBlankEdges() {
        XCTAssertTrue(LeetCodeDraftPolicy.isPristine("a  \n\tb\t\n\n", template: "a\n\tb"))
        XCTAssertTrue(LeetCodeDraftPolicy.isPristine("a\r\nb", template: "a\nb"))
        XCTAssertFalse(LeetCodeDraftPolicy.isPristine("a\n b", template: "a\nb"), "行首缩进是真改动")
    }

    func testArchiveIsBoundedByMostRecentUpdate() {
        var archive = LeetCodeDraftArchive()
        let base = Date(timeIntervalSince1970: 1_000)
        for index in 0..<(LeetCodeDraftPolicy.maximumQuestions + 5) {
            LeetCodeDraftPolicy.record(
                code: "code \(index)",
                template: "",
                slug: "q\(index)",
                language: "java",
                in: &archive,
                now: base.addingTimeInterval(Double(index))
            )
        }
        XCTAssertEqual(archive.questions.count, LeetCodeDraftPolicy.maximumQuestions)
        XCTAssertNil(archive.questions["q0"], "最久没动的先淘汰")
        XCTAssertNotNil(archive.questions["q\(LeetCodeDraftPolicy.maximumQuestions + 4)"])
    }

    func testEditedTestCasesPersistAndRestoreToOfficial() {
        let session = openedSession()
        let official = workspace().sampleTestCases
        session.updateTestCase("[3,3]\n6", at: 0, slug: "two-sum", official: official)
        XCTAssertEqual(session.drafts.archive.questions["two-sum"]?.testCases, ["[3,3]\n6"])

        session.restoreOfficialTestCases(slug: "two-sum", official: official)
        XCTAssertEqual(session.testCases(for: "two-sum", official: official), official)
        XCTAssertNil(session.drafts.archive.questions["two-sum"]?.testCases)
    }

    func testAssistantConversationPointerIsDroppedWhenConversationIsGone() {
        let session = openedSession()
        session.setAssistantConversationID("c_1", for: "two-sum")
        XCTAssertEqual(session.assistantConversationID(for: "two-sum", existing: ["c_1"]), "c_1")
        XCTAssertNil(session.assistantConversationID(for: "two-sum", existing: []))
    }

    // MARK: - 问 AI 的上下文

    func testAssistantContextCarriesNumberedCodeSelectionAndFailingCase() {
        let result = LeetCodeJudgeResult(
            kind: "submit", taskID: "9", state: "SUCCESS", status: "Wrong Answer", statusCode: 11,
            accepted: false, totalCorrect: 3, totalTestCases: 57, runtime: "", memory: "",
            compileError: "", runtimeError: "", input: "[3,2,4]\n6", output: "[0,0]", expectedOutput: "[1,2]",
            compareResult: "", aiJudgeMessage: ""
        )
        let prompt = LeetCodeAssistantContext.prompt(.init(
            frontendID: "1",
            title: "两数之和",
            difficulty: "简单",
            statement: "给定一个整数数组",
            language: "java",
            code: "int a;\nint b;",
            isPristine: false,
            selection: LeetCodeEditorSelection(text: "int b;", fromLine: 2, toLine: 2),
            judgeResult: result,
            diagnostics: []
        ))
        XCTAssertTrue(prompt.contains("1| int a;\n2| int b;"), "代码要带行号，AI 才能指到具体哪一行")
        XCTAssertTrue(prompt.contains("第 2 行"))
        XCTAssertTrue(prompt.contains("通过用例：3/57"))
        XCTAssertTrue(prompt.contains("失败用例输入：[3,2,4]"))
        XCTAssertTrue(prompt.contains("预期输出：[1,2]"))
        XCTAssertTrue(prompt.contains("类型：提交"))
    }

    func testAssistantContextOmitsDetachedCodeAndClipsHugeInputs() {
        let huge = String(repeating: "9", count: LeetCodeAssistantContext.statementLimit + 500)
        let prompt = LeetCodeAssistantContext.prompt(.init(
            frontendID: "1", title: "两数之和", difficulty: "", statement: huge, language: "java",
            code: nil, isPristine: true, selection: nil, judgeResult: nil, diagnostics: []
        ))
        XCTAssertFalse(prompt.contains("## 当前代码"))
        XCTAssertTrue(prompt.contains("已截断"))
        XCTAssertLessThan(prompt.count, LeetCodeAssistantContext.statementLimit + 600)
    }
}

@MainActor
final class InterfaceScaleTests: XCTestCase {
    /// 用户选定的"温和跟随"口径（2026-09）。改曲线前先看 `InterfaceMetrics` 上的注释：
    /// ×1.38 被否掉过，默认 ×1.0 又被反馈太小。
    func testDisplayScaleCurveMatchesAgreedTable() {
        XCTAssertEqual(InterfaceMetrics.displayScale(workAreaWidth: 1_470, height: 863), 1.0, "13.6\" 内建屏")
        XCTAssertEqual(InterfaceMetrics.displayScale(workAreaWidth: 1_440, height: 875), 1.0)
        XCTAssertEqual(InterfaceMetrics.displayScale(workAreaWidth: 1_920, height: 1_080), 1.12, "24\" 1080p 外接屏")
        XCTAssertEqual(InterfaceMetrics.displayScale(workAreaWidth: 2_560, height: 1_415), 1.18, "2K 封顶")
        XCTAssertEqual(InterfaceMetrics.displayScale(workAreaWidth: 5_120, height: 2_880), InterfaceMetrics.maximumDisplayScale)
        XCTAssertEqual(InterfaceMetrics.displayScale(workAreaWidth: 0, height: 0), 1)
    }
}

/// 防回退：View 层不许再用不跟「界面字号」走的系统文字样式。
final class TypographyCoverageTests: XCTestCase {
    func testViewsDoNotUseFixedSystemTextStyles() throws {
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(path: "Sources/LeetCodeAssistant")
        let pattern = try NSRegularExpression(
            pattern: #"\.font\(\.(largeTitle|title|title2|title3|headline|subheadline|body|callout|footnote|caption|caption2)\b|\.system\(\.(largeTitle|title|title2|title3|headline|subheadline|body|callout|footnote|caption|caption2)\b|@ScaledMetric"#
        )
        var offenders: [String] = []
        let enumerator = FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil)
        while let url = enumerator?.nextObject() as? URL {
            guard url.pathExtension == "swift" else { continue }
            let text = try String(contentsOf: url, encoding: .utf8)
            for (index, line) in text.components(separatedBy: "\n").enumerated() {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard !trimmed.hasPrefix("//") else { continue }
                let range = NSRange(line.startIndex..., in: line)
                if pattern.firstMatch(in: line, range: range) != nil {
                    offenders.append("\(url.lastPathComponent):\(index + 1): \(trimmed)")
                }
            }
        }
        XCTAssertTrue(offenders.isEmpty, "改用 AppDesign.Typography：\n" + offenders.joined(separator: "\n"))
    }
}

/// 分栏抓取带是盖在内容上的 NSView，命中测试总是赢。滚动条离边的距离必须
/// 大于抓取带伸进列里的宽度，否则 thumb 在抓取带底下点不着（2026-09 用户报过）。
@MainActor
final class ScrollIndicatorClearanceTests: XCTestCase {
    func testScrollThumbStaysClearOfColumnResizeBand() {
        XCTAssertGreaterThan(FloatingScrollIndicator.edgeClearance, ColumnResizeHandle.thickness)
    }
}

/// 界面重叠的回归：任何一栏的宽度都不能超过它拿到的空间。
@MainActor
final class LayoutOverflowTests: XCTestCase {
    func testProportionalSplitNeverExceedsTotalWhenMinimumsDoNotFit() {
        for total in stride(from: CGFloat(200), through: 1_600, by: 37) {
            for fraction in [0.1, 0.5, 0.9] {
                let leading = ProportionalSplitLayout.leadingWidth(total: total, fraction: fraction, minLeading: 360, minTrailing: 380)
                XCTAssertGreaterThanOrEqual(leading, 0)
                XCTAssertLessThanOrEqual(leading + 1, total, "total=\(total) fraction=\(fraction)")
                if total >= 741 {
                    XCTAssertGreaterThanOrEqual(leading, 360)
                    XCTAssertGreaterThanOrEqual(total - leading - 1, 380)
                }
            }
        }
    }

    /// 2026-09 用户截图：侧栏 + 第三列都开着时中间列约 500pt，上下文浮层还在，
    /// 正文让出 350pt 后输入框放不下，整列居中溢出，左侧被侧栏盖住、右侧被浮层压住。
    func testContextPanelIsSuppressedWhenColumnCannotHoldItBesideContent() {
        let panel = AppDesign.Size.contextPanelMinimum
        XCTAssertFalse(ContextPanelPresentationPolicy.fits(columnWidth: 500, panelWidth: panel))
        XCTAssertTrue(ContextPanelPresentationPolicy.fits(columnWidth: 1_100, panelWidth: panel))
        XCTAssertTrue(ContextPanelPresentationPolicy.fits(columnWidth: 0, panelWidth: panel), "还没量到宽度时不闪")
    }
}
