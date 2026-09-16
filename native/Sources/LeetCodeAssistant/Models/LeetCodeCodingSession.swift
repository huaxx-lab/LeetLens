import Foundation
import Observation

// MARK: - 草稿存档

/// 一道题在某种语言下的代码草稿。只存"和力扣初始模板不一样"的代码——
/// 和模板一字不差的不是草稿，存了反而会让「重置」按钮一直亮着。
struct LeetCodeCodeDraft: Codable, Equatable, Sendable {
    var code: String
    var updatedAt: Date
}

struct LeetCodeQuestionDraft: Codable, Equatable, Sendable {
    /// 这道题上次用的语言。换题回来要落在它上面，而不是全局默认的 Java。
    var language: String?
    var codes: [String: LeetCodeCodeDraft] = [:]
    /// 改过的测试用例；和官方样例一致时为 nil。
    var testCases: [String]?
    /// 在这道题里「问 AI」开出来的会话。会话本身在 conversations.json，这里只记指向。
    var assistantConversationID: String?
    var updatedAt: Date

    var isEmpty: Bool {
        codes.isEmpty && testCases == nil && assistantConversationID == nil
    }
}

struct LeetCodeDraftArchive: Codable, Equatable, Sendable {
    var version = 1
    /// 最近一次**手动**切换的语言，新题默认用它。
    var preferredLanguage: String?
    var questions: [String: LeetCodeQuestionDraft] = [:]
}

/// 草稿规则。全是纯函数，测试直接覆盖。
enum LeetCodeDraftPolicy {
    /// 有界增长：最多记这么多道题，超出按最近修改时间淘汰。
    static let maximumQuestions = 400
    /// 单份代码上限。力扣代码框自己限 100KB，给足余量。
    static let maximumCodeLength = 256_000

    /// 与模板"相同"的判定忽略行尾空白与首尾空行：编辑器格式化、末尾多敲一个回车
    /// 都不算真的写了代码。
    static func isPristine(_ code: String, template: String) -> Bool {
        normalized(code) == normalized(template)
    }

    static func normalized(_ code: String) -> String {
        code
            .replacingOccurrences(of: "\r\n", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { line in
                var line = Substring(line)
                while let last = line.last, last == " " || last == "\t" { line.removeLast() }
                return String(line)
            }
            .joined(separator: "\n")
            .trimmingCharacters(in: .newlines)
    }

    /// 更新一份代码草稿。返回是否真的有变化（没变化就不必落盘）。
    @discardableResult
    static func record(
        code: String,
        template: String,
        slug: String,
        language: String,
        in archive: inout LeetCodeDraftArchive,
        now: Date = .now
    ) -> Bool {
        guard !slug.isEmpty, !language.isEmpty else { return false }
        var question = archive.questions[slug] ?? LeetCodeQuestionDraft(updatedAt: now)
        let previous = question.codes[language]
        if isPristine(code, template: template) {
            guard previous != nil else { return false }
            question.codes[language] = nil
        } else {
            let clipped = String(code.prefix(maximumCodeLength))
            guard previous?.code != clipped else { return false }
            question.codes[language] = LeetCodeCodeDraft(code: clipped, updatedAt: now)
        }
        question.updatedAt = now
        store(question, slug: slug, in: &archive)
        return true
    }

    static func store(_ question: LeetCodeQuestionDraft, slug: String, in archive: inout LeetCodeDraftArchive) {
        // 代码回到模板、用例没改、没开过 AI、也没换过语言——这条记录没有任何信息，删掉。
        archive.questions[slug] = question.isEmpty && question.language == nil ? nil : question
        prune(&archive)
    }

    static func prune(_ archive: inout LeetCodeDraftArchive) {
        guard archive.questions.count > maximumQuestions else { return }
        let keep = archive.questions
            .sorted { $0.value.updatedAt > $1.value.updatedAt }
            .prefix(maximumQuestions)
            .map(\.key)
        archive.questions = archive.questions.filter { keep.contains($0.key) }
    }

    /// 打开一道题时用哪种语言：这道题上次用的 → 最近手动选的 → Java → 第一个可用的。
    static func language(
        for slug: String,
        available: [String],
        archive: LeetCodeDraftArchive
    ) -> String? {
        guard !available.isEmpty else { return nil }
        let candidates = [archive.questions[slug]?.language, archive.preferredLanguage, "java"]
        for candidate in candidates.compactMap({ $0 }) where available.contains(candidate) {
            return candidate
        }
        return available.first
    }
}

/// 落盘：`leetcode-drafts.json`，和其它数据文件同目录。
///
/// 写入是防抖的（每次按键都会改草稿），但**离开前台 / 退出前必须 `flush()`**，
/// 否则最后不到一秒的输入会丢。
@MainActor
final class LeetCodeDraftStore {
    static let fileName = "leetcode-drafts.json"
    static let saveDelay: Duration = .milliseconds(700)

    private(set) var archive = LeetCodeDraftArchive()
    private var directory: URL?
    private var pendingSave: Task<Void, Never>?
    private var isDirty = false

    func attach(directory: URL) {
        guard self.directory != directory else { return }
        self.directory = directory
        let url = directory.appending(path: Self.fileName)
        guard let data = try? Data(contentsOf: url) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        if let decoded = try? decoder.decode(LeetCodeDraftArchive.self, from: data) {
            archive = decoded
        }
    }

    func update(_ body: (inout LeetCodeDraftArchive) -> Bool) {
        guard body(&archive) else { return }
        isDirty = true
        pendingSave?.cancel()
        pendingSave = Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.saveDelay)
            guard !Task.isCancelled else { return }
            self?.flush()
        }
    }

    func flush() {
        pendingSave?.cancel()
        pendingSave = nil
        guard isDirty, let directory else { return }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        encoder.outputFormatting = [.sortedKeys]
        do {
            let data = try encoder.encode(archive)
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            try data.write(to: directory.appending(path: Self.fileName), options: .atomic)
            isDirty = false
        } catch {
            NSLog("LeetCode draft save failed: %@", error.localizedDescription)
        }
    }
}

// MARK: - 刷题会话

enum LeetCodeOverviewSection: String, CaseIterable, Identifiable {
    case library, activity, submissions
    var id: String { rawValue }
    var title: String {
        switch self {
        case .library: "题库"
        case .activity: "动态"
        case .submissions: "提交"
        }
    }
}

enum LeetCodeStatusFilter: String, CaseIterable, Identifiable {
    case all, todo, tried, solved
    var id: String { rawValue }
    var title: String {
        switch self {
        case .all: "全部"
        case .todo: "未开始"
        case .tried: "尝试过"
        case .solved: "已通过"
        }
    }

    func matches(_ question: LeetCodeQuestion) -> Bool {
        switch self {
        case .all: true
        case .todo: question.status == "TO_DO"
        case .tried: question.status == "TRIED"
        case .solved: question.status == "SOLVED"
        }
    }
}

enum LeetCodeDifficultyFilter: String, CaseIterable, Identifiable {
    case all, easy, medium, hard
    var id: String { rawValue }
    var title: String {
        switch self {
        case .all: "全部难度"
        case .easy: "简单"
        case .medium: "中等"
        case .hard: "困难"
        }
    }

    func matches(_ question: LeetCodeQuestion) -> Bool {
        self == .all || question.difficulty.lowercased() == rawValue
    }
}

enum LeetCodeJudgeAction: Sendable {
    case run, submit
}

/// 编辑器里当前选中的代码。问 AI 时作为"我指的是这几行"附带过去。
struct LeetCodeEditorSelection: Hashable, Sendable {
    let text: String
    /// 1 起算，闭区间。
    let fromLine: Int
    let toLine: Int

    var lineCaption: String {
        fromLine == toLine ? "第 \(fromLine) 行" : "第 \(fromLine)–\(toLine) 行"
    }
}

/// AI 助手浮窗的两种用法：自由问答，或者原来那套"一级一级要"的提示。
enum LeetCodeAssistantMode: String, CaseIterable, Identifiable {
    case chat, hints
    var id: String { rawValue }
    var title: String {
        switch self {
        case .chat: "问答"
        case .hints: "分级提示"
        }
    }
}

/// 刷题页的全部工作状态。
///
/// **为什么不再放在 View 的 `@State` 里**：`PrimaryWorkspaceView` 按分区 `switch`，
/// 切到对话页时 `LeetCodeWorkspaceView` 整个被销毁，@State 跟着清空——
/// 选中的题、写了一半的代码、判题结果全没了，回来只剩题库列表。
/// 这个对象由根视图持有，页面来回切不受影响；代码草稿另外落盘，退出重开也还在。
@MainActor
@Observable
final class LeetCodeCodingSession {
    // MARK: 导航

    var overviewSection = LeetCodeOverviewSection.library
    var searchText = ""
    var statusFilter = LeetCodeStatusFilter.all
    var difficultyFilter = LeetCodeDifficultyFilter.all
    var selectedQuestionSlug: String?
    var selectedSubmissionID: String?
    var isSolving = false

    // MARK: 编辑器

    /// 当前编辑器里的代码。只有编辑器回报和本类的方法会写它。
    private(set) var code = ""
    private(set) var language = "java"
    /// 编辑器文档的身份（题 + 语言）。它一变，编辑器整篇重载并**清空撤销历史**——
    /// 不清的话换题后按 ⌘Z 会把上一题的代码撤回到这一题里来。
    private(set) var documentID = ""
    private(set) var templateCode = ""
    var selection: LeetCodeEditorSelection?
    var diagnostics = LeetCodeEditorDiagnostics()

    /// 刚被「重置」替换掉的代码，给浮层上的「撤销」用。
    private(set) var discardedCode: (documentID: String, code: String)?
    private(set) var resetNoticeVersion = 0

    var isPristine: Bool {
        LeetCodeDraftPolicy.isPristine(code, template: templateCode)
    }

    // MARK: 测试用例与判题

    var editableTestCasesBySlug: [String: [String]] = [:]
    var selectedTestCaseIndexBySlug: [String: Int] = [:]
    var bottomPanelHeightsBySlug: [String: CGFloat] = [:]
    private(set) var judgeSlug: String?
    private(set) var judgeAction: LeetCodeJudgeAction?
    private(set) var judgeProgress: LeetCodeJudgeProgress?
    private(set) var judgeResult: LeetCodeJudgeResult?
    private(set) var judgeError: String?

    // MARK: AI 助手

    var isAssistantPresented = false
    var assistantMode = LeetCodeAssistantMode.chat
    var assistantDrafts: [String: String] = [:]
    /// 问 AI 时附带哪些上下文。默认全开：用户最常问的就是"我这段为什么不对"。
    var attachesCode = true
    var attachesJudgeResult = true
    var attachesSelection = true
    private(set) var hints: [CodingHint] = []
    private(set) var hintSlug = ""
    private(set) var isHinting = false
    private(set) var hintError = ""

    // MARK: AI 就地标注

    /// 当前文档上的 AI 修改建议。跟着代码编辑重新定位，原文被改掉的自动作废。
    private(set) var reviewSuggestions: [CodeReviewSuggestion] = []
    /// 建议属于哪篇文档：换题 / 换语言后旧建议一律不显示。
    private(set) var reviewDocumentID = ""
    /// 建议列表整体换了一批时加一：编辑器据此重画。单纯随编辑挪位置不加（编辑器里的标注自己会跟着文字走）。
    private(set) var reviewRevision = 0
    private(set) var isReviewing = false
    private(set) var reviewError = ""
    /// 「全部接受」请求计数，编辑器侧执行（保留撤销历史与滚动位置）。
    private(set) var acceptAllRequest = 0
    /// 运行 / 提交没通过时自动标注。**默认关**：没通过的第一反应应该是自己对着失败用例
    /// 再走一遍，直接把答案标到行上等于替他想。想不出来时结果区有「给个方向」，
    /// 再不行才是「标到代码上」。愿意让它自动标的人可以在这里打开。
    var autoReviewOnFailure: Bool = UserDefaults.standard.object(forKey: "leetcode.autoReviewOnFailure") as? Bool ?? false {
        didSet { UserDefaults.standard.set(autoReviewOnFailure, forKey: "leetcode.autoReviewOnFailure") }
    }
    @ObservationIgnored private var reviewTask: Task<Void, Never>?

    var visibleSuggestions: [CodeReviewSuggestion] {
        reviewDocumentID == documentID ? reviewSuggestions : []
    }

    @ObservationIgnored let drafts = LeetCodeDraftStore()
    @ObservationIgnored private var isLoadingDocument = false

    init() {}

    // MARK: - 打开题目

    func attach(dataDirectory: URL) {
        drafts.attach(directory: dataDirectory)
    }

    func openQuestion(_ slug: String, solving: Bool = false) {
        selectedQuestionSlug = slug
        isSolving = solving
    }

    func closeQuestion() {
        selectedQuestionSlug = nil
        selectedSubmissionID = nil
        isSolving = false
        isAssistantPresented = false
    }

    /// 题目数据就绪后调用。已经打开着同一篇文档时**什么都不做**——
    /// 以前每次回到这道题都会把代码重置成模板，就是这里无条件覆盖造成的。
    func prepareEditor(for workspace: LeetCodeQuestionWorkspace) {
        let slug = workspace.titleSlug
        guard selectedQuestionSlug == slug else { return }
        let available = workspace.snippets.map(\.languageSlug)
        guard let resolved = LeetCodeDraftPolicy.language(for: slug, available: available, archive: drafts.archive)
        else {
            loadDocument(slug: slug, language: language, template: "", code: "")
            return
        }
        let target = documentIdentity(slug: slug, language: resolved)
        guard target != documentID else { return }
        let template = workspace.snippets.first { $0.languageSlug == resolved }?.code ?? ""
        let saved = drafts.archive.questions[slug]?.codes[resolved]?.code
        loadDocument(slug: slug, language: resolved, template: template, code: saved ?? template)

        if editableTestCasesBySlug[slug] == nil {
            editableTestCasesBySlug[slug] = drafts.archive.questions[slug]?.testCases
                ?? LeetCodeTestCaseWorkspace.editableCases(from: workspace.sampleTestCases)
        }
    }

    /// 切换语言。当前语言的代码早在每次按键时就存成草稿了，这里直接换篇。
    func switchLanguage(to next: String, workspace: LeetCodeQuestionWorkspace) {
        let slug = workspace.titleSlug
        guard next != language || documentID != documentIdentity(slug: slug, language: next) else { return }
        drafts.update { archive in
            archive.preferredLanguage = next
            var question = archive.questions[slug] ?? LeetCodeQuestionDraft(updatedAt: .now)
            question.language = next
            question.updatedAt = .now
            LeetCodeDraftPolicy.store(question, slug: slug, in: &archive)
            return true
        }
        let template = workspace.snippets.first { $0.languageSlug == next }?.code ?? ""
        let saved = drafts.archive.questions[slug]?.codes[next]?.code
        loadDocument(slug: slug, language: next, template: template, code: saved ?? template)
    }

    private func loadDocument(slug: String, language: String, template: String, code: String) {
        isLoadingDocument = true
        defer { isLoadingDocument = false }
        self.language = language
        templateCode = template
        self.code = code
        documentID = documentIdentity(slug: slug, language: language)
        discardedCode = nil
        selection = nil
        diagnostics = LeetCodeEditorDiagnostics()
        clearReview()
    }

    func documentIdentity(slug: String, language: String) -> String {
        "\(slug)|\(language)"
    }

    // MARK: - 编辑

    /// 编辑器回报内容。带上文档身份：换篇的瞬间旧文档可能还有一条在路上，
    /// 不校验就会把上一种语言的代码写进这一种语言的草稿。
    func editorDidChange(_ value: String, documentID reported: String) {
        guard !isLoadingDocument, reported == documentID, value != code else { return }
        code = value
        persistCurrentCode()
        relocateSuggestions()
    }

    // MARK: - AI 就地标注

    enum ReviewTrigger: Sendable {
        /// 工具条上点「AI 检查」。
        case manual
        /// 运行 / 提交没通过。
        case judgeFailure
        /// AI 问答里点到了具体行，把它落到代码上。
        case assistantReply(String)
    }

    func requestReview(
        _ trigger: ReviewTrigger,
        question: LeetCodeQuestion?,
        workspace: LeetCodeQuestionWorkspace,
        dataStore: LegacyDataStore
    ) {
        guard documentID.hasPrefix(workspace.titleSlug + "|"),
              !code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !isPristine
        else { return }
        reviewTask?.cancel()
        let requestedDocument = documentID
        let requestedCode = code
        let judgeSummary = Self.judgeSummary(judgeState(for: workspace.titleSlug).result)
        let guidance: String? = if case .assistantReply(let text) = trigger { text } else { nil }
        isReviewing = true
        reviewError = ""
        reviewTask = Task { [weak self] in
            do {
                let suggestions = try await ChatService(dataDirectory: dataStore.dataDirectory).requestCodeReview(
                    title: question?.title ?? workspace.titleSlug,
                    content: LeetCodeQuestionActionBar.plainText(workspace.htmlContent),
                    code: requestedCode,
                    language: self?.language ?? "java",
                    judgeSummary: judgeSummary,
                    guidance: guidance,
                    providerID: AITaskRoute.codingHint.providerID(in: dataStore.settings)
                )
                guard let self, !Task.isCancelled, self.documentID == requestedDocument else { return }
                self.isReviewing = false
                // 请求期间用户又改了代码：按新代码重新定位，改没了的丢掉。
                let current = self.code
                self.reviewSuggestions = suggestions.compactMap { CodeReviewPolicy.relocate($0, in: current) }
                self.reviewDocumentID = requestedDocument
                self.reviewRevision &+= 1
                if self.reviewSuggestions.isEmpty, case .manual = trigger {
                    self.reviewError = "没有发现需要修改的地方"
                }
            } catch is CancellationError {
                return
            } catch {
                guard let self, !Task.isCancelled else { return }
                self.isReviewing = false
                self.reviewError = error.localizedDescription
            }
        }
    }

    /// 编辑器里点了「接受」或「忽略」，或者建议所在的行被改掉了。
    func resolveSuggestion(id: String) {
        guard reviewSuggestions.contains(where: { $0.id == id }) else { return }
        reviewSuggestions.removeAll { $0.id == id }
    }

    func acceptAllSuggestions() {
        guard !visibleSuggestions.isEmpty else { return }
        acceptAllRequest &+= 1
    }

    func clearReview() {
        reviewTask?.cancel()
        reviewTask = nil
        isReviewing = false
        reviewError = ""
        guard !reviewSuggestions.isEmpty else { return }
        reviewSuggestions = []
        reviewRevision &+= 1
    }

    private func relocateSuggestions() {
        guard !reviewSuggestions.isEmpty else { return }
        let current = code
        let moved = reviewSuggestions.compactMap { CodeReviewPolicy.relocate($0, in: current) }
        if moved != reviewSuggestions { reviewSuggestions = moved }
    }

    static func judgeSummary(_ result: LeetCodeJudgeResult?) -> String {
        guard let result else { return "" }
        var lines = ["状态：\(result.status)"]
        if result.totalTestCases > 0 { lines.append("通过用例：\(result.totalCorrect)/\(result.totalTestCases)") }
        for (label, value) in [
            ("编译错误", result.compileError), ("运行错误", result.runtimeError),
            ("失败用例输入", result.input), ("实际输出", result.output), ("预期输出", result.expectedOutput)
        ] where !value.isEmpty {
            lines.append("\(label)：\(LeetCodeAssistantContext.clipped(value, limit: 600))")
        }
        return lines.joined(separator: "\n")
    }

    private func persistCurrentCode() {
        guard let slug = slug(of: documentID) else { return }
        let code = code, template = templateCode, language = language
        drafts.update { archive in
            LeetCodeDraftPolicy.record(code: code, template: template, slug: slug, language: language, in: &archive)
        }
    }

    /// 一键恢复力扣初始代码。不弹确认框：浮层上有「撤销」，编辑器里 ⌘Z 也能撤回
    /// （替换走的是可撤销的整篇替换，不是重载文档）。
    func resetToTemplate() {
        guard !documentID.isEmpty, !isPristine else { return }
        discardedCode = (documentID, code)
        code = templateCode
        persistCurrentCode()
        resetNoticeVersion &+= 1
    }

    func undoReset() {
        guard let discarded = discardedCode, discarded.documentID == documentID else { return }
        code = discarded.code
        discardedCode = nil
        persistCurrentCode()
    }

    func dismissResetNotice() {
        discardedCode = nil
    }

    private func slug(of documentID: String) -> String? {
        guard let separator = documentID.lastIndex(of: "|") else { return nil }
        let slug = String(documentID[..<separator])
        return slug.isEmpty ? nil : slug
    }

    // MARK: - 测试用例

    func testCases(for slug: String, official: [String]) -> [String] {
        editableTestCasesBySlug[slug] ?? LeetCodeTestCaseWorkspace.editableCases(from: official)
    }

    func selectedTestCaseIndex(for slug: String, caseCount: Int) -> Int {
        LeetCodeTestCaseWorkspace.clampedIndex(selectedTestCaseIndexBySlug[slug] ?? 0, caseCount: caseCount)
    }

    func updateTestCase(_ value: String, at index: Int, slug: String, official: [String]) {
        var cases = testCases(for: slug, official: official)
        let safeIndex = LeetCodeTestCaseWorkspace.clampedIndex(index, caseCount: cases.count)
        cases[safeIndex] = value
        editableTestCasesBySlug[slug] = cases
        let officialCases = LeetCodeTestCaseWorkspace.editableCases(from: official)
        drafts.update { archive in
            var question = archive.questions[slug] ?? LeetCodeQuestionDraft(updatedAt: .now)
            let next = cases == officialCases ? nil : cases
            guard question.testCases != next else { return false }
            question.testCases = next
            question.updatedAt = .now
            LeetCodeDraftPolicy.store(question, slug: slug, in: &archive)
            return true
        }
    }

    func restoreOfficialTestCases(slug: String, official: [String]) {
        editableTestCasesBySlug[slug] = LeetCodeTestCaseWorkspace.editableCases(from: official)
        selectedTestCaseIndexBySlug[slug] = 0
        drafts.update { archive in
            guard var question = archive.questions[slug], question.testCases != nil else { return false }
            question.testCases = nil
            question.updatedAt = .now
            LeetCodeDraftPolicy.store(question, slug: slug, in: &archive)
            return true
        }
    }

    // MARK: - 判题

    func judgeState(for slug: String?) -> (action: LeetCodeJudgeAction?, progress: LeetCodeJudgeProgress?, result: LeetCodeJudgeResult?, error: String?) {
        guard let slug, slug == judgeSlug else { return (nil, nil, nil, nil) }
        return (judgeAction, judgeProgress, judgeResult, judgeError)
    }

    /// 判题挂在会话上而不是页面上：提交后切去问 AI，结果回来照样落在这里。
    func judge(
        _ action: LeetCodeJudgeAction,
        question: LeetCodeQuestion,
        workspace: LeetCodeQuestionWorkspace,
        dataStore: LegacyDataStore
    ) async {
        guard judgeAction == nil else {
            judgeError = "当前判题仍在进行，请等待本次结果返回"
            return
        }
        guard !workspace.questionID.isEmpty else {
            judgeSlug = question.titleSlug
            judgeError = "题目评测信息未加载完整，请重新加载题目"
            return
        }
        let slug = question.titleSlug
        let cases = testCases(for: slug, official: workspace.sampleTestCases)
        let testCase = cases[selectedTestCaseIndex(for: slug, caseCount: cases.count)]
        let code = code, language = language
        judgeSlug = slug
        judgeAction = action
        judgeProgress = nil
        judgeResult = nil
        judgeError = nil
        defer { judgeAction = nil }
        do {
            let result: LeetCodeJudgeResult
            switch action {
            case .run:
                result = try await LeetCodeAPIClient.shared.runCode(
                    titleSlug: slug,
                    questionID: workspace.questionID,
                    language: language,
                    code: code,
                    testCase: testCase
                ) { [weak self] progress in
                    guard self?.judgeSlug == slug else { return }
                    self?.judgeProgress = progress
                }
            case .submit:
                result = try await LeetCodeAPIClient.shared.submitCode(
                    titleSlug: slug,
                    questionID: workspace.questionID,
                    language: language,
                    code: code
                ) { [weak self] progress in
                    guard self?.judgeSlug == slug else { return }
                    self?.judgeProgress = progress
                }
            }
            judgeResult = result
            // 没通过就自动把问题标到代码上（设置里可以关）。
            if !result.accepted, autoReviewOnFailure, selectedQuestionSlug == slug {
                requestReview(.judgeFailure, question: question, workspace: workspace, dataStore: dataStore)
            }
            if action == .submit {
                _ = try await dataStore.refreshLeetCodeQuestionHistory(
                    slug,
                    expectedSubmissionID: result.taskID,
                    onDemand: false
                )
                if selectedQuestionSlug == slug { selectedSubmissionID = result.taskID }
                _ = try? await dataStore.fetchLeetCodeSubmissionDetail(result.taskID)
            }
        } catch {
            judgeError = error.localizedDescription
        }
    }

    // MARK: - AI

    func assistantConversationID(for slug: String, existing: Set<String>) -> String? {
        guard let id = drafts.archive.questions[slug]?.assistantConversationID else { return nil }
        // 会话在对话页被删掉了，指向就作废；下一次提问会新开一个。
        return existing.contains(id) ? id : nil
    }

    func setAssistantConversationID(_ id: String?, for slug: String) {
        drafts.update { archive in
            var question = archive.questions[slug] ?? LeetCodeQuestionDraft(updatedAt: .now)
            guard question.assistantConversationID != id else { return false }
            question.assistantConversationID = id
            question.updatedAt = .now
            LeetCodeDraftPolicy.store(question, slug: slug, in: &archive)
            return true
        }
        // 开新会话不必等防抖：它指向的会话已经写进 conversations.json 了。
        drafts.flush()
    }

    func requestHint(
        question: LeetCodeQuestion?,
        workspace: LeetCodeQuestionWorkspace,
        dataStore: LegacyDataStore
    ) async {
        guard !isHinting else { return }
        // 换题了就从头来，别把上一题的提示接着往下发。
        if hintSlug != workspace.titleSlug {
            hintSlug = workspace.titleSlug
            hints = []
        }
        guard hints.count < 3 else { return }
        isHinting = true
        hintError = ""
        defer { isHinting = false }
        do {
            let hint = try await ChatService(dataDirectory: dataStore.dataDirectory).requestCodingHint(
                title: question?.title ?? workspace.titleSlug,
                content: LeetCodeQuestionActionBar.plainText(workspace.htmlContent),
                code: code,
                language: language,
                level: hints.count + 1,
                previousHints: hints.map(\.hint),
                providerID: AITaskRoute.codingHint.providerID(in: dataStore.settings)
            )
            guard hintSlug == workspace.titleSlug else { return }
            hints.append(hint)
        } catch {
            hintError = error.localizedDescription
        }
    }

    func restartHints() {
        hints = []
        hintError = ""
    }

    func hints(for slug: String?) -> [CodingHint] {
        slug == hintSlug ? hints : []
    }
}

// MARK: - 问 AI 的上下文

/// 在刷题页问 AI 时，每次发送前现拼的一段 system 上下文。
///
/// 不写进用户消息：否则对话记录里每条提问都拖着一整份代码，
/// 在对话页翻看时全是噪音；而且代码是**发送那一刻**的，写进历史就过期了。
enum LeetCodeAssistantContext {
    static let statementLimit = 3_000
    static let codeLimit = 12_000
    static let ioLimit = 1_200

    struct Input {
        var frontendID: String
        var title: String
        var difficulty: String
        var statement: String
        var language: String
        var code: String?
        var isPristine: Bool
        var selection: LeetCodeEditorSelection?
        var judgeResult: LeetCodeJudgeResult?
        var diagnostics: [LeetCodeEditorIssue]
    }

    static func prompt(_ input: Input) -> String {
        var sections: [String] = []
        sections.append("""
        用户正在刷题页写「\(input.frontendID). \(input.title)」\(input.difficulty.isEmpty ? "" : "（\(input.difficulty)）")，\
        下面是他此刻的题面、代码与评测状态，由应用自动附带，不是用户说的话。
        回答规则：先针对他自己的代码说问题出在哪、为什么；除非他明确要完整解法，否则给改动方向和关键片段，\
        不要直接贴出整份 AC 代码。引用代码时标注行号。
        \(LeetCodeJudgeEnvironment.promptNote(language: input.language))
        """)

        let statement = clipped(input.statement, limit: statementLimit)
        if !statement.isEmpty {
            sections.append("## 题面\n\(statement)")
        }

        if let code = input.code {
            let body = clipped(numbered(code), limit: codeLimit)
            let state = input.isPristine ? "（还是力扣初始模板，尚未动笔）" : ""
            sections.append("## 当前代码 · \(input.language)\(state)\n```\(input.language)\n\(body)\n```")
        }

        if let selection = input.selection, !selection.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            sections.append("## 用户选中的代码（\(selection.lineCaption)）\n```\n\(clipped(selection.text, limit: 2_000))\n```\n用户的问题很可能就是指这几行。")
        }

        if !input.diagnostics.isEmpty {
            let lines = input.diagnostics.prefix(6).map { "- 第 \($0.line) 行：\($0.message)" }
            sections.append("## 编辑器语法检查\n" + lines.joined(separator: "\n"))
        }

        if let result = input.judgeResult {
            var lines = ["- 类型：\(result.kind == "submit" ? "提交" : "运行")", "- 状态：\(result.status)"]
            if result.totalTestCases > 0 { lines.append("- 通过用例：\(result.totalCorrect)/\(result.totalTestCases)") }
            for (label, value) in [
                ("编译错误", result.compileError),
                ("运行错误", result.runtimeError),
                ("失败用例输入", result.input),
                ("实际输出", result.output),
                ("预期输出", result.expectedOutput)
            ] where !value.isEmpty {
                lines.append("- \(label)：\(clipped(value, limit: ioLimit))")
            }
            sections.append("## 最近一次评测\n" + lines.joined(separator: "\n"))
        }
        return sections.joined(separator: "\n\n")
    }

    static func numbered(_ code: String) -> String {
        code.split(separator: "\n", omittingEmptySubsequences: false)
            .enumerated()
            .map { "\($0.offset + 1)| \($0.element)" }
            .joined(separator: "\n")
    }

    static func clipped(_ value: String, limit: Int) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > limit else { return trimmed }
        return String(trimmed.prefix(limit)) + "\n……（已截断，共 \(trimmed.count) 字）"
    }
}
