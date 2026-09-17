import Foundation

/// 一轮生成的持久化边界。恢复语义不是“从半个 token 续流”，而是从同一 user turn
/// 重新执行整轮，并复用 assistantMessageID；这样 provider 的消息交替与 tool_call_id
/// 配对始终有效。当前 agent tools 全是只读查询，重放不会重复外部写操作。
struct ConversationRunCheckpoint: Codable, Equatable, Sendable {
    enum Phase: String, Codable, Sendable {
        case preparing
        case streaming
        case toolCompleted
        case interrupted
    }

    let threadID: String
    let runID: String
    let userMessageID: String
    let assistantMessageID: String
    /// 本轮开始时 ledger 的 sequence 水位线。恢复时只把**此后**同 assistantID 的
    /// upsert 当成“本轮已经提交”，不会把上一次失败留下的 partial 误认成成功。
    let ledgerSequenceAtStart: Int
    var phase: Phase
    var partialContent: String
    var partialReasoning: String
    var toolCalls: [String]
    var agentRuns: [AgentToolRun]
    /// 发送瞬间冻结的宿主上下文 / 连续性说明；恢复时复用，不重新读可能已经变化的编辑器。
    let volatileContextPrompts: [String]
    let providerID: String
    let model: String
    let startedAt: Date
    var updatedAt: Date

    private enum CodingKeys: String, CodingKey {
        case threadID, runID, userMessageID, assistantMessageID, ledgerSequenceAtStart
        case phase, partialContent, partialReasoning, toolCalls, agentRuns, volatileContextPrompts
        case providerID, model, startedAt, updatedAt
    }

    init(
        threadID: String,
        runID: String,
        userMessageID: String,
        assistantMessageID: String,
        ledgerSequenceAtStart: Int,
        phase: Phase,
        partialContent: String,
        partialReasoning: String,
        toolCalls: [String],
        agentRuns: [AgentToolRun],
        volatileContextPrompts: [String],
        providerID: String,
        model: String,
        startedAt: Date,
        updatedAt: Date
    ) {
        self.threadID = threadID
        self.runID = runID
        self.userMessageID = userMessageID
        self.assistantMessageID = assistantMessageID
        self.ledgerSequenceAtStart = ledgerSequenceAtStart
        self.phase = phase
        self.partialContent = partialContent
        self.partialReasoning = partialReasoning
        self.toolCalls = toolCalls
        self.agentRuns = agentRuns
        self.volatileContextPrompts = volatileContextPrompts
        self.providerID = providerID
        self.model = model
        self.startedAt = startedAt
        self.updatedAt = updatedAt
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        threadID = try values.decode(String.self, forKey: .threadID)
        runID = try values.decode(String.self, forKey: .runID)
        userMessageID = try values.decode(String.self, forKey: .userMessageID)
        assistantMessageID = try values.decode(String.self, forKey: .assistantMessageID)
        ledgerSequenceAtStart = try values.decodeIfPresent(Int.self, forKey: .ledgerSequenceAtStart) ?? 0
        phase = try values.decode(Phase.self, forKey: .phase)
        partialContent = try values.decodeIfPresent(String.self, forKey: .partialContent) ?? ""
        partialReasoning = try values.decodeIfPresent(String.self, forKey: .partialReasoning) ?? ""
        toolCalls = try values.decodeIfPresent([String].self, forKey: .toolCalls) ?? []
        agentRuns = try values.decodeIfPresent([AgentToolRun].self, forKey: .agentRuns) ?? []
        volatileContextPrompts = try values.decodeIfPresent([String].self, forKey: .volatileContextPrompts) ?? []
        providerID = try values.decode(String.self, forKey: .providerID)
        model = try values.decodeIfPresent(String.self, forKey: .model) ?? ""
        startedAt = try values.decode(Date.self, forKey: .startedAt)
        updatedAt = try values.decode(Date.self, forKey: .updatedAt)
    }

    var canResume: Bool {
        !threadID.isEmpty && !runID.isEmpty && !userMessageID.isEmpty && !assistantMessageID.isEmpty
    }

    /// 本轮开始以后若 ledger 已追加同 assistantID 的 upsert，答案已经提交；
    /// 即使来不及删 checkpoint，也不该再提示恢复。
    func wasCommitted(in ledger: [ConversationLedgerEvent]) -> Bool {
        ledger.contains {
            $0.sequence > ledgerSequenceAtStart
                && $0.kind == .upsert
                && $0.messageID == assistantMessageID
        }
    }
}

/// 最新 checkpoint 的线程级持久层。写入独立小文件，避免流式生成每隔几百毫秒
/// 重写整个 conversations.json。actor 串行化进程内读写，文件更新用 atomic replace。
actor ConversationRunCheckpointStore {
    static let shared = ConversationRunCheckpointStore()

    private struct Document: Codable {
        var schemaVersion = 1
        var checkpoints: [String: ConversationRunCheckpoint] = [:]
    }

    private var documents: [String: Document] = [:]
    private var dirtyDirectories = Set<String>()
    private var flushTasks: [String: Task<Void, Never>] = [:]
    /// 完成 / 主动取消后封住该 run，晚到的 batch Task 不能把 checkpoint 复活。
    private var closedRuns: [String: Set<String>] = [:]

    func checkpoint(_ value: ConversationRunCheckpoint, dataDirectory: URL, immediately: Bool = false) {
        let key = dataDirectory.standardizedFileURL.path
        guard closedRuns[key]?.contains(value.runID) != true else { return }
        var document = document(for: dataDirectory)
        if let current = document.checkpoints[value.threadID] {
            // 新 run 可以取代旧 run；同一 run 只接受时间不倒退的 snapshot。
            if current.runID != value.runID, value.startedAt < current.startedAt { return }
            if current.runID == value.runID, value.updatedAt < current.updatedAt { return }
        }
        document.checkpoints[value.threadID] = value
        documents[key] = document
        dirtyDirectories.insert(key)
        if immediately {
            flush(dataDirectory: dataDirectory)
        } else {
            scheduleFlush(dataDirectory: dataDirectory)
        }
    }

    func remove(
        threadID: String,
        runID: String? = nil,
        dataDirectory: URL,
        immediately: Bool = true
    ) {
        let key = dataDirectory.standardizedFileURL.path
        var document = document(for: dataDirectory)
        if let runID { closedRuns[key, default: []].insert(runID) }
        guard let current = document.checkpoints[threadID], runID == nil || current.runID == runID else { return }
        document.checkpoints.removeValue(forKey: threadID)
        documents[key] = document
        dirtyDirectories.insert(key)
        if immediately { flush(dataDirectory: dataDirectory) }
        else { scheduleFlush(dataDirectory: dataDirectory) }
    }

    func checkpoint(threadID: String, dataDirectory: URL) -> ConversationRunCheckpoint? {
        document(for: dataDirectory).checkpoints[threadID]
    }

    func resumable(dataDirectory: URL) -> [ConversationRunCheckpoint] {
        document(for: dataDirectory).checkpoints.values
            .filter(\.canResume)
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    func flush(dataDirectory: URL) {
        let key = dataDirectory.standardizedFileURL.path
        flushTasks[key]?.cancel()
        flushTasks[key] = nil
        guard dirtyDirectories.contains(key), let document = documents[key] else { return }
        do {
            try FileManager.default.createDirectory(
                at: dataDirectory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            let data = try JSONEncoder.checkpoint.encode(document)
            let url = dataDirectory.appending(path: "conversation-checkpoints.json")
            try data.write(to: url, options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            dirtyDirectories.remove(key)
        } catch {
            // 保留 dirty；下一次 delta / scene flush 继续重试。
            NSLog("Conversation checkpoint flush failed: %@", error.localizedDescription)
        }
    }

    private func scheduleFlush(dataDirectory: URL) {
        let key = dataDirectory.standardizedFileURL.path
        guard flushTasks[key] == nil else { return }
        flushTasks[key] = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }
            await self?.finishScheduledFlush(dataDirectory: dataDirectory, key: key)
        }
    }

    private func finishScheduledFlush(dataDirectory: URL, key: String) {
        flushTasks[key] = nil
        flush(dataDirectory: dataDirectory)
    }

    private func document(for directory: URL) -> Document {
        let key = directory.standardizedFileURL.path
        if let cached = documents[key] { return cached }
        let url = directory.appending(path: "conversation-checkpoints.json")
        let loaded = (try? Data(contentsOf: url)).flatMap { try? JSONDecoder.checkpoint.decode(Document.self, from: $0) }
            ?? Document()
        documents[key] = loaded
        return loaded
    }
}

private extension JSONEncoder {
    static var checkpoint: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }
}

private extension JSONDecoder {
    static var checkpoint: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return decoder
    }
}
