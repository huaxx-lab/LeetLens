import Foundation
import Observation
import CryptoKit

enum LeetCodeSubmissionFingerprint {
    static func make(_ submissions: [LeetCodeRemoteSubmission]) -> String {
        let payload = submissions
            .sorted { $0.id.localizedStandardCompare($1.id) == .orderedAscending }
            .map { item in
                [item.id, item.status, item.language, String(item.timestamp), item.runtime, item.memory].joined(separator: "\u{0}")
            }
            .joined(separator: "\u{1}")
        return SHA256.hash(data: Data(payload.utf8)).map { String(format: "%02x", $0) }.joined().prefix(24).description
    }

    static func analysisCandidateIDs(
        incoming: [LeetCodeRemoteSubmission],
        knownIDs: Set<String>,
        analyzedIDs: Set<String>,
        previousFingerprint: String?,
        expectedSubmissionID: String?,
        onDemand: Bool
    ) -> [String] {
        if let expectedSubmissionID {
            return incoming.contains(where: { $0.id == expectedSubmissionID }) && !analyzedIDs.contains(expectedSubmissionID)
                ? [expectedSubmissionID]
                : []
        }
        let unseen = incoming.map(\.id).filter { !knownIDs.contains($0) && !analyzedIDs.contains($0) }
        guard onDemand else { return unseen }
        guard let previousFingerprint, previousFingerprint != make(incoming) else { return [] }
        return unseen
    }
}

enum LeetCodeAnalysisRetryBudget {
    static let taskAttempts = 12
    static let submissionAttempts = 6

    static func recordFailures(_ ids: [String], current: [String: Int]) -> [String: Int] {
        var result = current
        for id in Set(ids) {
            result[id] = min(submissionAttempts, (result[id] ?? 0) + 1)
        }
        return result
    }

    static func eligible(_ ids: [String], failures: [String: Int]) -> [String] {
        ids.filter { (failures[$0] ?? 0) < submissionAttempts }
    }
}

struct ConversationSummary: Identifiable, Hashable, Sendable {
    let id: String
    let title: String
    let summary: String
    let updatedAt: Date
    let messageCount: Int
    let messages: [ConversationTranscriptMessage]
    var aiTitle = ""
    var aiSummary = ""
    var contextSummary = ""
    /// 生成 `contextSummary` 时对话有多少条消息。摘要要滚动重写而不是只写一次，
    /// 否则长对话被压缩掉的早期消息既不在上下文里、也不在摘要里，等于永久丢失。
    var archivedMessageCount = 0
    var usage = ConversationUsage()
    var lastChatUsage = ConversationUsage()
    var isPinned = false

    var revision: ConversationRevision {
        ConversationRevision(
            updatedAtMilliseconds: Int64((updatedAt.timeIntervalSince1970 * 1_000).rounded()),
            messageCount: messageCount
        )
    }
}

struct ConversationTranscriptMessage: Identifiable, Hashable, Sendable {
    let id: String
    let role: String
    let content: String
    let createdAt: Date
    var artifacts: [ConversationArtifact] = []
    var toolCalls: [String] = []
    var providerID = ""
    var model = ""
}

struct ConversationArtifact: Hashable, Sendable {
    let type: String
    let url: String
    let title: String
}

struct ConversationUsage: Hashable, Sendable {
    var promptTokens = 0
    var completionTokens = 0
    var totalTokens = 0
    var cachedTokens = 0
    var cacheCreationTokens = 0
    var reasoningTokens = 0
    var textTokens = 0
    var toolCalls = 0
    var toolUsage: [String: Int] = [:]
    var exactRequests = 0
    var estimatedRequests = 0
    var cacheTrackedPromptTokens = 0
    var cacheSupported = false
    /// Presence markers from provider packets. A zero value can still be exact; conversely,
    /// a cache/tool-only `usage` object is not a complete token accounting response.
    var hasReportedPromptTokens = false
    var hasReportedCompletionTokens = false
    var hasReportedTotalTokens = false
    var model = ""

    static func + (lhs: Self, rhs: Self) -> Self {
        var tools = lhs.toolUsage
        rhs.toolUsage.forEach { tools[$0.key, default: 0] += $0.value }
        return ConversationUsage(
            promptTokens: lhs.promptTokens + rhs.promptTokens,
            completionTokens: lhs.completionTokens + rhs.completionTokens,
            totalTokens: lhs.totalTokens + rhs.totalTokens,
            cachedTokens: lhs.cachedTokens + rhs.cachedTokens,
            cacheCreationTokens: lhs.cacheCreationTokens + rhs.cacheCreationTokens,
            reasoningTokens: lhs.reasoningTokens + rhs.reasoningTokens,
            textTokens: lhs.textTokens + rhs.textTokens,
            toolCalls: lhs.toolCalls + rhs.toolCalls,
            toolUsage: tools,
            exactRequests: lhs.exactRequests + rhs.exactRequests,
            estimatedRequests: lhs.estimatedRequests + rhs.estimatedRequests,
            cacheTrackedPromptTokens: lhs.cacheTrackedPromptTokens + rhs.cacheTrackedPromptTokens,
            cacheSupported: lhs.cacheSupported || rhs.cacheSupported,
            hasReportedPromptTokens: lhs.hasReportedPromptTokens || rhs.hasReportedPromptTokens,
            hasReportedCompletionTokens: lhs.hasReportedCompletionTokens || rhs.hasReportedCompletionTokens,
            hasReportedTotalTokens: lhs.hasReportedTotalTokens || rhs.hasReportedTotalTokens,
            model: rhs.model.isEmpty ? lhs.model : rhs.model
        )
    }
}

struct LearningRecord: Identifiable, Hashable {
    let id: String
    let kind: String
    /// 形如 `leetcode:two-sum`，学习项与力扣题目的唯一关联点。
    let canonicalKey: String
    let title: String
    let question: String
    let diagnosis: String
    let labels: [String]
    let prerequisiteLabels: [String]
    let knowledgePath: [String]
    let masteryScore: Double
    let confidence: Double
    let evidenceCount: Int
    let evidence: [LearningEvidence]
    let sourceRefs: [LearningSourceReference]
    let language: String
    let dueAt: Date
    let reviewCount: Int
    /// FSRS 的记忆稳定度（天）。0 = 还没有可用的曲线。
    var stability: Double = 0
    /// 上次复习时间。和 `stability` 一起才能算出「现在还记得多少」。
    var lastReviewedAt: Date?
    let activeStudyPackage: LearningStudyPackage?
    let latestAttempt: LearningAttempt?
    let activePackageAttemptCount: Int
    let updatedAt: Date

    var primaryKnowledge: String {
        knowledgePath.last ?? labels.first ?? "未分类"
    }

    var isDue: Bool { dueAt <= .now }

    /// 现在还能想起来的概率。没复习过（没有曲线）时是 nil。
    func retention(at reference: Date = .now) -> Double? {
        guard let lastReviewedAt else { return nil }
        return ForgettingCurve.retention(
            stability: stability,
            elapsedDays: reference.timeIntervalSince(lastReviewedAt) / 86_400
        )
    }

    /// 掌握度按遗忘打折之后的「现在还剩多少」。界面上显示的就是这个数——
    /// 「三个月前学会过」不该和「昨天刚练过」显示成同一个百分比。
    func effectiveMastery(at reference: Date = .now) -> Double {
        ForgettingCurve.effectiveScore(masteryScore, retention: retention(at: reference))
    }

    /// 能取到 slug 才能拉真实题面；非力扣来源的知识点返回 nil。
    var leetCodeSlug: String? {
        guard canonicalKey.hasPrefix("leetcode:") else { return nil }
        let slug = String(canonicalKey.dropFirst("leetcode:".count))
        return slug.isEmpty ? nil : slug
    }
}

struct LearningSourceReference: Identifiable, Hashable {
    var id: String { "\(conversationID):\(messageID)" }
    let conversationID: String
    let messageID: String
    let excerpt: String
}

struct LearningTemplate: Identifiable, Hashable {
    let id: String
    let title: String
    let path: [String]
    let language: String
    let summary: String
    let applicableWhen: [String]
    let steps: [String]
    let pitfalls: [String]
    let code: String
    let itemCount: Int
    let generatedAt: Date
}

struct LearningEvidence: Identifiable, Hashable {
    let id: String
    /// learning.json 里的 `type`，`leetcode_submission` 表示这条证据背后有一次真实提交。
    let kind: String
    /// 形如 `lc_726712771`，去掉前缀就是力扣提交 ID。
    let attemptID: String
    let signal: String
    let summary: String
    let observedAt: Date

    var leetCodeSubmissionID: String? {
        guard kind == "leetcode_submission", attemptID.hasPrefix("lc_") else { return nil }
        let id = String(attemptID.dropFirst(3))
        return id.isEmpty ? nil : id
    }
}

struct ProviderRecord: Identifiable, Hashable {
    let id: String
    let name: String
    let assetName: String?
    let model: String
    let apiBase: String
    let mode: String
    let isConfigured: Bool
}

struct LeetCodePlanSummary: Identifiable, Hashable {
    let id: String
    let name: String
    let questionCount: Int
    let solvedCount: Int
}

struct LeetCodeQuestion: Identifiable, Hashable {
    var id: String { titleSlug }
    let titleSlug: String
    let frontendID: String
    let title: String
    let difficulty: String
    let status: String
    let paidOnly: Bool
    let acceptanceRate: Double?
    let groupName: String
    let topicTags: [String]
    let submissionCount: Int
    let acceptedCount: Int
    let lastSubmittedAt: Date?
}

struct LeetCodeCodeSnippet: Identifiable, Hashable {
    var id: String { languageSlug }
    let language: String
    let languageSlug: String
    let code: String
}

struct LeetCodeQuestionWorkspace: Hashable {
    let titleSlug: String
    let questionID: String
    let htmlContent: String
    let difficulty: String
    let topicTags: [String]
    let sampleTestCases: [String]
    let snippets: [LeetCodeCodeSnippet]
    let canRun: Bool
    let canSubmit: Bool
}

struct LeetCodeAttemptInsight: Hashable {
    let submissionID: String
    let issue: String
    let change: String
    let outcome: String
}

struct LeetCodeSubmissionAnalysis: Hashable {
    let summary: String
    let rootCause: String
    let evidence: [String]
    let suggestions: [String]
    let knowledgeGaps: [String]
    let updatedAt: Date
}

struct LeetCodeTrajectoryAnalysis: Hashable {
    let titleSlug: String
    let summary: String
    let weaknesses: [String]
    let improvements: [String]
    let attemptInsights: [LeetCodeAttemptInsight]
    let submissionAnalyses: [String: LeetCodeSubmissionAnalysis]
    let analyzedSubmissionIDs: [String]
    let latestSubmissionAt: Date
    let updatedAt: Date
}

struct LeetCodeAnalysisTask: Hashable {
    let titleSlug: String
    let submissionIDs: [String]
    let queuedAt: Date
    let attempts: Int
    let nextAttemptAt: Date
    let lastAttemptAt: Date
    let lastError: String
    let failedSubmissionAttempts: [String: Int]

    var isReady: Bool { attempts < LeetCodeAnalysisRetryBudget.taskAttempts && nextAttemptAt <= .now }
    var eligibleSubmissionIDs: [String] {
        LeetCodeAnalysisRetryBudget.eligible(submissionIDs, failures: failedSubmissionAttempts)
    }
}

struct LeetCodeSubmissionDetail: Hashable {
    let id: String
    let titleSlug: String
    let code: String
    let language: String
    let status: String
    let runtime: String
    let memory: String
    let runtimePercentile: Double?
    let memoryPercentile: Double?
    let runtimeError: String
    let compileError: String
    let lastTestCase: String
    let actualOutput: String
    let expectedOutput: String
    let correctCaseCount: Int
    let totalCaseCount: Int
}

struct LeetCodeProfile: Hashable {
    let username: String
    let displayName: String
    let avatarURL: URL?
    let avatarData: Data?
    let isPremium: Bool

    static let empty = LeetCodeProfile(
        username: "",
        displayName: "",
        avatarURL: nil,
        avatarData: nil,
        isPremium: false
    )
}

struct LeetCodeSubmission: Identifiable, Hashable {
    let id: String
    let titleSlug: String
    let title: String
    let frontendID: String
    let language: String
    let accepted: Bool
    let submittedAt: Date
    let activityType: String
    let status: String
    let runtime: String
    let memory: String
    let url: String
}

struct LeetCodeActivityDay: Identifiable, Hashable {
    var id: Date { date }
    let date: Date
    let submissionCount: Int
    let acceptedCount: Int
}

struct VideoHistoryEntry: Identifiable, Hashable {
    var id: String { bvid }
    let bvid: String
    let title: String
    let coverURL: URL?
    let progress: Double
    let duration: Double
    let lastOpenedAt: Date
    let openCount: Int

    var playbackURL: URL? { URL(string: "https://www.bilibili.com/video/\(bvid)") }
}

enum BilibiliVideoURLPolicy {
    static func bvid(from url: URL) -> String? {
        guard url.host?.lowercased().hasSuffix("bilibili.com") == true else { return nil }
        let components = url.pathComponents
        guard let videoIndex = components.firstIndex(where: { $0.lowercased() == "video" }),
              components.indices.contains(videoIndex + 1)
        else { return nil }
        let value = components[videoIndex + 1]
        guard value.range(of: #"^BV[0-9A-Za-z]+$"#, options: .regularExpression) != nil else { return nil }
        return value
    }
}

struct LegacySettingsSnapshot {
    var activeProviderID = "deepseek"
    var reasoningEffort = "high"
    var alwaysOnTop = false
    var videoAutoplay = true
    var appearance = "system"
    var emphasizeMotion = true
    var contextWindowTokens = 128_000.0
    var reservedOutputTokens = 8_192.0
    var compressionThreshold = 0.95
    var postCompressionRatio = 0.82
    var recentMessages = 12.0
    var maxImages = 4.0
    var taskRoutes: [String: String] = [:]
}

struct LearningSettingsSnapshot: Hashable, Sendable {
    var dailyNewTarget = 3
    var weekdayReviewTarget = 4
    /// 0 = 周日，与 learning-engine.cjs 的 `weeklyReviewDay` 同一口径。
    var weeklyReviewDay = 0
    var weeklyReviewTarget = 12
    var preferredLanguage = "java"
}

/// Lifecycle of the cross-conversation RAG index.
///
/// The index is deliberately *not* a precondition for the first window. Callers that
/// need retrieval accuracy await `waitForMemoryIndex()` instead, so a stale index is
/// never used silently.
enum MemoryIndexState: Equatable, Sendable {
    case cold
    case syncing
    case ready
}

@MainActor
@Observable
final class LegacyDataStore {
    @ObservationIgnored let conversationMemoryIndex: ConversationMemoryIndex
    @ObservationIgnored private let layeredVectorStore: LayeredVectorStore
    @ObservationIgnored private let learningBridge: LearningEngineBridge
    @ObservationIgnored private var isSyncingLeetCodeAccount = false
    @ObservationIgnored private var memoryIndexTask: Task<Void, Never>?
    @ObservationIgnored private var memoryIndexGeneration = 0
    private(set) var memoryIndexState = MemoryIndexState.cold
    private(set) var isDataReady = false
    /// Bumped whenever the active learning set changes. Results derived from an older
    /// revision must be discarded rather than written over the newer state.
    private(set) var activeLearningRevision = 0
    private(set) var conversations: [ConversationSummary] = []
    private(set) var learningRecords: [LearningRecord] = []
    private(set) var deletedLearningRecords: [LearningRecord] = []
    private(set) var learningTemplates: [LearningTemplate] = []
    private(set) var studyPlanTasks: [StudyPlanTask] = []
    private(set) var providers: [ProviderRecord] = []
    private(set) var leetCodePlans: [LeetCodePlanSummary] = []
    private(set) var activeLeetCodePlanID = ""
    private(set) var leetCodeQuestions: [LeetCodeQuestion] = []
    private(set) var leetCodeProfile = LeetCodeProfile.empty
    private(set) var leetCodeSubmissions: [LeetCodeSubmission] = []
    private(set) var leetCodeActivity: [LeetCodeActivityDay] = []
    private(set) var videoHistory: [VideoHistoryEntry] = []
    private(set) var leetCodeWorkspaces: [String: LeetCodeQuestionWorkspace] = [:]
    private(set) var leetCodeSubmissionDetails: [String: LeetCodeSubmissionDetail] = [:]
    private(set) var leetCodeAnalysisTasks: [String: LeetCodeAnalysisTask] = [:]
    private(set) var leetCodeAnalyses: [String: LeetCodeTrajectoryAnalysis] = [:]
    private(set) var leetCodeAnalysisProcessingSlug: String?
    private(set) var settings = LegacySettingsSnapshot()
    private(set) var learningSettings = LearningSettingsSnapshot()
    private(set) var leetCodeUsername = ""
    private(set) var leetCodeSignedIn = false
    private(set) var bilibiliSignedIn = false
    private(set) var bilibiliUserID = ""
    private(set) var bilibiliName = ""
    private(set) var bilibiliAvatarURL: URL?
    private(set) var lastReloadedAt = Date.distantPast

    let dataDirectory: URL

    /// Construction stays O(1). Loading is `hydrate()`, which the root view drives
    /// after the window is on screen — the previous `reload()` here put the entire
    /// JSON decode and RAG embedding pass in front of the first frame.
    init(dataDirectory: URL? = nil) {
        let resolvedDirectory = dataDirectory ?? Self.defaultDataDirectory
        self.dataDirectory = resolvedDirectory
        learningBridge = LearningEngineBridge(dataDirectory: resolvedDirectory)
        let layered = LayeredVectorStore(
            local: LocalVectorStore(dataDirectory: resolvedDirectory),
            durable: PostgresVectorStore.shared
        )
        layeredVectorStore = layered
        conversationMemoryIndex = ConversationMemoryIndex(vectorStore: layered)
    }

    /// Performs the initial load exactly once. Safe to call from every `.task`.
    func hydrate() async {
        ensureLoaded()
    }

    /// Guarantees the in-memory snapshot reflects disk before a read-modify-write.
    ///
    /// Loading is lazy now, so any mutation that serialises an in-memory collection
    /// must first make sure that collection is not simply empty-because-unloaded —
    /// otherwise it would write an empty file over real user data.
    private func ensureLoaded() {
        guard !isDataReady else { return }
        reload()
        isDataReady = true
    }

    /// Awaits the in-flight index rebuild, if any. Retrieval callers use this so an
    /// AI request never runs against a half-built index.
    func waitForMemoryIndex() async {
        while let task = memoryIndexTask {
            let generation = memoryIndexGeneration
            await task.value
            // A rebuild scheduled while we were waiting bumps the generation; loop
            // until the index has actually settled.
            if memoryIndexGeneration == generation { break }
        }
    }

    /// Searches cross-conversation memory, bringing the index current first.
    func searchMemory(
        query: String,
        currentConversationID: String,
        limit: Int = 4
    ) async -> [ConversationMemoryMatch] {
        await waitForMemoryIndex()
        return await conversationMemoryIndex.search(
            query: query,
            currentConversationID: currentConversationID,
            limit: limit
        )
    }

    /// Rebuilds the conversation index off the main actor. Supersedes any in-flight
    /// rebuild so rapid edits collapse into one pass instead of queueing.
    private func scheduleMemoryIndexSync() {
        memoryIndexTask?.cancel()
        memoryIndexGeneration += 1
        memoryIndexState = .syncing
        let snapshot = conversations
        let index = conversationMemoryIndex
        let vectorStore = layeredVectorStore
        memoryIndexTask = Task { [weak self] in
            await index.synchronize(conversations: snapshot)
            guard !Task.isCancelled else { return }
            // Reclaim vectors no document references any more, in both tiers. Only safe
            // after a *complete* pass: a cancelled sync has a partial live set, and
            // retaining against that would throw away vectors still in use.
            await vectorStore.retain(keys: await index.liveVectorKeys())
            await MainActor.run { self?.memoryIndexState = .ready }
        }
    }

    var activeLearningRecords: [LearningRecord] {
        learningRecords.sorted {
            if $0.isDue != $1.isDue { return $0.isDue }
            let left = $0.effectiveMastery(), right = $1.effectiveMastery()
            if left != right { return left < right }
            return $0.updatedAt > $1.updatedAt
        }
    }

    var dueCount: Int { learningRecords.lazy.filter(\.isDue).count }
    var weakCount: Int { learningRecords.lazy.filter { $0.effectiveMastery() < 45 }.count }
    var acceptedSubmissionCount: Int { leetCodeSubmissions.lazy.filter(\.accepted).count }
    var solvedProblemCount: Int {
        Set(leetCodeSubmissions.lazy.filter(\.accepted).map(\.titleSlug)).count
    }
    var activeLeetCodeDays: Int { leetCodeActivity.count }
    var videoHistoryCount: Int { videoHistory.count }
    var currentLeetCodeStreak: Int {
        guard let latest = leetCodeActivity.last?.date else { return 0 }
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: .now)
        guard calendar.dateComponents([.day], from: latest, to: today).day.map({ $0 <= 1 }) == true else { return 0 }
        let activeDates = Set(leetCodeActivity.map(\.date))
        var cursor = latest
        var streak = 0
        while activeDates.contains(cursor) {
            streak += 1
            guard let prior = calendar.date(byAdding: .day, value: -1, to: cursor) else { break }
            cursor = prior
        }
        return streak
    }

    func selectLeetCodePlan(_ planID: String) throws {
        guard leetCodePlans.contains(where: { $0.id == planID }),
              var root = jsonObject(named: "leetcode-cn.json") as? [String: Any]
        else { return }
        root["activePlanSlug"] = planID
        try writeJSONObject(root, named: "leetcode-cn.json")
        reload()
    }

    @discardableResult
    func fetchLeetCodeWorkspace(_ titleSlug: String) async throws -> LeetCodeQuestionWorkspace {
        let value = try await LeetCodeAPIClient.shared.fetchWorkspace(titleSlug: titleSlug)
        var root = (jsonObject(named: "leetcode-content.json") as? [String: Any]) ?? [:]
        var workspaces = root["workspaces"] as? [String: Any] ?? [:]
        workspaces[titleSlug] = [
            "value": value,
            "loadedAt": Date.now.timeIntervalSince1970 * 1_000
        ]
        root["schemaVersion"] = 1
        root["workspaces"] = workspaces
        try writeJSONObject(root, named: "leetcode-content.json")
        loadLeetCodeContent()
        guard let workspace = leetCodeWorkspaces[titleSlug] else {
            throw LeetCodeAPIError.invalidResponse("题目已经返回，但无法建立作答区")
        }
        return workspace
    }

    @discardableResult
    /// Read-through submission detail.
    ///
    /// Order is local file → Redis → GraphQL. The analysis worker used to skip both
    /// caches and re-request every submission in every batch, which is the main source
    /// of avoidable LeetCode traffic (and of rate limiting). A short `SET NX` lock
    /// coalesces concurrent requests for the same submission, matching the Electron
    /// client's promise coalescing.
    func fetchLeetCodeSubmissionDetail(
        _ submissionID: String,
        allowCached: Bool = true
    ) async throws -> LeetCodeSubmissionDetail {
        guard let submission = leetCodeSubmissions.first(where: { $0.id == submissionID }) else {
            throw LeetCodeAPIError.invalidResponse("本地没有这条提交记录，请先同步提交历史")
        }
        if allowCached, let cached = leetCodeSubmissionDetails[submissionID] {
            return cached
        }
        if allowCached, let cached = await Self.cachedRemoteDetail(submissionID: submissionID) {
            storeSubmissionDetail(cached, submissionID: submissionID)
            if let value = leetCodeSubmissionDetails[submissionID] { return value }
        }

        // Coalesce concurrent fetches for the same submission across both clients.
        let lockKey = LeetCodeAnalysisFingerprint.detailLockKey(submissionID: submissionID)
        let holdsLock = await RedisClient.shared.acquireLock(lockKey, ttl: 30)
        if !holdsLock, let shared = await Self.awaitSharedDetail(submissionID: submissionID) {
            storeSubmissionDetail(shared, submissionID: submissionID)
            if let value = leetCodeSubmissionDetails[submissionID] { return value }
        }
        defer {
            if holdsLock {
                Task { await RedisClient.shared.releaseLock(lockKey) }
            }
        }

        let detail = try await LeetCodeAPIClient.shared.fetchSubmissionDetail(submission)
        storeSubmissionDetail(detail, submissionID: submissionID)
        guard let value = leetCodeSubmissionDetails[submissionID] else {
            throw LeetCodeAPIError.invalidResponse("提交详情已经返回，但无法读取缓存")
        }
        await Self.cacheRemoteDetail(detail, submissionID: submissionID)
        return value
    }

    /// Persists one detail into the local content file and refreshes the in-memory map.
    private func storeSubmissionDetail(_ detail: [String: Any], submissionID: String) {
        var root = (jsonObject(named: "leetcode-content.json") as? [String: Any]) ?? [:]
        var details = root["submissionDetails"] as? [String: Any] ?? [:]
        details[submissionID] = [
            "detail": detail,
            "loadedAt": Date.now.timeIntervalSince1970 * 1_000,
            "performanceChecked": true
        ]
        root["schemaVersion"] = 1
        root["submissionDetails"] = details
        try? writeJSONObject(root, named: "leetcode-content.json")
        loadLeetCodeContent()
    }

    /// Reads a detail payload another client already fetched.
    private static func cachedRemoteDetail(submissionID: String) async -> [String: Any]? {
        let client = RedisClient.shared
        let key = LeetCodeAnalysisFingerprint.detailKey(submissionID: submissionID)
        guard let data = await client.get(key),
              let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return value
    }

    private static func cacheRemoteDetail(_ detail: [String: Any], submissionID: String) async {
        let client = RedisClient.shared
        guard let data = try? JSONSerialization.data(withJSONObject: detail)
        else { return }
        await client.setValue(
            data,
            for: LeetCodeAnalysisFingerprint.detailKey(submissionID: submissionID),
            ttl: 60 * 60 * 24 * 30
        )
    }

    /// Briefly waits for whoever holds the lock to publish the detail.
    private static func awaitSharedDetail(submissionID: String) async -> [String: Any]? {
        for _ in 0..<10 {
            if let value = await cachedRemoteDetail(submissionID: submissionID) { return value }
            try? await Task.sleep(for: .milliseconds(300))
        }
        return nil
    }

    @discardableResult
    func refreshLeetCodeQuestionHistory(
        _ titleSlug: String,
        expectedSubmissionID: String? = nil,
        onDemand: Bool = true
    ) async throws -> [LeetCodeSubmission] {
        var remote: [LeetCodeRemoteSubmission] = []
        for attempt in 0..<5 {
            remote = try await LeetCodeAPIClient.shared.fetchSubmissions(titleSlug: titleSlug, limit: onDemand ? 100 : 20)
            if expectedSubmissionID == nil || remote.contains(where: { $0.id == expectedSubmissionID }) { break }
            try await Task.sleep(for: .milliseconds(350 + attempt * 250))
        }
        // 合并前先记下已知提交：自动完成只认这次新到的 AC。
        // 打开题目也会走这里（onDemand，拉 100 条历史），拿全量去勾会把
        // "再做一遍 xxx" 这类复习任务按历史成绩直接勾掉。
        let knownIDs = Set(leetCodeSubmissions.map(\.id))
        try mergeLeetCodeSubmissions(
            remote,
            titleSlug: titleSlug,
            expectedSubmissionID: expectedSubmissionID,
            onDemand: onDemand
        )
        try? await mergeLeetCodeSubmissionsIntoLearning()
        // 项目内提交也要立刻勾掉学习计划里的对应任务。以前只有账号级轮询会做这件事，
        // 于是在刷题页 AC 之后，计划里那条最多要等 10 分钟才变成已完成。
        autoCompleteStudyTasks(
            matchingTitles: Set(
                remote
                    .filter {
                        !knownIDs.contains($0.id)
                            && LeetCodeStatus.isAccepted(statusCode: 0, display: $0.status)
                    }
                    .map { Self.normalizedTitle($0.title) }
            )
        )
        reload()
        return leetCodeSubmissions.filter { $0.titleSlug == titleSlug }
    }

    func retryLeetCodeAnalysis(_ titleSlug: String) throws {
        guard var root = jsonObject(named: "leetcode-cn.json") as? [String: Any] else { return }
        var analysis = root["analysis"] as? [String: Any] ?? [:]
        var queue = analysis["queue"] as? [String: Any] ?? [:]
        guard var task = queue[titleSlug] as? [String: Any] else { return }
        task["attempts"] = 0
        task["nextAttemptAt"] = 0
        task["lastError"] = ""
        task["failedSubmissionAttempts"] = [:]
        queue[titleSlug] = task
        analysis["queue"] = queue
        root["analysis"] = analysis
        try writeJSONObject(root, named: "leetcode-cn.json")
        reload()
    }

    /// Processes one due trajectory task. Repeated calls form the background worker.
    @discardableResult
    func processNextLeetCodeAnalysis() async -> Bool {
        guard !Task.isCancelled else { return false }
        guard leetCodeAnalysisProcessingSlug == nil else { return false }
        guard let task = leetCodeAnalysisTasks.values
            .filter(\.isReady)
            .sorted(by: { $0.queuedAt < $1.queuedAt })
            .first
        else { return false }
        leetCodeAnalysisProcessingSlug = task.titleSlug
        defer { leetCodeAnalysisProcessingSlug = nil }

        let submissions = task.eligibleSubmissionIDs.compactMap { id in
            leetCodeSubmissions.first { $0.id == id }
        }
        .sorted { $0.submittedAt < $1.submittedAt }
        .prefix(8)
        guard !submissions.isEmpty else {
            try? removeLeetCodeAnalysisTask(task.titleSlug)
            return true
        }

        var details: [LeetCodeSubmissionDetail] = []
        var failedIDs: [String] = []
        for submission in submissions {
            do {
                details.append(try await fetchLeetCodeSubmissionDetail(submission.id))
            } catch let error where Self.isCancellation(error) {
                // Navigating away is not a failed analysis. Abandon the pass without
                // touching the queue so the task is retried untouched next time.
                return false
            } catch {
                failedIDs.append(submission.id)
            }
        }
        do {
            guard !details.isEmpty else {
                throw LeetCodeAPIError.invalidResponse("这一批提交详情暂时都无法读取")
            }
            // A partial failure re-queues the whole batch, so drop submissions whose
            // exact content was already analysed rather than paying for them again.
            var pending: [LeetCodeSubmissionDetail] = []
            for detail in details {
                if await Self.isAlreadyAnalyzed(detail, slug: task.titleSlug) { continue }
                pending.append(detail)
            }
            if pending.isEmpty {
                // Everything here is already covered. Retire the queue entry without a
                // model call, and without touching the stored analysis record.
                try retireAnalyzedSubmissions(task: task, processedIDs: details.map(\.id))
                reload()
                return true
            }
            let question = leetCodeQuestions.first { $0.titleSlug == task.titleSlug }
                ?? submissions.first.map {
                    LeetCodeQuestion(
                        titleSlug: task.titleSlug,
                        frontendID: $0.frontendID,
                        title: $0.title,
                        difficulty: "",
                        status: "TRIED",
                        paidOnly: false,
                        acceptanceRate: nil,
                        groupName: "",
                        topicTags: [],
                        submissionCount: submissions.count,
                        acceptedCount: submissions.lazy.filter(\.accepted).count,
                        lastSubmittedAt: submissions.last?.submittedAt
                    )
                }
            let payloads = details.map {
                LeetCodeTrajectoryPromptSubmission(
                    id: $0.id,
                    code: String($0.code.prefix(30_000)),
                    language: $0.language,
                    status: $0.status,
                    runtime: $0.runtime,
                    memory: $0.memory,
                    runtimeError: String($0.runtimeError.prefix(5_000)),
                    compileError: String($0.compileError.prefix(5_000)),
                    lastTestCase: String($0.lastTestCase.prefix(5_000)),
                    actualOutput: String($0.actualOutput.prefix(5_000)),
                    expectedOutput: String($0.expectedOutput.prefix(5_000)),
                    correctCaseCount: $0.correctCaseCount,
                    totalCaseCount: $0.totalCaseCount
                )
            }
            // Content fingerprint gate. Identical inputs plus an identical analyser and
            // prompt can only produce the same answer, so a hit skips the model call
            // entirely — this is the cache that actually saves money.
            let providerID = AITaskRoute.leetCodeAnalysis.providerID(in: settings)
            let resolvedProvider = providers.first { $0.id == (providerID ?? settings.activeProviderID) }
            let modelProfile = "\(resolvedProvider?.id ?? "")|\(resolvedProvider?.model ?? "")"
            let fingerprint = LeetCodeAnalysisFingerprint.analysisFingerprint(
                details: details,
                modelProfile: modelProfile
            )
            let draft: LeetCodeTrajectoryDraft
            if let cached = await Self.cachedAnalysis(slug: task.titleSlug, fingerprint: fingerprint) {
                draft = cached
            } else {
                draft = try await LeetCodeAnalysisService(dataDirectory: dataDirectory).analyzeTrajectory(
                    titleSlug: task.titleSlug,
                    title: question?.title ?? task.titleSlug,
                    topicTags: question?.topicTags ?? [],
                    previous: leetCodeAnalyses[task.titleSlug],
                    submissions: payloads,
                    providerID: providerID
                )
                await Self.cacheAnalysis(draft, slug: task.titleSlug, fingerprint: fingerprint)
            }
            await Self.markAnalyzed(details: details, slug: task.titleSlug, modelProfile: modelProfile)
            try persistLeetCodeAnalysisSuccess(task: task, details: details, failedIDs: failedIDs, draft: draft)
            try? await mergeLeetCodeAnalysisIntoLearning(task.titleSlug)
            reload()
        } catch let error where Self.isCancellation(error) {
            // Deliberately persists nothing: attempts, the failed-submission map, the
            // eligible IDs and the queue itself must be identical to before this pass.
            return false
        } catch {
            try? persistLeetCodeAnalysisFailure(task: task, failedIDs: failedIDs, error: error)
        }
        return true
    }

    /// Removes submissions from the queue that need no further analysis.
    ///
    /// Used when every detail in a batch already has a fingerprint marker. The existing
    /// analysis record is left untouched — there is nothing new to say about it.
    private func retireAnalyzedSubmissions(task: LeetCodeAnalysisTask, processedIDs: [String]) throws {
        guard var root = jsonObject(named: "leetcode-cn.json") as? [String: Any] else { return }
        var analysis = root["analysis"] as? [String: Any] ?? [:]
        var queue = analysis["queue"] as? [String: Any] ?? [:]
        guard var currentTask = queue[task.titleSlug] as? [String: Any] else { return }

        let remaining = currentTask.stringArray("submissionIds").filter { !processedIDs.contains($0) }
        if remaining.isEmpty {
            queue[task.titleSlug] = nil
        } else {
            currentTask["submissionIds"] = remaining
            currentTask["attempts"] = 0
            currentTask["nextAttemptAt"] = 0
            queue[task.titleSlug] = currentTask
        }
        analysis["queue"] = queue
        root["analysis"] = analysis
        try writeJSONObject(root, named: "leetcode-cn.json")
    }

    /// Returns a previously computed analysis for exactly these inputs, if one exists.
    private static func cachedAnalysis(slug: String, fingerprint: String) async -> LeetCodeTrajectoryDraft? {
        let client = RedisClient.shared
        let key = LeetCodeAnalysisFingerprint.analysisKey(slug: slug, fingerprint: fingerprint)
        guard let data = await client.get(key) else { return nil }
        return try? JSONDecoder().decode(LeetCodeTrajectoryDraft.self, from: data)
    }

    private static func cacheAnalysis(
        _ draft: LeetCodeTrajectoryDraft,
        slug: String,
        fingerprint: String
    ) async {
        let client = RedisClient.shared
        guard let data = try? JSONEncoder().encode(draft)
        else { return }
        await client.setValue(
            data,
            for: LeetCodeAnalysisFingerprint.analysisKey(slug: slug, fingerprint: fingerprint),
            ttl: 60 * 60 * 24 * 90
        )
    }

    /// Records per-submission content fingerprints so an unchanged submission is never
    /// re-sent, even when a partial failure re-queues its batch.
    private static func markAnalyzed(
        details: [LeetCodeSubmissionDetail],
        slug: String,
        modelProfile: String
    ) async {
        let client = RedisClient.shared
        for detail in details {
            let key = LeetCodeAnalysisFingerprint.analyzedKey(
                slug: slug,
                itemFingerprint: LeetCodeAnalysisFingerprint.itemFingerprint(detail)
            )
            await client.setValue(Data("1".utf8), for: key, ttl: 60 * 60 * 24 * 90)
        }
    }

    /// True when this exact submission content has already been analysed.
    private static func isAlreadyAnalyzed(_ detail: LeetCodeSubmissionDetail, slug: String) async -> Bool {
        let client = RedisClient.shared
        return await client.exists(LeetCodeAnalysisFingerprint.analyzedKey(
            slug: slug,
            itemFingerprint: LeetCodeAnalysisFingerprint.itemFingerprint(detail)
        ))
    }

    /// Distinguishes "the user walked away" from "the analysis failed".
    ///
    /// The worker lives on a view `.task`, so leaving the LeetCode page cancels it.
    /// Counting that as a failure burned the per-submission retry budget and, once every
    /// submission exceeded it, deleted the queued task outright — silently losing work
    /// the user never abandoned. URLSession reports cancellation as `URLError.cancelled`
    /// rather than `CancellationError`, so both spellings have to be recognised.
    nonisolated static func isCancellation(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        if let urlError = error as? URLError, urlError.code == .cancelled { return true }
        return false
    }

    private func mergeLeetCodeSubmissions(
        _ incoming: [LeetCodeRemoteSubmission],
        titleSlug: String,
        expectedSubmissionID: String?,
        onDemand: Bool
    ) throws {
        var root = (jsonObject(named: "leetcode-cn.json") as? [String: Any]) ?? [:]
        let existing = root["submissions"] as? [[String: Any]] ?? []
        var byID = Dictionary(uniqueKeysWithValues: existing.compactMap { value -> (String, [String: Any])? in
            let id = value.string("id")
            return id.isEmpty ? nil : (id, value)
        })
        let knownIDs = Set(byID.keys)
        var tracking = root["tracking"] as? [String: Any] ?? [:]
        var questionFingerprints = tracking["questionFingerprints"] as? [String: Any] ?? [:]
        let previousFingerprint = questionFingerprints[titleSlug] as? String
        let incomingFingerprint = LeetCodeSubmissionFingerprint.make(incoming)
        let plans = root["plans"] as? [String: Any] ?? [:]
        let question = plans.values.compactMap { ($0 as? [String: Any])?["questions"] as? [[String: Any]] }
            .flatMap { $0 }
            .first { $0.string("titleSlug") == titleSlug }
        var latest = existing
            .filter { $0.string("titleSlug") == titleSlug }
            .max { $0.double("submittedAt") < $1.double("submittedAt") }

        for item in incoming.sorted(by: { $0.timestamp < $1.timestamp }) {
            let milliseconds = item.timestamp > 100_000_000_000 ? item.timestamp : item.timestamp * 1_000
            let previous = byID[item.id]
            let activityType: String
            if let previous, !previous.string("activityType").isEmpty {
                activityType = previous.string("activityType")
            } else if onDemand {
                activityType = "historical"
            } else if latest == nil {
                activityType = question?.string("status") == "SOLVED" ? "review" : "new"
            } else if milliseconds - (latest?.double("submittedAt") ?? 0) >= 12 * 60 * 60 * 1_000 {
                activityType = "review"
            } else {
                activityType = "attempt"
            }
            let value: [String: Any] = [
                "id": item.id,
                "titleSlug": titleSlug,
                "frontendId": question?.string("frontendId", fallback: question?.string("questionFrontendId") ?? "") ?? "",
                "title": question?.string("title", fallback: item.title) ?? item.title,
                "translatedTitle": question?.string("translatedTitle", fallback: item.title) ?? item.title,
                "statusDisplay": item.status,
                "accepted": LeetCodeStatus.isAccepted(statusCode: 0, display: item.status),
                "lang": item.language,
                "runtime": item.runtime,
                "memory": item.memory,
                "submittedAt": milliseconds,
                "url": item.url,
                "activityType": activityType
            ]
            byID[item.id] = value
            if latest == nil || milliseconds >= (latest?.double("submittedAt") ?? 0) { latest = value }
        }
        root["submissions"] = byID.values.sorted { $0.double("submittedAt") > $1.double("submittedAt") }

        var analysis = root["analysis"] as? [String: Any] ?? [:]
        var queue = analysis["queue"] as? [String: Any] ?? [:]
        let records = analysis["records"] as? [String: Any] ?? [:]
        let analyzed = Set((records[titleSlug] as? [String: Any])?.stringArray("analyzedSubmissionIds") ?? [])
        let candidates = LeetCodeSubmissionFingerprint.analysisCandidateIDs(
            incoming: incoming,
            knownIDs: knownIDs,
            analyzedIDs: analyzed,
            previousFingerprint: previousFingerprint,
            expectedSubmissionID: expectedSubmissionID,
            onDemand: onDemand
        )
        if !candidates.isEmpty {
            var task = queue[titleSlug] as? [String: Any] ?? [:]
            let previousIDs = task.stringArray("submissionIds")
            task["submissionIds"] = Array(Set(previousIDs + candidates)).sorted { left, right in
                (byID[left]?.double("submittedAt") ?? 0) < (byID[right]?.double("submittedAt") ?? 0)
            }.suffix(80).map { $0 }
            task["queuedAt"] = task.double("queuedAt") > 0 ? task.double("queuedAt") : Date.now.timeIntervalSince1970 * 1_000
            task["attempts"] = task.int("attempts")
            task["nextAttemptAt"] = 0
            task["lastError"] = ""
            task["reason"] = onDemand ? "on_demand" : "incremental"
            queue[titleSlug] = task
        }
        analysis["version"] = 1
        analysis["queue"] = queue
        analysis["records"] = records
        root["analysis"] = analysis
        questionFingerprints[titleSlug] = incomingFingerprint
        tracking["questionFingerprints"] = questionFingerprints
        root["tracking"] = tracking
        root["lastSyncAt"] = Date.now.timeIntervalSince1970 * 1_000
        root["lastError"] = ""
        root["updatedAt"] = Date.now.timeIntervalSince1970 * 1_000
        try writeJSONObject(root, named: "leetcode-cn.json")
        reload()
    }

    private func mergeLeetCodeSubmissionsIntoLearning() async throws {
        guard let root = jsonObject(named: "leetcode-cn.json") as? [String: Any] else { return }
        let plans = root["plans"] as? [String: Any] ?? [:]
        let questions = plans.values.compactMap { ($0 as? [String: Any])?["questions"] as? [[String: Any]] }.flatMap { $0 }
        let submissions = root["submissions"] as? [[String: Any]] ?? []
        let questionData = try JSONSerialization.data(withJSONObject: questions)
        let submissionData = try JSONSerialization.data(withJSONObject: submissions)
        try await learningBridge.mergeLeetCodeSubmissions(
            planQuestionsJSON: questionData,
            submissionsJSON: submissionData
        )
    }

    private func mergeLeetCodeAnalysisIntoLearning(_ titleSlug: String) async throws {
        guard let root = jsonObject(named: "leetcode-cn.json") as? [String: Any],
              let analysis = root["analysis"] as? [String: Any],
              let records = analysis["records"] as? [String: Any],
              let record = records[titleSlug] as? [String: Any]
        else { return }
        let data = try JSONSerialization.data(withJSONObject: record)
        try await learningBridge.mergeLeetCodeAnalysis(titleSlug: titleSlug, analysisJSON: data)
    }

    /// 账号级增量同步：不打开题目也能发现官网的新提交，
    /// 并入提交历史 / 学习引擎，并把已通过题目的未完成计划任务自动勾选。
    func syncLeetCodeAccountActivity() async {
        guard !isSyncingLeetCodeAccount else { return }
        isSyncingLeetCodeAccount = true
        defer { isSyncingLeetCodeAccount = false }
        do {
            let remote = try await LeetCodeAPIClient.shared.fetchSubmissions(titleSlug: "", limit: 40)
            guard !remote.isEmpty else { return }
            let knownIDs = Set(leetCodeSubmissions.map(\.id))
            var titleToSlug: [String: String] = [:]
            for question in leetCodeQuestions {
                let key = Self.normalizedTitle(question.title)
                if !key.isEmpty { titleToSlug[key] = question.titleSlug }
            }
            for submission in leetCodeSubmissions {
                let key = Self.normalizedTitle(submission.title)
                if !key.isEmpty, titleToSlug[key] == nil { titleToSlug[key] = submission.titleSlug }
            }
            var newBySlug: [String: [LeetCodeRemoteSubmission]] = [:]
            for item in remote where !knownIDs.contains(item.id) {
                // 全账号这条链路拿不到 slug（力扣中国的 SubmissionDumpNode 没这个字段，
                // 写进查询整条会报错），所以按标题反查。索引里除了本地题库，
                // 还并入了历史提交的标题——在浏览器里刷的题第一次也能落到正确的 slug 上。
                let slug = item.titleSlug.isEmpty
                    ? titleToSlug[Self.normalizedTitle(item.title)]
                    : item.titleSlug
                guard let slug, !slug.isEmpty else { continue }
                newBySlug[slug, default: []].append(item)
            }
            guard !newBySlug.isEmpty else { return }
            var acceptedTitles: Set<String> = []
            // 一次刷一堆题时 8 个太少：剩下的要等下一轮 10 分钟轮询才补。
            for (slug, items) in newBySlug.sorted(by: { $0.key < $1.key }).prefix(24) {
                try? mergeLeetCodeSubmissions(items, titleSlug: slug, expectedSubmissionID: nil, onDemand: false)
                for item in items where LeetCodeStatus.isAccepted(statusCode: 0, display: item.status) {
                    acceptedTitles.insert(Self.normalizedTitle(item.title))
                }
            }
            try? await mergeLeetCodeSubmissionsIntoLearning()
            autoCompleteStudyTasks(matchingTitles: acceptedTitles)
            reload()
        } catch {
        }
    }

    private static func normalizedTitle(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private func autoCompleteStudyTasks(matchingTitles: Set<String>) {
        guard !matchingTitles.isEmpty else { return }
        var changed = false
        for index in studyPlanTasks.indices where !studyPlanTasks[index].isCompleted {
            let titleKey = Self.normalizedTitle(studyPlanTasks[index].title)
            let recordKey = studyPlanTasks[index].learningRecordID.flatMap { id in
                learningRecords.first { $0.id == id }
            }.map { Self.normalizedTitle($0.title) } ?? ""
            if matchingTitles.contains(titleKey)
                || (!recordKey.isEmpty && matchingTitles.contains(recordKey)) {
                studyPlanTasks[index].isCompleted = true
                studyPlanTasks[index].completedAt = .now
                changed = true
            }
        }
        if changed { try? saveStudyPlan() }
    }

    private func removeLeetCodeAnalysisTask(_ titleSlug: String) throws {
        guard var root = jsonObject(named: "leetcode-cn.json") as? [String: Any] else { return }
        var analysis = root["analysis"] as? [String: Any] ?? [:]
        var queue = analysis["queue"] as? [String: Any] ?? [:]
        queue[titleSlug] = nil
        analysis["queue"] = queue
        root["analysis"] = analysis
        try writeJSONObject(root, named: "leetcode-cn.json")
        reload()
    }

    private func persistLeetCodeAnalysisSuccess(
        task: LeetCodeAnalysisTask,
        details: [LeetCodeSubmissionDetail],
        failedIDs: [String],
        draft: LeetCodeTrajectoryDraft
    ) throws {
        guard var root = jsonObject(named: "leetcode-cn.json") as? [String: Any] else { return }
        var analysis = root["analysis"] as? [String: Any] ?? [:]
        var queue = analysis["queue"] as? [String: Any] ?? [:]
        var records = analysis["records"] as? [String: Any] ?? [:]
        let previous = records[task.titleSlug] as? [String: Any] ?? [:]
        let now = Date.now.timeIntervalSince1970 * 1_000
        let processedIDs = details.map(\.id)
        let validInsights = draft.attemptInsights.filter { processedIDs.contains($0.submissionId) }
        var insightsByID = Dictionary(uniqueKeysWithValues: (previous["attemptInsights"] as? [[String: Any]] ?? []).compactMap { item -> (String, [String: Any])? in
            let id = item.string("submissionId")
            return id.isEmpty ? nil : (id, item)
        })
        for insight in validInsights {
            insightsByID[insight.submissionId] = [
                "submissionId": insight.submissionId,
                "issue": String(insight.issue.prefix(600)),
                "change": String(insight.change.prefix(600)),
                "outcome": String(insight.outcome.prefix(600))
            ]
        }
        let submissionTimes = Dictionary(uniqueKeysWithValues: leetCodeSubmissions.map { ($0.id, $0.submittedAt.timeIntervalSince1970 * 1_000) })
        let orderedInsights = insightsByID.values.sorted {
            (submissionTimes[$0.string("submissionId")] ?? 0) < (submissionTimes[$1.string("submissionId")] ?? 0)
        }.suffix(80).map { $0 }
        var snapshots = previous["submissionAnalyses"] as? [String: Any] ?? [:]
        for insight in validInsights {
            snapshots[insight.submissionId] = [
                "summary": String(draft.summary.prefix(2_000)),
                "rootCause": String(insight.issue.prefix(800)),
                "evidence": [],
                "suggestions": insight.change.isEmpty ? [] : [String(insight.change.prefix(400))],
                "knowledgeGaps": draft.weaknesses.prefix(8).map { String($0.prefix(400)) },
                "updatedAt": now
            ]
        }
        let previousAnalyzed = previous.stringArray("analyzedSubmissionIds")
        let latestSubmissionAt = max(
            previous.double("latestSubmissionAt"),
            processedIDs.compactMap { submissionTimes[$0] }.max() ?? 0
        )
        let record: [String: Any] = [
            "version": 1,
            "analyzedSubmissionIds": Array(Set(previousAnalyzed + processedIDs)).suffix(500).map { $0 },
            "summary": String(draft.summary.prefix(2_000)),
            "weaknesses": draft.weaknesses.prefix(12).map { String($0.prefix(400)) },
            "improvements": draft.improvements.prefix(12).map { String($0.prefix(400)) },
            "attemptInsights": orderedInsights,
            "submissionAnalyses": snapshots,
            "latestSubmissionAt": latestSubmissionAt,
            "summaryUpdatedAt": now,
            "updatedAt": now
        ]
        records[task.titleSlug] = record
        var currentTask = queue[task.titleSlug] as? [String: Any] ?? [:]
        let previousFailures = (currentTask["failedSubmissionAttempts"] as? [String: Any] ?? [:])
            .mapValues { ($0 as? NSNumber)?.intValue ?? 0 }
        let failures = LeetCodeAnalysisRetryBudget.recordFailures(failedIDs, current: previousFailures)
        currentTask["failedSubmissionAttempts"] = failures
        currentTask["submissionIds"] = LeetCodeAnalysisRetryBudget.eligible(
            task.submissionIDs.filter { !processedIDs.contains($0) },
            failures: failures
        )
        currentTask["attempts"] = 0
        currentTask["lastAttemptAt"] = now
        currentTask["lastError"] = failedIDs.isEmpty ? "" : "部分提交详情暂时无法读取"
        currentTask["nextAttemptAt"] = currentTask.stringArray("submissionIds").isEmpty ? 0 : now + 5 * 60 * 1_000
        if currentTask.stringArray("submissionIds").isEmpty { queue[task.titleSlug] = nil }
        else { queue[task.titleSlug] = currentTask }
        analysis["queue"] = queue
        analysis["records"] = records
        root["analysis"] = analysis
        root["updatedAt"] = now
        try writeJSONObject(root, named: "leetcode-cn.json")
        reload()
    }

    private func persistLeetCodeAnalysisFailure(
        task: LeetCodeAnalysisTask,
        failedIDs: [String],
        error: Error
    ) throws {
        guard var root = jsonObject(named: "leetcode-cn.json") as? [String: Any] else { return }
        var analysis = root["analysis"] as? [String: Any] ?? [:]
        var queue = analysis["queue"] as? [String: Any] ?? [:]
        guard var currentTask = queue[task.titleSlug] as? [String: Any] else { return }
        let attempts = min(LeetCodeAnalysisRetryBudget.taskAttempts, currentTask.int("attempts") + 1)
        let now = Date.now.timeIntervalSince1970 * 1_000
        currentTask["attempts"] = attempts
        currentTask["lastAttemptAt"] = now
        currentTask["lastError"] = String(error.localizedDescription.prefix(300))
        currentTask["nextAttemptAt"] = now + min(30 * 60 * 1_000, 30 * 1_000 * pow(2, Double(attempts)))
        let previousFailures = (currentTask["failedSubmissionAttempts"] as? [String: Any] ?? [:])
            .mapValues { ($0 as? NSNumber)?.intValue ?? 0 }
        let failures = LeetCodeAnalysisRetryBudget.recordFailures(
            failedIDs.isEmpty ? task.submissionIDs : failedIDs,
            current: previousFailures
        )
        currentTask["failedSubmissionAttempts"] = failures
        currentTask["submissionIds"] = LeetCodeAnalysisRetryBudget.eligible(
            currentTask.stringArray("submissionIds"),
            failures: failures
        )
        if currentTask.stringArray("submissionIds").isEmpty { queue[task.titleSlug] = nil }
        else { queue[task.titleSlug] = currentTask }
        analysis["queue"] = queue
        root["analysis"] = analysis
        try writeJSONObject(root, named: "leetcode-cn.json")
        reload()
    }

    func applyLeetCodeWebSync(
        account: [String: Any],
        submissions incoming: [[String: Any]],
        studyPlan: [String: Any]? = nil
    ) throws {
        var root = (jsonObject(named: "leetcode-cn.json") as? [String: Any]) ?? [:]
        root["account"] = [
            "signedIn": account.bool("isSignedIn"),
            "username": account.string("username"),
            "realName": account.string("realName", fallback: account.string("username")),
            "userSlug": account.string("userSlug"),
            "avatar": account.string("avatar"),
            "isPremium": account.bool("isPremium")
        ]

        var plans = root["plans"] as? [String: Any] ?? [:]
        if let studyPlan {
            let slug = studyPlan.string("slug")
            if !slug.isEmpty {
                let groups = studyPlan["planSubGroups"] as? [[String: Any]] ?? []
                let questions = groups.flatMap { group in
                    (group["questions"] as? [[String: Any]] ?? []).map { question in
                        var normalized = question
                        normalized["frontendId"] = question.string("questionFrontendId")
                        normalized["groupName"] = group.string("name")
                        normalized["topicTags"] = (question["topicTags"] as? [[String: Any]] ?? []).map { tag in
                            var value = tag
                            value["translatedName"] = tag.string("nameTranslated", fallback: tag.string("name"))
                            return value
                        }
                        return normalized
                    }
                }
                plans[slug] = [
                    "slug": slug,
                    "name": studyPlan.string("name", fallback: slug),
                    "description": studyPlan.string("description"),
                    "questions": questions,
                    "syncedAt": Date.now.timeIntervalSince1970 * 1_000
                ]
                root["plans"] = plans
                root["activePlanSlug"] = slug
            }
        }
        var questionsByTitle: [String: [String: Any]] = [:]
        for rawPlan in plans.values {
            guard let plan = rawPlan as? [String: Any] else { continue }
            for question in plan["questions"] as? [[String: Any]] ?? [] {
                for title in [question.string("title"), question.string("translatedTitle")].filter({ !$0.isEmpty }) {
                    questionsByTitle[title.lowercased()] = question
                }
            }
        }

        var byID = Dictionary(uniqueKeysWithValues: (root["submissions"] as? [[String: Any]] ?? []).compactMap { value -> (String, [String: Any])? in
            let id = value.string("id")
            return id.isEmpty ? nil : (id, value)
        })
        for raw in incoming {
            let id = raw.string("id")
            guard !id.isEmpty else { continue }
            let question = questionsByTitle[raw.string("title").lowercased()]
            let status = raw.string("statusDisplay")
            let timestamp = raw.double("timestamp")
            var value = byID[id] ?? [:]
            value.merge([
                "id": id,
                "titleSlug": question?.string("titleSlug") ?? value.string("titleSlug"),
                "frontendId": question?.string("frontendId", fallback: question?.string("questionFrontendId") ?? "") ?? value.string("frontendId"),
                "title": question?.string("title", fallback: raw.string("title")) ?? raw.string("title"),
                "translatedTitle": question?.string("translatedTitle", fallback: raw.string("title")) ?? raw.string("title"),
                "statusDisplay": status,
                "accepted": LeetCodeStatus.isAccepted(statusCode: raw.int("statusCode"), display: status),
                "lang": raw.string("lang"),
                "runtime": raw.string("runtime"),
                "memory": raw.string("memory"),
                "submittedAt": timestamp > 100_000_000_000 ? timestamp : timestamp * 1_000,
                "url": raw.string("url")
            ]) { _, new in new }
            byID[id] = value
        }
        root["submissions"] = byID.values.sorted { $0.double("submittedAt") > $1.double("submittedAt") }
        root["lastSyncAt"] = Date.now.timeIntervalSince1970 * 1_000
        root["lastError"] = ""
        try writeJSONObject(root, named: "leetcode-cn.json")
        reload()
    }

    func applyBilibiliWebLogin(userID: String, name: String = "", avatar: String = "") throws {
        let value: [String: Any] = [
            "signedIn": true,
            "userID": userID,
            "name": name,
            "avatar": avatar,
            "updatedAt": Date.now.timeIntervalSince1970 * 1_000
        ]
        try writeJSONObject(value, named: "native-bilibili-account.json")
        loadNativeAccountState()
    }

    @discardableResult
    func createConversation(title: String, firstMessage: ConversationTranscriptMessage? = nil) throws -> String {
        let id = "c_\(Int(Date.now.timeIntervalSince1970 * 1_000))_\(Self.shortIdentifier())"
        let messages = firstMessage.map { [Self.messageDictionary($0)] } ?? []
        try updateConversationFile { root in
            root[id] = [
                "schemaVersion": 3,
                "title": Self.conversationTitle(from: title),
                "summary": "",
                "messages": messages,
                "updatedAt": Int(Date.now.timeIntervalSince1970 * 1_000)
            ]
        }
        reload()
        return id
    }

    func appendMessage(_ message: ConversationTranscriptMessage, to conversationID: String) throws {
        let updatedAt = Date.now
        try updateConversationFile { root in
            guard var conversation = root[conversationID] as? [String: Any] else {
                throw ConversationStoreError.missingConversation
            }
            var messages = conversation["messages"] as? [[String: Any]] ?? []
            messages.append(Self.messageDictionary(message))
            conversation["messages"] = messages
            conversation["updatedAt"] = Int(updatedAt.timeIntervalSince1970 * 1_000)
            root[conversationID] = conversation
        }
        try updateCachedConversation(conversationID, updatedAt: updatedAt) { messages in
            messages.append(message)
        }
    }

    func upsertMessage(_ message: ConversationTranscriptMessage, in conversationID: String) throws {
        let updatedAt = Date.now
        try updateConversationFile { root in
            guard var conversation = root[conversationID] as? [String: Any] else {
                throw ConversationStoreError.missingConversation
            }
            var messages = conversation["messages"] as? [[String: Any]] ?? []
            if let index = messages.firstIndex(where: { ($0["id"] as? String) == message.id }) {
                messages[index] = Self.messageDictionary(message)
            } else {
                messages.append(Self.messageDictionary(message))
            }
            conversation["messages"] = messages
            conversation["updatedAt"] = Int(updatedAt.timeIntervalSince1970 * 1_000)
            root[conversationID] = conversation
        }
        try updateCachedConversation(conversationID, updatedAt: updatedAt) { messages in
            if let index = messages.firstIndex(where: { $0.id == message.id }) { messages[index] = message }
            else { messages.append(message) }
        }
    }

    /// `archivedMessageCount` 是摘要覆盖到第几条消息的水位线，滚动重写时靠它决定
    /// 增量喂哪几条。标题只在第一次归档时写，后面滚动更新不该把用户看惯的标题改掉。
    func applyArchive(
        _ archive: ConversationArchiveSummary,
        to conversationID: String,
        messageCount: Int,
        renames: Bool
    ) throws {
        try updateConversationFile { root in
            guard var conversation = root[conversationID] as? [String: Any] else {
                throw ConversationStoreError.missingConversation
            }
            if renames {
                conversation["aiTitle"] = archive.title
                conversation["title"] = archive.title
            }
            conversation["aiSummary"] = archive.summary
            conversation["contextSummary"] = archive.context
            conversation["summary"] = archive.summary
            conversation["archivedMessageCount"] = messageCount
            conversation["updatedAt"] = Int(Date.now.timeIntervalSince1970 * 1_000)
            root[conversationID] = conversation
        }
        reload()
    }

    func renameConversation(_ conversationID: String, title: String) throws {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { throw ConversationStoreError.invalidTitle }
        try updateConversationFile { root in
            guard var conversation = root[conversationID] as? [String: Any] else {
                throw ConversationStoreError.missingConversation
            }
            conversation["title"] = String(title.prefix(80))
            conversation["updatedAt"] = Int(Date.now.timeIntervalSince1970 * 1_000)
            root[conversationID] = conversation
        }
        reload()
    }

    func setConversationPinned(_ conversationID: String, pinned: Bool) throws {
        try updateConversationFile { root in
            guard var conversation = root[conversationID] as? [String: Any] else {
                throw ConversationStoreError.missingConversation
            }
            conversation["pinned"] = pinned
            root[conversationID] = conversation
        }
        reload()
    }

    @discardableResult
    func duplicateConversation(_ conversationID: String) throws -> String {
        let newID = "c_\(Int(Date.now.timeIntervalSince1970 * 1_000))_\(Self.shortIdentifier())"
        try updateConversationFile { root in
            guard var conversation = root[conversationID] as? [String: Any] else {
                throw ConversationStoreError.missingConversation
            }
            let originalTitle = conversation["title"] as? String ?? "未命名会话"
            conversation["title"] = String("\(originalTitle) 副本".prefix(80))
            conversation["pinned"] = false
            conversation["updatedAt"] = Int(Date.now.timeIntervalSince1970 * 1_000)
            root[newID] = conversation
        }
        reload()
        return newID
    }

    func deleteConversation(_ conversationID: String) throws {
        try updateConversationFile { root in
            guard root.removeValue(forKey: conversationID) != nil else {
                throw ConversationStoreError.missingConversation
            }
        }
        reload()
    }

    func activateProvider(_ providerID: String) throws {
        try updateSettingsFile { root in
            let providers = root["providers"] as? [String: Any] ?? [:]
            guard providers[providerID] != nil else {
                throw ConversationStoreError.missingProvider
            }
            root["activeProvider"] = providerID
        }
        reload()
    }

    /// 模型菜单里的一次选择必须是原子写：改模型与切默认在同一次
    /// read-modify-write 里完成，避免两次写之间被并发的设置页自动保存
    /// 插进来，只落下一半（模型改了、默认没切）。
    func selectProviderModel(_ providerID: String, model: String) throws {
        try updateSettingsFile { root in
            var providers = root["providers"] as? [String: Any] ?? [:]
            guard var provider = providers[providerID] as? [String: Any] else {
                throw ConversationStoreError.missingProvider
            }
            provider["model"] = model.trimmingCharacters(in: .whitespacesAndNewlines)
            providers[providerID] = provider
            root["providers"] = providers
            root["activeProvider"] = providerID
        }
        reload()
    }

    func saveTaskRoute(_ key: String, providerID: String?) throws {
        guard AITaskRoute(rawValue: key) != nil else { throw ConversationStoreError.invalidTaskRoute }
        try updateSettingsFile { root in
            if let providerID {
                let providers = root["providers"] as? [String: Any] ?? [:]
                guard providers[providerID] != nil else {
                    throw ConversationStoreError.missingProvider
                }
            }
            var routes = root["taskModels"] as? [String: Any] ?? [:]
            if let providerID {
                routes[key] = ["providerId": providerID]
            } else {
                routes.removeValue(forKey: key)
            }
            root["taskModels"] = routes
        }
        reload()
    }

    func saveProvider(
        id: String,
        apiBase: String,
        apiKey: String,
        model: String,
        mode: String
    ) throws {
        // Validate before touching the keychain: a rejected URL must not leave a new
        // secret stored against settings that were never written.
        let normalizedBase = try ProviderURLPolicy.normalize(apiBase)
        let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let previousSecret = try ProviderKeychain.readIfPresent(providerID: id)
        if !trimmedKey.isEmpty { try ProviderKeychain.store(trimmedKey, providerID: id) }
        do {
            try updateSettingsFile { root in
                var providers = root["providers"] as? [String: Any] ?? [:]
                guard var provider = providers[id] as? [String: Any] else {
                    throw ConversationStoreError.missingProvider
                }
                provider["apiBase"] = normalizedBase.apiBase
                provider["model"] = model.trimmingCharacters(in: .whitespacesAndNewlines)
                provider["apiMode"] = mode
                // A pasted generation endpoint tells us the mode more reliably than the picker.
                if mode == "auto", !normalizedBase.endpointHint.isEmpty {
                    provider["resolvedMode"] = normalizedBase.endpointHint
                } else {
                    provider["resolvedMode"] = mode == "auto" ? provider["resolvedMode"] : mode
                }
                if !trimmedKey.isEmpty { provider["apiKey"] = ProviderKeychain.marker(for: id) }
                providers[id] = provider
                root["providers"] = providers
            }
        } catch {
            if !trimmedKey.isEmpty {
                if let previousSecret { try? ProviderKeychain.store(previousSecret, providerID: id) }
                else { try? ProviderKeychain.delete(providerID: id) }
            }
            throw error
        }
        reload()
    }

    @discardableResult
    func addProvider() throws -> String {
        let id = "custom-\(Self.shortIdentifier())"
        try updateSettingsFile { root in
            var providers = root["providers"] as? [String: Any] ?? [:]
            providers[id] = [
                "name": "自定义供应商",
                "apiBase": "https://api.openai.com/v1",
                "apiKey": "",
                "model": "",
                "apiMode": "auto",
                "resolvedMode": "auto"
            ]
            root["providers"] = providers
            var order = root["providerOrder"] as? [String] ?? []
            order.append(id)
            root["providerOrder"] = order
        }
        reload()
        return id
    }

    /// 只有自定义供应商能改名——内置三家的名字是身份标识，改了对不上图标。
    func renameProvider(_ providerID: String, to name: String) throws {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw ConversationStoreError.invalidTitle }
        try updateSettingsFile { root in
            var providers = root["providers"] as? [String: Any] ?? [:]
            guard var provider = providers[providerID] as? [String: Any] else {
                throw ConversationStoreError.missingProvider
            }
            provider["name"] = String(trimmed.prefix(40))
            providers[providerID] = provider
            root["providers"] = providers
        }
        reload()
    }

    func deleteProvider(_ providerID: String) throws {
        let previousSecret = try ProviderKeychain.readIfPresent(providerID: providerID)
        try ProviderKeychain.delete(providerID: providerID)
        do {
            try updateSettingsFile { root in
                var providers = root["providers"] as? [String: Any] ?? [:]
                guard providers.removeValue(forKey: providerID) != nil else {
                    throw ConversationStoreError.missingProvider
                }
                root["providers"] = providers
                let remaining = (root["providerOrder"] as? [String] ?? []).filter {
                    $0 != providerID && providers[$0] != nil
                }
                root["providerOrder"] = remaining
                if root.string("activeProvider") == providerID {
                    root["activeProvider"] = remaining.first ?? ""
                }
                var routes = root["taskModels"] as? [String: Any] ?? [:]
                routes = routes.filter { _, value in
                    guard let route = value as? [String: Any] else { return false }
                    return route.string("providerId") != providerID
                }
                root["taskModels"] = routes
            }
        } catch {
            if let previousSecret { try? ProviderKeychain.store(previousSecret, providerID: providerID) }
            throw error
        }
        reload()
    }

    func saveContextPolicy(
        window: Double,
        reserved: Double,
        compression: Double,
        postCompression: Double,
        recentMessages: Double,
        maxImages: Double
    ) throws {
        try updateSettingsFile { root in
            root["contextPolicy"] = [
                "contextWindowTokens": Int(window),
                "reservedOutputTokens": Int(reserved),
                "compressionThreshold": compression,
                "postCompressionRatio": postCompression,
                "recentMessages": Int(recentMessages),
                "maxImages": Int(maxImages)
            ]
        }
        reload()
    }

    func saveGeneral(alwaysOnTop: Bool? = nil, videoAutoplay: Bool? = nil) throws {
        try updateSettingsFile { root in
            if let alwaysOnTop { root["alwaysOnTop"] = alwaysOnTop }
            if let videoAutoplay { root["videoAutoplay"] = videoAutoplay }
        }
        reload()
    }

    func saveAppearance(_ appearance: String, emphasizeMotion: Bool) throws {
        let allowed = ["system", "light", "dark"]
        try updateSettingsFile { root in
            root["appearance"] = allowed.contains(appearance) ? appearance : "system"
            root["emphasizeMotion"] = emphasizeMotion
        }
        reload()
    }

    func clearVideoHistory() throws {
        try FileManager.default.createDirectory(at: dataDirectory, withIntermediateDirectories: true)
        let data = try JSONSerialization.data(withJSONObject: [], options: [])
        try data.write(to: dataDirectory.appending(path: "video-history.json"), options: .atomic)
        reload()
    }

    /// Records a completed Bilibili video navigation. WebKit can publish the same
    /// load more than once, so nearby updates refresh metadata without inflating
    /// the open count.
    func recordVideoVisit(url: URL, title: String, at date: Date = .now) throws {
        guard let bvid = BilibiliVideoURLPolicy.bvid(from: url) else { return }
        ensureLoaded()
        let existing = videoHistory.first { $0.bvid == bvid }
        let isNewVisit = existing.map { date.timeIntervalSince($0.lastOpenedAt) >= 30 } ?? true
        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let updated = VideoHistoryEntry(
            bvid: bvid,
            title: cleanTitle.isEmpty ? (existing?.title ?? bvid) : cleanTitle,
            coverURL: existing?.coverURL,
            progress: existing?.progress ?? 0,
            duration: existing?.duration ?? 0,
            lastOpenedAt: date,
            openCount: max(1, (existing?.openCount ?? 0) + (isNewVisit ? 1 : 0))
        )
        videoHistory.removeAll { $0.bvid == bvid }
        videoHistory.append(updated)
        videoHistory.sort { $0.lastOpenedAt > $1.lastOpenedAt }
        let values: [[String: Any]] = videoHistory.map {
            [
                "bvid": $0.bvid,
                "title": $0.title,
                "cover": $0.coverURL?.absoluteString ?? "",
                "progress": $0.progress,
                "duration": $0.duration,
                "lastOpenedAt": $0.lastOpenedAt.timeIntervalSince1970 * 1_000,
                "openCount": $0.openCount
            ]
        }
        try writeJSONObject(values, named: "video-history.json")
    }

    func createStudyTask(_ draft: StudyPlanDraft) throws {
        try createStudyTasks([draft])
    }

    func createStudyTasks(_ drafts: [StudyPlanDraft]) throws {
        ensureLoaded()
        let tasks = try drafts.map { draft in
            let title = draft.title.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty else { throw ConversationStoreError.invalidTitle }
            return StudyPlanTask(
                id: "task_\(Self.shortIdentifier())",
                title: String(title.prefix(120)),
                notes: String(draft.notes.trimmingCharacters(in: .whitespacesAndNewlines).prefix(2_000)),
                scheduledAt: draft.scheduledAt,
                durationMinutes: min(480, max(5, draft.durationMinutes)),
                priority: draft.priority,
                isCompleted: false,
                learningRecordID: draft.learningRecordID,
                createdAt: .now,
                completedAt: nil
            )
        }
        let previousTasks = studyPlanTasks
        studyPlanTasks.append(contentsOf: tasks)
        do {
            try saveStudyPlan()
        } catch {
            studyPlanTasks = previousTasks
            throw error
        }
    }

    func updateStudyTask(_ task: StudyPlanTask) throws {
        ensureLoaded()
        guard let index = studyPlanTasks.firstIndex(where: { $0.id == task.id }) else { return }
        studyPlanTasks[index] = task
        try saveStudyPlan()
    }

    func toggleStudyTask(_ taskID: String) throws {
        ensureLoaded()
        guard let index = studyPlanTasks.firstIndex(where: { $0.id == taskID }) else { return }
        studyPlanTasks[index].isCompleted.toggle()
        studyPlanTasks[index].completedAt = studyPlanTasks[index].isCompleted ? .now : nil
        try saveStudyPlan()
    }

    func deleteStudyTask(_ taskID: String) throws {
        ensureLoaded()
        studyPlanTasks.removeAll { $0.id == taskID }
        try saveStudyPlan()
    }

    func deleteStudyTasks(_ ids: Set<String>) throws {
        ensureLoaded()
        guard !ids.isEmpty else { return }
        studyPlanTasks.removeAll { ids.contains($0.id) }
        try saveStudyPlan()
    }

    func learningExportData() throws -> Data {
        let records: [[String: Any]] = learningRecords.map { record in
            [
                "id": record.id,
                "kind": record.kind,
                "title": record.title,
                "question": record.question,
                "diagnosis": record.diagnosis,
                "labels": record.labels,
                "prerequisiteLabels": record.prerequisiteLabels,
                "knowledgePath": record.knowledgePath,
                "masteryScore": record.masteryScore,
                "confidence": record.confidence,
                "language": record.language,
                "dueAt": Int(record.dueAt.timeIntervalSince1970 * 1_000),
                "reviewCount": record.reviewCount,
                "evidence": record.evidence.map {
                    ["id": $0.id, "signal": $0.signal, "summary": $0.summary, "observedAt": Int($0.observedAt.timeIntervalSince1970 * 1_000)]
                },
                "sourceRefs": record.sourceRefs.map {
                    ["conversationId": $0.conversationID, "messageId": $0.messageID, "excerpt": $0.excerpt]
                }
            ]
        }
        return try JSONSerialization.data(
            withJSONObject: ["exportedAt": ISO8601DateFormatter().string(from: .now), "records": records],
            options: [.prettyPrinted, .sortedKeys]
        )
    }

    func pendingLearningAnalysis(for conversationID: String) -> (
        messages: [LearningAnalysisMessage],
        context: [LearningAnalysisContext],
        fingerprint: String,
        versions: [String]
    )? {
        guard let conversation = conversations.first(where: { $0.id == conversationID }) else { return nil }
        let root = jsonObject(named: "learning.json") as? [String: Any] ?? [:]
        let analyses = root["analysis"] as? [String: Any] ?? [:]
        let analysis = analyses[conversationID] as? [String: Any] ?? [:]
        let processed = Set(analysis.stringArray("messageVersions"))
        let candidates = conversation.messages.compactMap { message -> (LearningAnalysisMessage, String)? in
            guard message.role == "user", message.id.hasPrefix("m_"), !message.content.isEmpty else { return nil }
            let clipped = String(message.content.prefix(12_000))
            let digest = SHA256.hash(data: Data(clipped.utf8)).map { String(format: "%02x", $0) }.joined()
            let version = "\(message.id):\(digest.prefix(24))"
            guard !processed.contains(version) else { return nil }
            return (LearningAnalysisMessage(id: message.id, content: clipped, createdAt: message.createdAt), version)
        }
        guard !candidates.isEmpty else { return nil }

        var characterCount = 0
        var selected: [(LearningAnalysisMessage, String)] = []
        for candidate in candidates.prefix(16) {
            let remaining = 36_000 - characterCount
            guard remaining > 0 else { break }
            let clipped = String(candidate.0.content.prefix(remaining))
            selected.append((.init(id: candidate.0.id, content: clipped, createdAt: candidate.0.createdAt), candidate.1))
            characterCount += clipped.count
        }
        let messages = selected.map(\.0)
        let fingerprintSource = messages.map { "\($0.id)\0\($0.content)" }.joined(separator: "\0\0")
        let fingerprint = SHA256.hash(data: Data(fingerprintSource.utf8)).map { String(format: "%02x", $0) }.joined()
        let context = learningRecords
            .filter { record in record.sourceRefs.contains { $0.conversationID == conversationID } }
            .sorted { $0.updatedAt > $1.updatedAt }
            .prefix(12)
            .map {
                LearningAnalysisContext(
                    id: $0.id,
                    kind: $0.kind,
                    title: $0.title,
                    question: $0.question,
                    knowledgePath: $0.knowledgePath,
                    language: $0.language,
                    labels: $0.labels,
                    diagnosis: $0.diagnosis,
                    masteryScore: $0.masteryScore,
                    confidence: $0.confidence,
                    evidenceCount: $0.evidenceCount
                )
            }
        return (messages, Array(context), fingerprint, selected.map(\.1))
    }

    func mergeLearningAnalysis(
        conversationID: String,
        result: LearningAnalysisResult,
        messages: [LearningAnalysisMessage]
    ) async throws {
        try await learningBridge.mergeAnalysis(conversationID: conversationID, result: result, messages: messages)
        reload()
    }

    func reviewLearningRecord(_ recordID: String, rating: Int) async throws {
        try await learningBridge.review(itemID: recordID, rating: rating)
        reload()
    }

    func saveLearningPackage(_ package: LearningPackageDraft, for recordID: String) async throws {
        try await learningBridge.savePackage(itemID: recordID, package: package)
        reload()
    }

    func recordLearningAttempt(
        recordID: String,
        packageID: String,
        answer: String,
        judgment: LearningAttemptJudgment
    ) async throws {
        try await learningBridge.recordAttempt(
            itemID: recordID,
            packageID: packageID,
            answer: answer,
            judgment: judgment
        )
        reload()
    }

    /// Moves an active knowledge item to the trash and publishes a new active-set
    /// revision, so anything derived from the old set (prompts, graph, plans) refreshes.
    func deleteLearningRecord(_ recordID: String) async throws {
        try await learningBridge.delete(itemID: recordID)
        reload()
        activeLearningRevision &+= 1
    }

    func restoreLearningRecord(_ recordID: String) async throws {
        try await learningBridge.restore(itemID: recordID)
        reload()
        activeLearningRevision &+= 1
    }

    func purgeLearningRecord(_ recordID: String) async throws {
        try await learningBridge.purge(itemID: recordID)
        reload()
    }

    func emptyLearningTrash() async throws {
        try await learningBridge.emptyTrash()
        reload()
    }

    func saveLearningSettings(
        dailyNewTarget: Int,
        weekdayReviewTarget: Int,
        weeklyReviewTarget: Int,
        preferredLanguage: String
    ) async throws {
        let language = preferredLanguage
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard (0...12).contains(dailyNewTarget),
              (0...30).contains(weekdayReviewTarget),
              (0...60).contains(weeklyReviewTarget),
              !language.isEmpty,
              language.count <= 24
        else { throw ConversationStoreError.invalidLearningSettings }
        try await learningBridge.updateSettings(
            dailyNewTarget: dailyNewTarget,
            weekdayReviewTarget: weekdayReviewTarget,
            weeklyReviewTarget: weeklyReviewTarget,
            preferredLanguage: language
        )
        loadLearningExtras()
        lastReloadedAt = .now
    }

    func reload() {
        conversations = loadConversations()
        scheduleMemoryIndexSync()
        learningRecords = loadLearningRecords()
        loadLearningExtras()
        loadStudyPlan()
        loadSettings()
        loadLeetCode()
        loadVideoHistory()
        loadNativeAccountState()
        lastReloadedAt = .now
    }

    private func loadNativeAccountState() {
        let value = jsonObject(named: "native-bilibili-account.json") as? [String: Any] ?? [:]
        bilibiliSignedIn = value.bool("signedIn")
        bilibiliUserID = value.string("userID")
        bilibiliName = value.string("name")
        bilibiliAvatarURL = URL(string: value.string("avatar"))
    }

    private func loadStudyPlan() {
        let url = dataDirectory.appending(path: "study-plan.json")
        guard let data = try? Data(contentsOf: url),
              let tasks = try? JSONDecoder().decode([StudyPlanTask].self, from: data)
        else {
            studyPlanTasks = []
            return
        }
        studyPlanTasks = tasks.sorted { $0.scheduledAt < $1.scheduledAt }
    }

    private func saveStudyPlan() throws {
        try FileManager.default.createDirectory(at: dataDirectory, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(studyPlanTasks.sorted { $0.scheduledAt < $1.scheduledAt })
        try data.write(to: dataDirectory.appending(path: "study-plan.json"), options: .atomic)
        studyPlanTasks.sort { $0.scheduledAt < $1.scheduledAt }
    }

    private func loadVideoHistory() {
        let values = jsonObject(named: "video-history.json") as? [[String: Any]] ?? []
        videoHistory = values.compactMap { value in
            let bvid = value.string("bvid")
            guard !bvid.isEmpty else { return nil }
            return VideoHistoryEntry(
                bvid: bvid,
                title: value.string("title", fallback: bvid),
                coverURL: URL(string: value.string("cover")),
                progress: value.double("progress"),
                duration: value.double("duration"),
                lastOpenedAt: value.date("lastOpenedAt"),
                openCount: value.int("openCount")
            )
        }
        .sorted { $0.lastOpenedAt > $1.lastOpenedAt }
    }

    private static var defaultDataDirectory: URL {
        guard let applicationSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else {
            return FileManager.default.temporaryDirectory
                .appending(path: "leetcode-ai-helper/data", directoryHint: .isDirectory)
        }
        return applicationSupport.appending(path: "leetcode-ai-helper/data", directoryHint: .isDirectory)
    }

    private func jsonObject(named fileName: String) -> Any? {
        let url = dataDirectory.appending(path: fileName)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONSerialization.jsonObject(with: data)
    }

    private func writeJSONObject(_ value: Any, named fileName: String) throws {
        try FileManager.default.createDirectory(at: dataDirectory, withIntermediateDirectories: true)
        let data = try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: dataDirectory.appending(path: fileName), options: .atomic)
    }

    private func updateConversationFile(_ update: (inout [String: Any]) throws -> Void) throws {
        try FileManager.default.createDirectory(
            at: dataDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let url = dataDirectory.appending(path: "conversations.json")
        var root = (jsonObject(named: "conversations.json") as? [String: Any]) ?? [:]
        try update(&root)
        let data = try JSONSerialization.data(withJSONObject: root, options: [])
        try data.write(to: url, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    private func updateCachedConversation(
        _ conversationID: String,
        updatedAt: Date,
        mutateMessages: (inout [ConversationTranscriptMessage]) -> Void
    ) throws {
        guard let index = conversations.firstIndex(where: { $0.id == conversationID }) else {
            // Another process can add a conversation after this store was loaded.
            // Reconcile only the conversation file on that rare cache miss; the
            // normal streaming path remains incremental and avoids a global reload.
            conversations = loadConversations()
            scheduleMemoryIndexSync()
            guard conversations.contains(where: { $0.id == conversationID }) else {
                throw ConversationStoreError.missingConversation
            }
            lastReloadedAt = updatedAt
            return
        }
        let previous = conversations[index]
        var messages = previous.messages
        mutateMessages(&messages)
        conversations[index] = ConversationSummary(
            id: previous.id,
            title: previous.title,
            summary: previous.summary,
            updatedAt: updatedAt,
            messageCount: messages.count,
            messages: messages,
            aiTitle: previous.aiTitle,
            aiSummary: previous.aiSummary,
            contextSummary: previous.contextSummary,
            archivedMessageCount: previous.archivedMessageCount,
            usage: previous.usage,
            lastChatUsage: previous.lastChatUsage,
            isPinned: previous.isPinned
        )
        conversations.sort { $0.updatedAt > $1.updatedAt }
        scheduleMemoryIndexSync()
        lastReloadedAt = updatedAt
    }

    private func updateSettingsFile(_ update: (inout [String: Any]) throws -> Void) throws {
        try FileManager.default.createDirectory(at: dataDirectory, withIntermediateDirectories: true)
        let url = dataDirectory.appending(path: "settings.json")
        var root = (jsonObject(named: "settings.json") as? [String: Any]) ?? [:]
        try update(&root)
        let data = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: url, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    private static func messageDictionary(_ message: ConversationTranscriptMessage) -> [String: Any] {
        var value: [String: Any] = [
            "id": message.id,
            "role": message.role,
            "content": message.content,
            "artifacts": message.artifacts.map {
                ["type": $0.type, "url": $0.url, "title": $0.title]
            },
            "toolCalls": message.toolCalls,
            "createdAt": Int(message.createdAt.timeIntervalSince1970 * 1_000)
        ]
        if !message.providerID.isEmpty { value["providerId"] = message.providerID }
        if !message.model.isEmpty { value["model"] = message.model }
        return value
    }

    private static func conversationTitle(from text: String) -> String {
        let compact = text
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !compact.isEmpty else { return "新建会话" }
        return String(compact.prefix(32))
    }

    private static func shortIdentifier() -> String {
        String(UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: "").prefix(7))
    }

    private func loadConversations() -> [ConversationSummary] {
        guard let root = jsonObject(named: "conversations.json") as? [String: Any] else { return [] }
        return root.compactMap { id, rawValue in
            guard let value = rawValue as? [String: Any] else { return nil }
            let messages = value["messages"] as? [Any] ?? []
            let transcript = messages.compactMap { rawMessage -> ConversationTranscriptMessage? in
                guard
                    let message = rawMessage as? [String: Any],
                    message.string("role") != "system",
                    !message.string("content").isEmpty
                else { return nil }
                return ConversationTranscriptMessage(
                    id: message.string("id", fallback: UUID().uuidString),
                    role: message.string("role"),
                    content: ConversationQueueContent.visibleContent(fromStored: message.string("content")),
                    createdAt: message.date("createdAt"),
                    artifacts: (message["artifacts"] as? [[String: Any]] ?? []).compactMap { artifact in
                        let url = artifact.string("url")
                        guard !url.isEmpty else { return nil }
                        return ConversationArtifact(
                            type: artifact.string("type", fallback: "file"),
                            url: url,
                            title: artifact.string("title")
                        )
                    },
                    toolCalls: message.stringArray("toolCalls"),
                    providerID: message.string("providerId"),
                    model: message.string("model")
                )
            }
            return ConversationSummary(
                id: id,
                title: value.string("title", fallback: "未命名会话"),
                summary: value.string("summary"),
                updatedAt: value.date("updatedAt"),
                messageCount: transcript.count,
                messages: transcript,
                aiTitle: value.string("aiTitle"),
                aiSummary: value.string("aiSummary"),
                contextSummary: value.string("contextSummary"),
                archivedMessageCount: value.int("archivedMessageCount"),
                usage: Self.parseUsage(value["usage"]),
                lastChatUsage: Self.parseUsage(value["lastChatUsage"]),
                isPinned: value.bool("pinned")
            )
        }
        .sorted {
            if $0.isPinned != $1.isPinned { return $0.isPinned }
            return $0.updatedAt > $1.updatedAt
        }
    }

    private static func parseUsage(_ rawValue: Any?) -> ConversationUsage {
        let value = rawValue as? [String: Any] ?? [:]
        let rawTools = value["toolUsage"] as? [String: Any] ?? [:]
        let tools = rawTools.reduce(into: [String: Int]()) { result, entry in
            let count = max(0, Int((entry.value as? NSNumber)?.doubleValue ?? 0))
            if count > 0 { result[entry.key] = count }
        }
        return ConversationUsage(
            promptTokens: value.int("promptTokens"),
            completionTokens: value.int("completionTokens"),
            totalTokens: value.int("totalTokens"),
            cachedTokens: value.int("cachedTokens"),
            cacheCreationTokens: value.int("cacheCreationTokens"),
            reasoningTokens: value.int("reasoningTokens"),
            textTokens: value.int("textTokens"),
            toolCalls: value.int("toolCalls"),
            toolUsage: tools,
            exactRequests: value.int("exactRequests"),
            estimatedRequests: value.int("estimatedRequests"),
            cacheTrackedPromptTokens: value.int("cacheTrackedPromptTokens"),
            cacheSupported: value.bool("cacheSupported"),
            model: value.string("model")
        )
    }

    private func loadLearningRecords() -> [LearningRecord] {
        guard
            let root = jsonObject(named: "learning.json") as? [String: Any],
            let items = root["items"] as? [String: Any]
        else { return [] }

        return items.compactMap { id, rawValue in
            guard let value = rawValue as? [String: Any], value.bool("archived") == false else { return nil }
            return parseLearningRecord(value, fallbackID: id)
        }
    }

    private func parseLearningRecord(_ value: [String: Any], fallbackID: String) -> LearningRecord {
            let mastery = value["mastery"] as? [String: Any] ?? [:]
            let review = value["review"] as? [String: Any] ?? [:]
            let card = review["card"] as? [String: Any] ?? [:]
            let evidence = value["evidence"] as? [Any] ?? []
            let evidenceItems = evidence.compactMap { rawEvidence -> LearningEvidence? in
                guard let item = rawEvidence as? [String: Any] else { return nil }
                return LearningEvidence(
                    id: item.string("id", fallback: UUID().uuidString),
                    kind: item.string("type", fallback: "note"),
                    attemptID: item.string("attemptId"),
                    signal: item.string("signal", fallback: "neutral"),
                    summary: item.string("summary", fallback: "学习行为记录"),
                    observedAt: item.date("observedAt")
                )
            }
            let sourceRefs = (value["sourceRefs"] as? [Any] ?? []).compactMap { rawReference -> LearningSourceReference? in
                guard let reference = rawReference as? [String: Any] else { return nil }
                return LearningSourceReference(
                    conversationID: reference.string("conversationId"),
                    messageID: reference.string("messageId"),
                    excerpt: reference.string("excerpt")
                )
            }
            let study = value["study"] as? [String: Any] ?? [:]
            let packages = (study["packages"] as? [[String: Any]] ?? []).compactMap(parseStudyPackage)
            let activePackageID = study.string("activePackageId")
            let activePackage = packages.first(where: { $0.id == activePackageID }) ?? packages.last
            let attempts = (study["attempts"] as? [[String: Any]] ?? []).compactMap(parseLearningAttempt)
            let latestAttempt = attempts.max { $0.submittedAt < $1.submittedAt }
            let activePackageAttemptCount = activePackage.map { package in
                attempts.filter { $0.packageID == package.id }.count
            } ?? 0
            return LearningRecord(
                id: value.string("id", fallback: fallbackID),
                kind: value.string("kind", fallback: "problem"),
                canonicalKey: value.string("canonicalKey"),
                title: value.string("title", fallback: "未命名知识点"),
                question: value.string("question"),
                diagnosis: value.string("diagnosis"),
                labels: value.stringArray("labels"),
                prerequisiteLabels: value.stringArray("prerequisiteLabels"),
                knowledgePath: value.stringArray("knowledgePath"),
                masteryScore: mastery.double("score"),
                confidence: mastery.double("confidence"),
                evidenceCount: max(evidence.count, mastery.int("evidenceCount")),
                evidence: evidenceItems.sorted { $0.observedAt > $1.observedAt },
                sourceRefs: sourceRefs,
                language: value.string("language"),
                dueAt: card.date("due"),
                reviewCount: review.int("reviewCount"),
                stability: card.double("stability"),
                // 从没复习过时引擎写的是 null，这时没有遗忘曲线可算。
                lastReviewedAt: card.optionalDate("last_review"),
                activeStudyPackage: activePackage,
                latestAttempt: latestAttempt,
                activePackageAttemptCount: activePackageAttemptCount,
                updatedAt: value.date("updatedAt")
            )
    }

    private func parseStudyPackage(_ value: [String: Any]) -> LearningStudyPackage? {
        let lessonValue = value["lesson"] as? [String: Any] ?? [:]
        let exerciseValue = value["exercise"] as? [String: Any] ?? [:]
        let id = value.string("id")
        guard !id.isEmpty, !exerciseValue.string("prompt").isEmpty else { return nil }
        return LearningStudyPackage(
            id: id,
            lesson: LearningLesson(
                overview: lessonValue.string("overview"),
                keyPoints: lessonValue.stringArray("keyPoints"),
                pitfalls: lessonValue.stringArray("pitfalls"),
                example: lessonValue.string("example")
            ),
            exercise: LearningExercise(
                type: exerciseValue.string("type", fallback: "short_answer"),
                title: exerciseValue.string("title", fallback: "掌握度检测"),
                prompt: exerciseValue.string("prompt"),
                instructions: exerciseValue.string("instructions"),
                language: exerciseValue.string("language"),
                starterCode: exerciseValue.string("starterCode"),
                choices: exerciseValue.stringArray("choices"),
                examples: exerciseValue.stringArray("examples"),
                constraints: exerciseValue.stringArray("constraints"),
                rubric: exerciseValue.stringArray("rubric"),
                referenceAnswer: exerciseValue.string("referenceAnswer")
            ),
            generatedAt: value.date("generatedAt"),
            model: value.string("model")
        )
    }

    private func parseLearningAttempt(_ value: [String: Any]) -> LearningAttempt? {
        let id = value.string("id")
        guard !id.isEmpty else { return nil }
        return LearningAttempt(
            id: id,
            packageID: value.string("packageId"),
            answer: value.string("answer"),
            score: value.double("score"),
            verdict: value.string("verdict"),
            feedback: value.string("feedback"),
            strengths: value.stringArray("strengths"),
            gaps: value.stringArray("gaps"),
            nextStep: value.string("nextStep"),
            submittedAt: value.date("submittedAt")
        )
    }

    private func loadLearningExtras() {
        guard let root = jsonObject(named: "learning.json") as? [String: Any] else {
            deletedLearningRecords = []
            learningTemplates = []
            learningSettings = LearningSettingsSnapshot()
            return
        }

        let rawSettings = root["settings"] as? [String: Any] ?? [:]
        learningSettings = LearningSettingsSnapshot(
            dailyNewTarget: min(12, max(0, rawSettings.int("dailyNewTarget", fallback: 3))),
            weekdayReviewTarget: min(30, max(0, rawSettings.int("weekdayReviewTarget", fallback: 4))),
            weeklyReviewDay: min(6, max(0, rawSettings.int("weeklyReviewDay", fallback: 0))),
            weeklyReviewTarget: min(60, max(0, rawSettings.int("weeklyReviewTarget", fallback: 12))),
            preferredLanguage: rawSettings.string("preferredLanguage", fallback: "java")
        )

        let deleted = root["deletedItems"] as? [String: Any] ?? [:]
        deletedLearningRecords = deleted.compactMap { id, rawValue in
            guard let value = rawValue as? [String: Any] else { return nil }
            let snapshot = value["snapshot"] as? [String: Any] ?? value
            return parseLearningRecord(snapshot, fallbackID: id)
        }

        let templates = root["templates"] as? [String: Any] ?? [:]
        learningTemplates = templates.compactMap { key, rawValue in
            guard let value = rawValue as? [String: Any] else { return nil }
            return LearningTemplate(
                id: value.string("key", fallback: key),
                title: value.string("title", fallback: "未命名模板"),
                path: value.stringArray("path"),
                language: value.string("language"),
                summary: value.string("summary"),
                applicableWhen: value.stringArray("applicableWhen"),
                steps: value.stringArray("steps"),
                pitfalls: value.stringArray("pitfalls"),
                code: value.string("code"),
                itemCount: value.int("itemCount"),
                generatedAt: value.date("generatedAt")
            )
        }
        .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    private func loadSettings() {
        guard let root = jsonObject(named: "settings.json") as? [String: Any] else { return }
        let policy = root["contextPolicy"] as? [String: Any] ?? [:]
        let taskModels = root["taskModels"] as? [String: Any] ?? [:]
        settings = LegacySettingsSnapshot(
            activeProviderID: root.string("activeProvider", fallback: "deepseek"),
            reasoningEffort: root.string("reasoningEffort", fallback: "high"),
            alwaysOnTop: root.bool("alwaysOnTop"),
            videoAutoplay: root.bool("videoAutoplay", fallback: true),
            appearance: root.string("appearance", fallback: "system"),
            emphasizeMotion: root.bool("emphasizeMotion", fallback: true),
            contextWindowTokens: policy.double("contextWindowTokens", fallback: 128_000),
            reservedOutputTokens: policy.double("reservedOutputTokens", fallback: 8_192),
            compressionThreshold: policy.double("compressionThreshold", fallback: 0.95),
            postCompressionRatio: policy.double("postCompressionRatio", fallback: 0.82),
            recentMessages: policy.double("recentMessages", fallback: 12),
            maxImages: policy.double("maxImages", fallback: 4),
            taskRoutes: taskModels.reduce(into: [:]) { result, entry in
                guard let route = entry.value as? [String: Any] else { return }
                let providerID = route.string("providerId")
                guard !providerID.isEmpty else { return }
                result[entry.key] = providerID
            }
        )

        let providerDictionary = root["providers"] as? [String: Any] ?? [:]
        let order = root.stringArray("providerOrder")
        providers = order.compactMap { id in
            guard let provider = providerDictionary[id] as? [String: Any] else { return nil }
            let assetName: String? = switch id {
            case "deepseek": "deepseek"
            case "alibaba": "alibaba-cloud"
            case "opencode-go": "opencode"
            default: nil
            }
            return ProviderRecord(
                id: id,
                name: provider.string("name", fallback: id),
                assetName: assetName,
                model: provider.string("model"),
                apiBase: provider.string("apiBase"),
                mode: provider.string("resolvedMode", fallback: provider.string("apiMode", fallback: "auto")),
                isConfigured: !provider.string("apiKey").isEmpty
            )
        }
    }

    private func loadLeetCode() {
        guard let root = jsonObject(named: "leetcode-cn.json") as? [String: Any] else {
            leetCodeProfile = .empty
            leetCodeSubmissions = []
            leetCodeActivity = []
            leetCodePlans = []
            activeLeetCodePlanID = ""
            leetCodeQuestions = []
            leetCodeWorkspaces = [:]
            leetCodeSubmissionDetails = [:]
            leetCodeAnalysisTasks = [:]
            leetCodeAnalyses = [:]
            return
        }
        let account = root["account"] as? [String: Any] ?? [:]
        leetCodeUsername = account.string("realName", fallback: account.string("username"))
        leetCodeSignedIn = account.bool("signedIn")
        leetCodeProfile = LeetCodeProfile(
            username: account.string("username"),
            displayName: account.string("realName", fallback: account.string("username")),
            avatarURL: URL(string: account.string("avatar")),
            avatarData: Self.decodeDataURL(account.string("avatarData")),
            isPremium: account.bool("isPremium")
        )

        let rawSubmissions = root["submissions"] as? [[String: Any]] ?? []
        leetCodeSubmissions = rawSubmissions.compactMap { submission in
            let submittedAt = submission.date("submittedAt")
            guard submittedAt != .distantPast else { return nil }
            return LeetCodeSubmission(
                id: submission.string("id", fallback: UUID().uuidString),
                titleSlug: submission.string("titleSlug"),
                title: submission.string("translatedTitle", fallback: submission.string("title")),
                frontendID: submission.string("frontendId"),
                language: submission.string("lang"),
                accepted: submission.bool("accepted"),
                submittedAt: submittedAt,
                activityType: submission.string("activityType"),
                status: submission.string("statusDisplay"),
                runtime: submission.string("runtime"),
                memory: submission.string("memory"),
                url: submission.string("url")
            )
        }
        .sorted { $0.submittedAt < $1.submittedAt }

        let calendar = Calendar.current
        let groupedActivity = Dictionary(grouping: leetCodeSubmissions) {
            calendar.startOfDay(for: $0.submittedAt)
        }
        leetCodeActivity = groupedActivity.map { date, submissions in
            LeetCodeActivityDay(
                date: date,
                submissionCount: submissions.count,
                acceptedCount: submissions.lazy.filter(\.accepted).count
            )
        }
        .sorted { $0.date < $1.date }

        let plans = root["plans"] as? [String: Any] ?? [:]
        activeLeetCodePlanID = root.string("activePlanSlug")
        // 题单进度必须和题库页同一口径：用本地提交记录现算。
        // 存盘里的 status 是拉取题单那天的快照，做完题也不会更新，
        // 之前 solvedCount 永远停在 0 就是这个原因。
        let acceptedSlugs = Set(leetCodeSubmissions.lazy.filter(\.accepted).map(\.titleSlug))
        leetCodePlans = plans.compactMap { id, rawValue in
            guard let value = rawValue as? [String: Any] else { return nil }
            let questions = value["questions"] as? [[String: Any]] ?? []
            return LeetCodePlanSummary(
                id: id,
                name: value.string("name", fallback: id),
                questionCount: questions.count,
                solvedCount: questions.lazy.filter {
                    acceptedSlugs.contains($0.string("titleSlug")) || $0.string("status") == "SOLVED"
                }.count
            )
        }
        .sorted { $0.name < $1.name }

        let activePlan = plans[activeLeetCodePlanID] as? [String: Any]
        let rawQuestions = activePlan?["questions"] as? [[String: Any]] ?? []
        let submissionsBySlug = Dictionary(grouping: leetCodeSubmissions, by: \.titleSlug)
        leetCodeQuestions = rawQuestions.compactMap { question in
            let slug = question.string("titleSlug")
            guard !slug.isEmpty else { return nil }
            let submissions = submissionsBySlug[slug] ?? []
            let acceptedCount = submissions.lazy.filter(\.accepted).count
            let status = acceptedCount > 0 ? "SOLVED" : (!submissions.isEmpty ? "TRIED" : question.string("status", fallback: "TO_DO"))
            let tags = (question["topicTags"] as? [[String: Any]] ?? []).compactMap { tag -> String? in
                let value = tag.string("translatedName", fallback: tag.string("name"))
                return value.isEmpty ? nil : value
            }
            let rate = question["acRate"] as? Double ?? (question["acRate"] as? NSNumber)?.doubleValue
            return LeetCodeQuestion(
                titleSlug: slug,
                frontendID: question.string("frontendId", fallback: question.string("questionFrontendId")),
                title: question.string("translatedTitle", fallback: question.string("title")),
                difficulty: question.string("difficulty", fallback: "MEDIUM"),
                status: status,
                paidOnly: question.bool("paidOnly"),
                acceptanceRate: rate,
                groupName: question.string("groupName"),
                topicTags: tags,
                submissionCount: submissions.count,
                acceptedCount: acceptedCount,
                lastSubmittedAt: submissions.max(by: { $0.submittedAt < $1.submittedAt })?.submittedAt
            )
        }
        loadLeetCodeAnalysis(root["analysis"] as? [String: Any] ?? [:])
        loadLeetCodeContent()
    }

    private func loadLeetCodeAnalysis(_ value: [String: Any]) {
        let queue = value["queue"] as? [String: Any] ?? [:]
        leetCodeAnalysisTasks = queue.reduce(into: [:]) { result, entry in
            guard let raw = entry.value as? [String: Any] else { return }
            let ids = raw.stringArray("submissionIds")
            guard !ids.isEmpty else { return }
            result[entry.key] = LeetCodeAnalysisTask(
                titleSlug: entry.key,
                submissionIDs: ids,
                queuedAt: raw.date("queuedAt"),
                attempts: raw.int("attempts"),
                nextAttemptAt: raw.date("nextAttemptAt"),
                lastAttemptAt: raw.date("lastAttemptAt"),
                lastError: raw.string("lastError"),
                failedSubmissionAttempts: (raw["failedSubmissionAttempts"] as? [String: Any] ?? [:])
                    .mapValues { ($0 as? NSNumber)?.intValue ?? 0 }
            )
        }

        let records = value["records"] as? [String: Any] ?? [:]
        leetCodeAnalyses = records.reduce(into: [:]) { result, entry in
            guard let raw = entry.value as? [String: Any] else { return }
            let insights = (raw["attemptInsights"] as? [[String: Any]] ?? []).compactMap { item -> LeetCodeAttemptInsight? in
                let id = item.string("submissionId")
                guard !id.isEmpty else { return nil }
                return LeetCodeAttemptInsight(
                    submissionID: id,
                    issue: item.string("issue"),
                    change: item.string("change"),
                    outcome: item.string("outcome")
                )
            }
            let rawSnapshots = raw["submissionAnalyses"] as? [String: Any] ?? [:]
            let snapshots = rawSnapshots.reduce(into: [String: LeetCodeSubmissionAnalysis]()) { snapshotResult, snapshotEntry in
                guard let item = snapshotEntry.value as? [String: Any] else { return }
                snapshotResult[snapshotEntry.key] = LeetCodeSubmissionAnalysis(
                    summary: item.string("summary"),
                    rootCause: item.string("rootCause"),
                    evidence: item.stringArray("evidence"),
                    suggestions: item.stringArray("suggestions"),
                    knowledgeGaps: item.stringArray("knowledgeGaps"),
                    updatedAt: item.date("updatedAt")
                )
            }
            result[entry.key] = LeetCodeTrajectoryAnalysis(
                titleSlug: entry.key,
                summary: raw.string("summary"),
                weaknesses: raw.stringArray("weaknesses"),
                improvements: raw.stringArray("improvements"),
                attemptInsights: insights,
                submissionAnalyses: snapshots,
                analyzedSubmissionIDs: raw.stringArray("analyzedSubmissionIds"),
                latestSubmissionAt: raw.date("latestSubmissionAt"),
                updatedAt: raw.date("summaryUpdatedAt") == .distantPast ? raw.date("updatedAt") : raw.date("summaryUpdatedAt")
            )
        }
    }

    private func loadLeetCodeContent() {
        guard let root = jsonObject(named: "leetcode-content.json") as? [String: Any] else {
            leetCodeWorkspaces = [:]
            leetCodeSubmissionDetails = [:]
            return
        }
        let rawWorkspaces = root["workspaces"] as? [String: Any] ?? [:]
        leetCodeWorkspaces = rawWorkspaces.reduce(into: [:]) { result, entry in
            guard let wrapper = entry.value as? [String: Any],
                  let value = wrapper["value"] as? [String: Any],
                  let question = value["question"] as? [String: Any]
            else { return }
            let snippets = (value["snippets"] as? [[String: Any]] ?? []).compactMap { snippet -> LeetCodeCodeSnippet? in
                let slug = snippet.string("langSlug")
                guard !slug.isEmpty else { return nil }
                return LeetCodeCodeSnippet(language: snippet.string("lang", fallback: slug), languageSlug: slug, code: snippet.string("code"))
            }
            let tags = (question["topicTags"] as? [[String: Any]] ?? []).compactMap { tag -> String? in
                let value = tag.string("name", fallback: tag.string("translatedName"))
                return value.isEmpty ? nil : value
            }
            let sampleCases = question["exampleTestcases"] as? [String]
                ?? question.string("sampleTestCase").split(separator: "\n\n").map(String.init)
            result[entry.key] = LeetCodeQuestionWorkspace(
                titleSlug: entry.key,
                questionID: question.string("questionId"),
                htmlContent: question.string("content", fallback: question.string("translatedContent")),
                difficulty: question.string("difficulty"),
                topicTags: tags,
                sampleTestCases: sampleCases,
                snippets: snippets,
                canRun: question.bool("enableRunCode"),
                canSubmit: question.bool("enableSubmit")
            )
        }

        let rawDetails = root["submissionDetails"] as? [String: Any] ?? [:]
        leetCodeSubmissionDetails = rawDetails.reduce(into: [:]) { result, entry in
            guard let wrapper = entry.value as? [String: Any],
                  let detail = wrapper["detail"] as? [String: Any]
            else { return }
            result[entry.key] = LeetCodeSubmissionDetail(
                id: entry.key,
                titleSlug: detail.string("titleSlug"),
                code: detail.string("code"),
                language: detail.string("lang"),
                status: detail.string("statusDisplay"),
                runtime: detail.string("runtime"),
                memory: detail.string("memory"),
                runtimePercentile: (detail["runtimePercentile"] as? NSNumber)?.doubleValue,
                memoryPercentile: (detail["memoryPercentile"] as? NSNumber)?.doubleValue,
                runtimeError: detail.string("runtimeError"),
                compileError: detail.string("compileError"),
                lastTestCase: detail.string("lastTestcase"),
                actualOutput: detail.string("codeOutput"),
                expectedOutput: detail.string("expectedOutput"),
                correctCaseCount: detail.int("totalCorrect"),
                totalCaseCount: detail.int("totalTestcases")
            )
        }
    }

    private static func decodeDataURL(_ value: String) -> Data? {
        guard let comma = value.firstIndex(of: ",") else { return nil }
        let encoded = String(value[value.index(after: comma)...])
        return Data(base64Encoded: encoded)
    }
}

private enum ConversationStoreError: LocalizedError {
    case missingConversation
    case missingProvider
    case missingLearningRecord
    case invalidTitle
    case invalidLearningSettings
    case invalidTaskRoute

    var errorDescription: String? {
        switch self {
        case .missingConversation: "会话已不存在，请新建会话后重试"
        case .missingProvider: "供应商配置已不存在"
        case .missingLearningRecord: "学习记录已不存在"
        case .invalidTitle: "任务标题不能为空"
        case .invalidLearningSettings: "学习设置超出可用范围"
        case .invalidTaskRoute: "任务模型路由不存在"
        }
    }
}

private extension Dictionary where Key == String, Value == Any {
    func string(_ key: String, fallback: String = "") -> String {
        self[key] as? String ?? fallback
    }

    func stringArray(_ key: String) -> [String] {
        self[key] as? [String] ?? []
    }

    func bool(_ key: String, fallback: Bool = false) -> Bool {
        self[key] as? Bool ?? fallback
    }

    func double(_ key: String, fallback: Double = 0) -> Double {
        (self[key] as? NSNumber)?.doubleValue ?? fallback
    }

    func int(_ key: String, fallback: Int = 0) -> Int {
        (self[key] as? NSNumber)?.intValue ?? fallback
    }

    func date(_ key: String) -> Date {
        let milliseconds = double(key)
        return milliseconds > 0 ? Date(timeIntervalSince1970: milliseconds / 1_000) : .distantPast
    }

    /// 缺字段、写成 null、写成 0 都算「没有这个时间」，而不是 1970 年。
    /// 遗忘曲线拿 `.distantPast` 当上次复习时间会直接算出"全忘光了"。
    func optionalDate(_ key: String) -> Date? {
        let milliseconds = double(key)
        return milliseconds > 0 ? Date(timeIntervalSince1970: milliseconds / 1_000) : nil
    }
}
