import Foundation

/// `messages` 不再是事实源，而是这条 append-only 日志的一次物化投影。
///
/// 语义对齐 LangGraph `add_messages`：新 messageID 追加；同 ID 的后续 upsert
/// 替换当前值但不改第一次出现的位置；remove 是 tombstone，不回写旧事件。
struct ConversationLedgerEvent: Identifiable, Hashable, Sendable {
    enum Kind: String, Hashable, Sendable {
        case upsert
        case remove
    }

    let id: String
    let sequence: Int
    let kind: Kind
    let messageID: String
    let recordedAt: Date
    let message: ConversationTranscriptMessage?
}

enum ConversationLedger {
    /// 旧会话第一次写入时，在同一次原子文件更新里把原 `messages` 引导成事件。
    /// event ID 是确定性的：迁移重试不会制造一批不同身份的历史事件。
    static func bootstrap(_ messages: [ConversationTranscriptMessage]) -> [ConversationLedgerEvent] {
        messages.enumerated().map { index, message in
            ConversationLedgerEvent(
                id: "bootstrap:\(index):\(message.id)",
                sequence: index + 1,
                kind: .upsert,
                messageID: message.id,
                recordedAt: message.createdAt,
                message: message
            )
        }
    }

    static func appending(
        _ message: ConversationTranscriptMessage,
        to events: [ConversationLedgerEvent],
        eventID: String = "le_\(UUID().uuidString.lowercased())",
        recordedAt: Date = .now
    ) -> [ConversationLedgerEvent] {
        events + [ConversationLedgerEvent(
            id: eventID,
            sequence: nextSequence(after: events),
            kind: .upsert,
            messageID: message.id,
            recordedAt: recordedAt,
            message: message
        )]
    }

    static func removing(
        messageID: String,
        from events: [ConversationLedgerEvent],
        eventID: String = "le_\(UUID().uuidString.lowercased())",
        recordedAt: Date = .now
    ) -> [ConversationLedgerEvent] {
        events + [ConversationLedgerEvent(
            id: eventID,
            sequence: nextSequence(after: events),
            kind: .remove,
            messageID: messageID,
            recordedAt: recordedAt,
            message: nil
        )]
    }

    /// 当前对话窗口只是 ledger 的投影；归约本身没有 IO、时间或全局状态。
    static func project(_ events: [ConversationLedgerEvent]) -> [ConversationTranscriptMessage] {
        let ordered = normalized(events)
        var firstSeen: [String] = []
        var seen = Set<String>()
        var values: [String: ConversationTranscriptMessage] = [:]

        for event in ordered {
            if seen.insert(event.messageID).inserted { firstSeen.append(event.messageID) }
            switch event.kind {
            case .upsert:
                guard let message = event.message, message.id == event.messageID else { continue }
                values[event.messageID] = message
            case .remove:
                values.removeValue(forKey: event.messageID)
            }
        }
        return firstSeen.compactMap { values[$0] }
    }

    /// 归档水位线之后被追加或修订过的**当前版本**，按第一次变更顺序返回。
    /// 同一 message 在一次归档周期里修订多次，只给摘要器最终版本。
    static func changedMessages(
        after sequence: Int,
        in events: [ConversationLedgerEvent]
    ) -> [ConversationTranscriptMessage] {
        let ordered = normalized(events)
        let current = Dictionary(uniqueKeysWithValues: project(ordered).map { ($0.id, $0) })
        var ids: [String] = []
        var seen = Set<String>()
        for event in ordered where event.sequence > sequence {
            if seen.insert(event.messageID).inserted { ids.append(event.messageID) }
        }
        return ids.compactMap { current[$0] }
    }

    static func latestSequence(_ events: [ConversationLedgerEvent]) -> Int {
        events.map(\.sequence).max() ?? 0
    }

    private static func nextSequence(after events: [ConversationLedgerEvent]) -> Int {
        latestSequence(events) + 1
    }

    /// 文件被手工改乱时仍给出确定投影：sequence 优先，数组位置稳定打破并列。
    private static func normalized(_ events: [ConversationLedgerEvent]) -> [ConversationLedgerEvent] {
        events.enumerated().sorted { lhs, rhs in
            if lhs.element.sequence != rhs.element.sequence {
                return lhs.element.sequence < rhs.element.sequence
            }
            return lhs.offset < rhs.offset
        }.map(\.element)
    }
}
