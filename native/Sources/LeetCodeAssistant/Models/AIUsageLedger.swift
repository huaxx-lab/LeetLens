import Foundation

enum AIUsageOutcome: String, Codable, Sendable {
    case succeeded
    case failed
    case cancelled
}

struct AIUsageCounters: Codable, Hashable, Sendable {
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
    var succeededRequests = 0
    var failedRequests = 0
    var cancelledRequests = 0
    var durationMilliseconds = 0
    var model = ""

    var requestCount: Int { succeededRequests + failedRequests + cancelledRequests }

    mutating func merge(
        usage: ConversationUsage,
        outcome: AIUsageOutcome,
        durationMilliseconds: Int
    ) {
        promptTokens += usage.promptTokens
        completionTokens += usage.completionTokens
        totalTokens += usage.totalTokens
        cachedTokens += usage.cachedTokens
        cacheCreationTokens += usage.cacheCreationTokens
        reasoningTokens += usage.reasoningTokens
        textTokens += usage.textTokens
        toolCalls += usage.toolCalls
        usage.toolUsage.forEach { toolUsage[$0.key, default: 0] += $0.value }
        exactRequests += usage.exactRequests
        estimatedRequests += usage.estimatedRequests
        cacheTrackedPromptTokens += usage.cacheTrackedPromptTokens
        cacheSupported = cacheSupported || usage.cacheSupported
        self.durationMilliseconds += max(0, durationMilliseconds)
        if !usage.model.isEmpty { model = usage.model }
        switch outcome {
        case .succeeded: succeededRequests += 1
        case .failed: failedRequests += 1
        case .cancelled: cancelledRequests += 1
        }
    }

    var conversationUsage: ConversationUsage {
        ConversationUsage(
            promptTokens: promptTokens,
            completionTokens: completionTokens,
            totalTokens: totalTokens,
            cachedTokens: cachedTokens,
            cacheCreationTokens: cacheCreationTokens,
            reasoningTokens: reasoningTokens,
            textTokens: textTokens,
            toolCalls: toolCalls,
            toolUsage: toolUsage,
            exactRequests: exactRequests,
            estimatedRequests: estimatedRequests,
            cacheTrackedPromptTokens: cacheTrackedPromptTokens,
            cacheSupported: cacheSupported,
            model: model
        )
    }
}

struct AIUsageSnapshot: Hashable, Sendable {
    var totals = AIUsageCounters()
    var byTask: [String: AIUsageCounters] = [:]
    var byConversation: [String: AIUsageCounters] = [:]
    var byProvider: [String: AIUsageCounters] = [:]
    /// Keyed by `providerID\u{1F}model` to avoid cross-provider model-name collisions.
    var byModel: [String: AIUsageCounters] = [:]
    var updatedAt = Date.distantPast

    static let empty = AIUsageSnapshot()
}

private struct AIUsageDocument: Codable, Sendable {
    var version = 2
    var totals = AIUsageCounters()
    var byTask: [String: AIUsageCounters] = [:]
    var byConversation: [String: AIUsageCounters] = [:]
    var byProvider: [String: AIUsageCounters] = [:]
    var byModel: [String: AIUsageCounters] = [:]
    var updatedAt = Date.distantPast

    private enum CodingKeys: String, CodingKey {
        case version, totals, byTask, byConversation, byProvider, byModel, updatedAt
    }

    init() {}

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        version = try values.decodeIfPresent(Int.self, forKey: .version) ?? 1
        totals = try values.decodeIfPresent(AIUsageCounters.self, forKey: .totals) ?? AIUsageCounters()
        byTask = try values.decodeIfPresent([String: AIUsageCounters].self, forKey: .byTask) ?? [:]
        byConversation = try values.decodeIfPresent([String: AIUsageCounters].self, forKey: .byConversation) ?? [:]
        byProvider = try values.decodeIfPresent([String: AIUsageCounters].self, forKey: .byProvider) ?? [:]
        byModel = try values.decodeIfPresent([String: AIUsageCounters].self, forKey: .byModel) ?? [:]
        updatedAt = try values.decodeIfPresent(Date.self, forKey: .updatedAt) ?? .distantPast
    }
}

struct AIUsageEntry: Sendable {
    let taskRoute: AITaskRoute
    let conversationID: String?
    let providerID: String
    let usage: ConversationUsage
    let outcome: AIUsageOutcome
    let durationMilliseconds: Int

    func withOutcome(_ outcome: AIUsageOutcome) -> Self {
        Self(
            taskRoute: taskRoute,
            conversationID: conversationID,
            providerID: providerID,
            usage: usage,
            outcome: outcome,
            durationMilliseconds: durationMilliseconds
        )
    }
}

/// Structured callers validate JSON and semantics after the transport finishes. This one-shot
/// holder delays the ledger write until that validation boundary without allowing duplicate
/// success + failure entries for a single network request.
actor DeferredAIUsageAccounting {
    private var entry: AIUsageEntry?
    private var isCommitted = false

    func stage(_ entry: AIUsageEntry) {
        guard !isCommitted else { return }
        self.entry = entry
    }

    func commit(outcome: AIUsageOutcome, dataDirectory: URL) async {
        guard !isCommitted, let entry else { return }
        isCommitted = true
        self.entry = nil
        await AIUsageLedger.shared.record(entry.withOutcome(outcome), dataDirectory: dataDirectory)
    }

    func commitIfStaged(outcome: AIUsageOutcome, dataDirectory: URL) async -> Bool {
        guard !isCommitted, let entry else { return false }
        isCommitted = true
        self.entry = nil
        await AIUsageLedger.shared.record(entry.withOutcome(outcome), dataDirectory: dataDirectory)
        return true
    }

}

extension Notification.Name {
    static let aiUsageLedgerDidChange = Notification.Name("aiUsageLedgerDidChange")
}

/// Single accounting boundary for every native model request. The ledger stores
/// aggregates only; prompts, answers, API keys and provider endpoints never leave
/// the request pipeline.
actor AIUsageLedger {
    static let shared = AIUsageLedger()

    private var documents: [String: AIUsageDocument] = [:]
    private var pendingWrites: [String: Int] = [:]
    private var lastCheckpoint: [String: Date] = [:]

    /// Checkpoint budgets: whichever comes first.
    private static let checkpointEntryBudget = 20
    private static let checkpointInterval: TimeInterval = 30

    static func modelBucketKey(providerID: String, model: String) -> String {
        providerID + "\u{1F}" + model
    }

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = .current
        return formatter
    }()

    func record(_ entry: AIUsageEntry, dataDirectory: URL) async {
        let key = dataDirectory.standardizedFileURL.path
        var document = documents[key] ?? loadDocument(dataDirectory: dataDirectory)
        document.totals.merge(
            usage: entry.usage,
            outcome: entry.outcome,
            durationMilliseconds: entry.durationMilliseconds
        )
        var task = document.byTask[entry.taskRoute.rawValue] ?? AIUsageCounters()
        task.merge(
            usage: entry.usage,
            outcome: entry.outcome,
            durationMilliseconds: entry.durationMilliseconds
        )
        document.byTask[entry.taskRoute.rawValue] = task
        if let conversationID = entry.conversationID, !conversationID.isEmpty {
            var conversation = document.byConversation[conversationID] ?? AIUsageCounters()
            conversation.merge(
                usage: entry.usage,
                outcome: entry.outcome,
                durationMilliseconds: entry.durationMilliseconds
            )
            document.byConversation[conversationID] = conversation
        }
        if !entry.providerID.isEmpty {
            var provider = document.byProvider[entry.providerID] ?? AIUsageCounters()
            provider.merge(
                usage: entry.usage,
                outcome: entry.outcome,
                durationMilliseconds: entry.durationMilliseconds
            )
            document.byProvider[entry.providerID] = provider
        }
        if !entry.usage.model.isEmpty {
            let modelKey = Self.modelBucketKey(providerID: entry.providerID, model: entry.usage.model)
            var model = document.byModel[modelKey] ?? AIUsageCounters()
            model.merge(
                usage: entry.usage,
                outcome: entry.outcome,
                durationMilliseconds: entry.durationMilliseconds
            )
            document.byModel[modelKey] = model
        }
        document.updatedAt = .now
        documents[key] = document

        // 在任何 await 前先登记脏状态。actor 在 Redis 等待期间可以重入；若之后拿着
        // 当前调用的局部 document 落盘，会把重入期间新增的 usage 覆盖掉。
        let checkpointDue = markPendingAndCheckBudget(key: key)

        // O(1) shared counters. Redis is authoritative for nothing here — it just means
        // both clients agree on running totals without either one rewriting a file.
        await publishCounters(entry)

        // 每次都从 actor 当前状态取最新 document；只有成功写盘后才清脏标记。
        if checkpointDue {
            checkpointCurrent(key: key, dataDirectory: dataDirectory)
        }
        await MainActor.run {
            NotificationCenter.default.post(name: .aiUsageLedgerDidChange, object: key)
        }
    }

    /// Flushes any pending in-memory aggregate. Call on quit or when the UI needs disk
    /// state to be current.
    func flush(dataDirectory: URL) {
        let key = dataDirectory.standardizedFileURL.path
        guard pendingWrites[key] ?? 0 > 0 else { return }
        checkpointCurrent(key: key, dataDirectory: dataDirectory)
    }

    /// Checkpoints on a count or time budget, so a crash loses at most a few entries.
    /// 这里只判断是否到预算，不提前清 pending；落盘成功才算真正 checkpoint。
    private func markPendingAndCheckBudget(key: String) -> Bool {
        let pending = (pendingWrites[key] ?? 0) + 1
        pendingWrites[key] = pending
        let elapsed = Date.now.timeIntervalSince(lastCheckpoint[key] ?? .distantPast)
        return pending >= Self.checkpointEntryBudget || elapsed >= Self.checkpointInterval
    }

    private func checkpointCurrent(key: String, dataDirectory: URL) {
        guard let current = documents[key] else { return }
        do {
            try persist(current, dataDirectory: dataDirectory)
            // 只有刚写的仍是最新版本才能清零；写盘期间 actor 不会 await，状态不会重入改变。
            pendingWrites[key] = 0
            lastCheckpoint[key] = .now
        } catch {
            // 保留 pending，下一次 record/flush 会继续重试。
        }
    }

    private func publishCounters(_ entry: AIUsageEntry) async {
        let client = RedisClient.shared
        let usage = entry.usage
        let fields: [(String, Int)] = [
            ("prompt_tokens", usage.promptTokens),
            ("completion_tokens", usage.completionTokens),
            ("total_tokens", usage.totalTokens),
            ("cached_tokens", usage.cachedTokens),
            ("reasoning_tokens", usage.reasoningTokens),
            ("requests", 1),
            ("duration_ms", entry.durationMilliseconds)
        ]
        let day = Self.dayFormatter.string(from: .now)
        var increments: [(key: String, field: String, by: Int)] = []
        for (field, amount) in fields where amount != 0 {
            increments.append((key: "usage:v1:totals", field: field, by: amount))
            increments.append((key: "usage:v1:task:\(entry.taskRoute.rawValue)", field: field, by: amount))
            increments.append((key: "usage:v1:day:\(day)", field: field, by: amount))
            if !entry.providerID.isEmpty {
                increments.append((key: "usage:v2:provider:\(entry.providerID)", field: field, by: amount))
            }
            if !entry.usage.model.isEmpty {
                let modelKey = Self.modelBucketKey(providerID: entry.providerID, model: entry.usage.model)
                increments.append((key: "usage:v2:model:\(modelKey)", field: field, by: amount))
            }
        }
        await client.incrementCounters(increments, ttl: 60 * 60 * 24 * 400)
    }

    func snapshot(dataDirectory: URL) -> AIUsageSnapshot {
        let key = dataDirectory.standardizedFileURL.path
        let document = documents[key] ?? loadDocument(dataDirectory: dataDirectory)
        documents[key] = document
        return Self.snapshot(from: document)
    }

    /// Decodes the persisted aggregate without populating the actor cache. Tests use this
    /// to exercise v1 migration fixtures in isolation from prior snapshots for the same path.
    static func decodeSnapshot(_ data: Data) throws -> AIUsageSnapshot {
        snapshot(from: try JSONDecoder().decode(AIUsageDocument.self, from: data))
    }

    private static func snapshot(from document: AIUsageDocument) -> AIUsageSnapshot {
        AIUsageSnapshot(
            totals: document.totals,
            byTask: document.byTask,
            byConversation: document.byConversation,
            byProvider: document.byProvider,
            byModel: document.byModel,
            updatedAt: document.updatedAt
        )
    }

    private func loadDocument(dataDirectory: URL) -> AIUsageDocument {
        let url = dataDirectory.appending(path: "ai-usage.json")
        guard let data = try? Data(contentsOf: url),
              let document = try? JSONDecoder().decode(AIUsageDocument.self, from: data)
        else { return AIUsageDocument() }
        return document
    }

    private func persist(_ document: AIUsageDocument, dataDirectory: URL) throws {
        try FileManager.default.createDirectory(
            at: dataDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let url = dataDirectory.appending(path: "ai-usage.json")
        let data = try JSONEncoder().encode(document)
        try data.write(to: url, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}

struct AIProviderUsageAccumulator: Sendable {
    private(set) var usage = ConversationUsage()
    private(set) var hasExactUsage = false

    mutating func merge(_ incoming: ConversationUsage) {
        // Some compatible providers send `usage: {}` or cache/tool-only fragments. Those
        // packets do not establish request token totals and must not suppress estimation.
        usage.hasReportedPromptTokens = usage.hasReportedPromptTokens || incoming.hasReportedPromptTokens
        usage.hasReportedCompletionTokens = usage.hasReportedCompletionTokens || incoming.hasReportedCompletionTokens
        usage.hasReportedTotalTokens = usage.hasReportedTotalTokens || incoming.hasReportedTotalTokens
        hasExactUsage = usage.hasReportedTotalTokens
            || (usage.hasReportedPromptTokens && usage.hasReportedCompletionTokens)
        usage.promptTokens = max(usage.promptTokens, incoming.promptTokens)
        usage.completionTokens = max(usage.completionTokens, incoming.completionTokens)
        usage.totalTokens = max(usage.totalTokens, incoming.totalTokens)
        usage.cachedTokens = max(usage.cachedTokens, incoming.cachedTokens)
        usage.cacheCreationTokens = max(usage.cacheCreationTokens, incoming.cacheCreationTokens)
        usage.reasoningTokens = max(usage.reasoningTokens, incoming.reasoningTokens)
        usage.textTokens = max(usage.textTokens, incoming.textTokens)
        usage.cacheTrackedPromptTokens = max(usage.cacheTrackedPromptTokens, incoming.cacheTrackedPromptTokens)
        usage.cacheSupported = usage.cacheSupported || incoming.cacheSupported
        if !incoming.model.isEmpty { usage.model = incoming.model }
        incoming.toolUsage.forEach { usage.toolUsage[$0.key] = max(usage.toolUsage[$0.key] ?? 0, $0.value) }
        usage.toolCalls = max(usage.toolCalls, incoming.toolCalls)
    }

    func resolved(
        model: String,
        estimatedPromptTokens: Int,
        outputText: String,
        reasoningText: String,
        observedTools: [String: Int]
    ) -> ConversationUsage {
        var result = usage
        result.model = result.model.isEmpty ? model : result.model
        observedTools.forEach { result.toolUsage[$0.key, default: 0] = max(result.toolUsage[$0.key] ?? 0, $0.value) }
        result.toolCalls = max(result.toolCalls, observedTools.values.reduce(0, +))
        if hasExactUsage {
            result.exactRequests = 1
            result.cacheTrackedPromptTokens = max(
                result.cacheTrackedPromptTokens,
                result.cacheSupported ? result.promptTokens : 0
            )
            result.totalTokens = max(result.totalTokens, result.promptTokens + result.completionTokens)
            return result
        }
        result.promptTokens = estimatedPromptTokens
        result.completionTokens = AITokenEstimator.estimate(outputText + reasoningText)
        result.reasoningTokens = AITokenEstimator.estimate(reasoningText)
        result.textTokens = AITokenEstimator.estimate(outputText)
        result.totalTokens = result.promptTokens + result.completionTokens
        result.estimatedRequests = 1
        return result
    }
}

enum AITokenEstimator {
    static func estimate(messages: [ChatRequestMessage]) -> Int {
        max(1, messages.reduce(0) { $0 + estimate($1.role) + estimate($1.content) + 4 })
    }

    static func estimate(_ text: String) -> Int {
        guard !text.isEmpty else { return 0 }
        var ascii = 0
        var nonASCII = 0
        for scalar in text.unicodeScalars {
            if scalar.isASCII { ascii += 1 } else { nonASCII += 1 }
        }
        return max(1, Int(ceil(Double(ascii) / 4.0)) + nonASCII)
    }
}
