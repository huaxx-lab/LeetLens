import Foundation

/// 一条长期事实。刻意用结构化条目而不是纯向量存：
/// 用户必须能看见和改。向量库是黑盒，记错了用户没法纠正，信任一次就崩掉。
struct ConversationMemoryFact: Codable, Hashable, Identifiable, Sendable {
    var id: String
    var text: String
    /// profile（他是谁）/ preference（他要什么样的答案）/ project（他在做什么）
    var kind: String
    var sources: [String]
    var updatedAt: Date

    static let kinds = ["profile", "preference", "project"]

    var kindTitle: String {
        switch kind {
        case "profile": "身份"
        case "preference": "偏好"
        default: "项目"
        }
    }
}

struct ConversationMemoryFactDocument: Codable, Sendable {
    var version = 1
    /// 乐观锁版本号：多个端/多个任务可能同时改，写回时对不上就走合并而不是覆盖。
    var revision = 0
    var facts: [ConversationMemoryFact] = []
    /// conversationID -> 已经整合到第几条消息。避免同一段摘要被反复喂进去。
    var consolidated: [String: Int] = [:]
    var updatedAt = Date.distantPast

    static let empty = ConversationMemoryFactDocument()
}

/// 长期事实的读写。写入走"双通道"里的异步整合那一路：
/// 对话中同步抽取的是会话摘要（宁可漏不可错），这里离线做去重、冲突消解
/// （"我换用 Kotlin 了" 要覆盖旧的语言偏好而不是追加），以及把零散提及升格成模式。
actor ConversationMemoryFactStore {
    static let shared = ConversationMemoryFactStore()

    /// 注入上限。事实是常驻 L0，涨上去每一轮都要付钱。
    static let injectionLimit = 12
    static let storageLimit = 60

    private var cache: [String: ConversationMemoryFactDocument] = [:]

    private func key(_ dataDirectory: URL) -> String {
        dataDirectory.standardizedFileURL.path
    }

    func document(dataDirectory: URL) -> ConversationMemoryFactDocument {
        if let cached = cache[key(dataDirectory)] { return cached }
        let loaded = load(dataDirectory: dataDirectory)
        cache[key(dataDirectory)] = loaded
        return loaded
    }

    func facts(dataDirectory: URL) -> [ConversationMemoryFact] {
        document(dataDirectory: dataDirectory).facts
    }

    /// 用 `expectedRevision` 做乐观锁。对不上说明期间有别的写入，
    /// 这时按 id 合并、`updatedAt` 新的胜出，而不是拿旧快照整个盖掉。
    @discardableResult
    func commit(
        facts incoming: [ConversationMemoryFact],
        consolidated: [String: Int],
        expectedRevision: Int,
        dataDirectory: URL
    ) -> ConversationMemoryFactDocument {
        var current = load(dataDirectory: dataDirectory)
        var merged: [ConversationMemoryFact]
        if current.revision == expectedRevision {
            merged = incoming
        } else {
            var byID = Dictionary(uniqueKeysWithValues: current.facts.map { ($0.id, $0) })
            for fact in incoming {
                if let existing = byID[fact.id], existing.updatedAt > fact.updatedAt { continue }
                byID[fact.id] = fact
            }
            merged = Array(byID.values)
        }
        merged.sort { $0.updatedAt > $1.updatedAt }
        current.facts = Array(merged.prefix(Self.storageLimit))
        current.consolidated = current.consolidated.merging(consolidated) { _, new in new }
        current.revision += 1
        current.updatedAt = .now
        persist(current, dataDirectory: dataDirectory)
        cache[key(dataDirectory)] = current
        return current
    }

    /// 用户删掉的事实要真的消失。记错了却删不掉，比记错本身更伤信任。
    func remove(id: String, dataDirectory: URL) {
        var current = load(dataDirectory: dataDirectory)
        guard current.facts.contains(where: { $0.id == id }) else { return }
        current.facts.removeAll { $0.id == id }
        current.revision += 1
        current.updatedAt = .now
        persist(current, dataDirectory: dataDirectory)
        cache[key(dataDirectory)] = current
    }

    func removeAll(dataDirectory: URL) {
        var current = load(dataDirectory: dataDirectory)
        current.facts = []
        current.consolidated = [:]
        current.revision += 1
        current.updatedAt = .now
        persist(current, dataDirectory: dataDirectory)
        cache[key(dataDirectory)] = current
    }

    private func load(dataDirectory: URL) -> ConversationMemoryFactDocument {
        let url = dataDirectory.appending(path: "memory-facts.json")
        guard let data = try? Data(contentsOf: url),
              let document = try? JSONDecoder().decode(ConversationMemoryFactDocument.self, from: data)
        else { return .empty }
        return document
    }

    private func persist(_ document: ConversationMemoryFactDocument, dataDirectory: URL) {
        try? FileManager.default.createDirectory(
            at: dataDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let url = dataDirectory.appending(path: "memory-facts.json")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(document) else { return }
        try? data.write(to: url, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}

enum ConversationMemoryFactPrompt {
    /// L0 常驻层：极小且稳定，每轮都相关，不值得为它做一次判断。
    static func prompt(for facts: [ConversationMemoryFact]) -> String? {
        let selected = facts.prefix(ConversationMemoryFactStore.injectionLimit)
        guard !selected.isEmpty else { return nil }
        let lines = selected.map { "- [\($0.kindTitle)] \($0.text)" }
        return """
        【关于这位用户的长期事实】
        由历史会话离线整合而来，可能过时。与本轮用户明确说法冲突时一律以本轮为准。
        只有当它确实改变回答的实质内容时才使用，不要为了显得记得而复述。

        \(lines.joined(separator: "\n"))
        """
    }

    /// 待整合的会话：摘要变过、且比上次整合时更新。
    static func pending(
        conversations: [ConversationSummary],
        consolidated: [String: Int],
        limit: Int = 8
    ) -> [ConversationSummary] {
        conversations
            .filter { !$0.aiSummary.isEmpty || !$0.contextSummary.isEmpty }
            .filter { $0.archivedMessageCount > (consolidated[$0.id] ?? 0) }
            .sorted { $0.updatedAt > $1.updatedAt }
            .prefix(limit)
            .map { $0 }
    }
}
