import Foundation

/// 模型窗口不是事实存储，只是 append-only ledger 的一个纯投影。
///
/// 三层从近到远：
/// - verbatim：最近完整 turn，逐字保留；
/// - skeleton：较早 turn 的完整 user 问句 / assistant 首个完整语义单元；
/// - digest：异步归档完成后才可用的滚动摘要。
///
/// `peak` 只决定“现在要不要压缩”；一旦越线就收敛到更低的 `steady`，避免每新增一条
/// 消息都在临界点附近反复压缩。两者都按模型可用输入窗口比例算，不按固定消息数。
struct ContextProjection: Equatable, Sendable {
    struct Budgets: Equatable, Sendable {
        let availableInputTokens: Int
        let peakTokens: Int
        let steadyTokens: Int
        let digestTokens: Int
        let skeletonTokens: Int
        let verbatimTokens: Int

        static func resolve(settings: LegacySettingsSnapshot) -> Self {
            let window = max(512, Int(settings.contextWindowTokens))
            let reserved = min(max(0, Int(settings.reservedOutputTokens)), max(0, window - 256))
            let available = max(256, window - reserved)
            let peakRatio = min(max(settings.compressionThreshold, 0.50), 0.99)
            let steadyRatio = min(max(settings.postCompressionRatio, 0.40), peakRatio)
            let peak = max(1, Int(Double(available) * peakRatio))
            let steady = max(1, Int(Double(available) * steadyRatio))

            // digest 有封顶：1M 窗口不能让摘要膨胀到十几万 token。
            let digest = min(8_192, max(0, Int(Double(steady) * 0.15)))
            // 最近逐字上下文至少拿 steady 的 60%；剩余全部给 skeleton。
            let verbatim = max(1, Int(Double(steady) * 0.60))
            let skeleton = max(0, steady - digest - verbatim)
            return Self(
                availableInputTokens: available,
                peakTokens: peak,
                steadyTokens: steady,
                digestTokens: digest,
                skeletonTokens: skeleton,
                verbatimTokens: verbatim
            )
        }
    }

    enum Tier: String, Equatable, Sendable {
        case full
        case ladder
    }

    let messages: [ChatRequestMessage]
    let tier: Tier
    let verbatimMessageIDs: [String]
    let estimatedTokens: Int
    let budgets: Budgets

    static func build(
        ledger: [ConversationLedgerEvent],
        digest: String,
        settings: LegacySettingsSnapshot
    ) -> Self {
        let source = ConversationLedger.project(ledger)
            .filter { $0.role == "user" || $0.role == "assistant" }
        return build(messages: source, digest: digest, settings: settings)
    }

    static func build(
        messages source: [ConversationTranscriptMessage],
        digest: String,
        settings: LegacySettingsSnapshot
    ) -> Self {
        let source = source.filter { $0.role == "user" || $0.role == "assistant" }
        let budgets = Budgets.resolve(settings: settings)
        let clean = source.compactMap(sanitized)
        let fullTokens = tokenCount(clean.map(\.request))
        guard fullTokens > budgets.peakTokens else {
            return Self(
                messages: clean.map(\.request),
                tier: .full,
                verbatimMessageIDs: clean.map(\.id),
                estimatedTokens: fullTokens,
                budgets: budgets
            )
        }

        let turns = turns(from: clean)
        let verbatim = takeRecentWholeTurns(turns, budget: budgets.verbatimTokens)
        let verbatimIDs = Set(verbatim.flatMap { $0.messages.map(\.id) })
        let older = turns.filter { turn in !turn.messages.contains { verbatimIDs.contains($0.id) } }
        let skeleton = takeRecentSkeletons(older, budget: budgets.skeletonTokens)
        let digestMessage = digestRequest(digest, budget: budgets.digestTokens)

        var projected: [ChatRequestMessage] = []
        if let digestMessage { projected.append(digestMessage) }
        if !skeleton.isEmpty {
            projected.append(ChatRequestMessage(
                role: "system",
                content: "【较早对话骨架】\n" + skeleton.joined(separator: "\n")
            ))
        }
        projected.append(contentsOf: verbatim.flatMap { $0.messages.map(\.request) })

        // 精确兜底：估算误差或一个超大 turn 让结果越过 steady 时，从最弱层开始整块删。
        projected = enforceSteadyBudget(
            projected,
            steadyTokens: budgets.steadyTokens,
            keepsLastUser: clean.last(where: { $0.request.role == "user" })?.request
        )
        let includedIDs = verbatim.flatMap { $0.messages.map(\.id) }
        return Self(
            messages: projected,
            tier: .ladder,
            verbatimMessageIDs: includedIDs,
            estimatedTokens: tokenCount(projected),
            budgets: budgets
        )
    }

    private struct CleanMessage {
        let id: String
        let role: String
        let content: String
        var request: ChatRequestMessage { ChatRequestMessage(role: role, content: content) }
    }

    private struct Turn {
        var messages: [CleanMessage]
        var tokens: Int { tokenCount(messages.map(\.request)) }
    }

    private static func sanitized(_ message: ConversationTranscriptMessage) -> CleanMessage? {
        let content = ConversationChunker.sanitize(message.content, role: message.role)
        guard !content.isEmpty else { return nil }
        return CleanMessage(id: message.id, role: message.role, content: content)
    }

    private static func turns(from messages: [CleanMessage]) -> [Turn] {
        var result: [Turn] = []
        var current: [CleanMessage] = []
        for message in messages {
            if message.role == "user", !current.isEmpty {
                result.append(Turn(messages: current))
                current = []
            }
            current.append(message)
        }
        if !current.isEmpty { result.append(Turn(messages: current)) }
        return result
    }

    /// 最近 turn 逐个整块准入。最后一个 turn 自身超预算时，按消息语义边界保住当前 user；
    /// 绝不把 user/assistant 配对从中间截成 provider 无效序列。
    private static func takeRecentWholeTurns(_ turns: [Turn], budget: Int) -> [Turn] {
        guard budget > 0 else { return [] }
        var selected: [Turn] = []
        var used = 0
        for turn in turns.reversed() {
            if used + turn.tokens <= budget {
                selected.append(turn)
                used += turn.tokens
                continue
            }
            if selected.isEmpty, let clipped = clippedLatestTurn(turn, budget: budget) {
                selected.append(clipped)
            }
            break
        }
        return selected.reversed()
    }

    private static func clippedLatestTurn(_ turn: Turn, budget: Int) -> Turn? {
        guard budget > 4, let user = turn.messages.last(where: { $0.role == "user" }) else { return nil }
        let tail = ConversationChunker.semanticTail(
            in: user.content,
            role: "user",
            budgetTokens: budget - 4
        )
        guard let tail, !tail.isEmpty else { return nil }
        return Turn(messages: [CleanMessage(id: user.id, role: "user", content: tail)])
    }

    /// skeleton 也是按完整 turn 准入；每个 turn 最多留下 user 首句与 assistant 首句。
    private static func takeRecentSkeletons(_ turns: [Turn], budget: Int) -> [String] {
        guard budget > 0 else { return [] }
        var selected: [String] = []
        var used = 0
        for turn in turns.reversed() {
            let remaining = budget - used
            guard remaining > 8 else { break }
            let user = turn.messages.first(where: { $0.role == "user" })
            let assistant = turn.messages.first(where: { $0.role == "assistant" })
            let roleCount = [user, assistant].compactMap { $0 }.count
            guard roleCount > 0 else { continue }
            // 单条摘要预算必须服从整层剩余预算；固定给每条 96 token 会出现
            // “一个骨架项比整个 skeleton 层还大”，最终整层永远为空。
            let perRole = max(4, min(96, (remaining - 8) / roleCount))
            var lines: [String] = []
            if let user,
               let head = ConversationChunker.semanticHead(
                in: user.content, role: "user", budgetTokens: perRole
               ) {
                lines.append("用户：\(head)")
            }
            if let assistant,
               let head = ConversationChunker.semanticHead(
                in: assistant.content, role: "assistant", budgetTokens: perRole
               ) {
                lines.append("助手：\(head)")
            }
            let item = lines.joined(separator: "\n")
            guard !item.isEmpty else { continue }
            let cost = 4 + ConversationContextEstimator.estimateTextTokens(item)
            guard used + cost <= budget else { break }
            selected.append(item)
            used += cost
        }
        return selected.reversed()
    }

    private static func digestRequest(_ source: String, budget: Int) -> ChatRequestMessage? {
        guard budget > 4 else { return nil }
        let clean = ConversationChunker.sanitize(source, role: "assistant")
        guard !clean.isEmpty else { return nil }
        let body: String
        if 4 + ConversationContextEstimator.estimateTextTokens(clean) <= budget {
            body = clean
        } else {
            body = ConversationChunker.semanticHead(
                in: clean,
                role: "assistant",
                budgetTokens: budget - 4
            ) ?? ""
        }
        guard !body.isEmpty else { return nil }
        return ChatRequestMessage(role: "system", content: "【历史对话摘要】\n\(body)")
    }

    private static func enforceSteadyBudget(
        _ source: [ChatRequestMessage],
        steadyTokens: Int,
        keepsLastUser: ChatRequestMessage?
    ) -> [ChatRequestMessage] {
        var result = source
        while tokenCount(result) > steadyTokens, result.count > 1 {
            // digest 和 skeleton 在队首，先删最弱的旧信息；最近逐字 turn 最后才动。
            result.removeFirst()
        }
        guard tokenCount(result) > steadyTokens, let lastUser = keepsLastUser else { return result }
        let body = ConversationChunker.semanticTail(
            in: lastUser.content,
            role: "user",
            budgetTokens: max(1, steadyTokens - 4)
        )
        return body.map { [ChatRequestMessage(role: "user", content: $0)] } ?? []
    }

    private static func tokenCount(_ messages: [ChatRequestMessage]) -> Int {
        messages.reduce(0) { $0 + 4 + ConversationContextEstimator.estimateTextTokens($1.content) }
    }
}
