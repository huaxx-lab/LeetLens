import Foundation

/// 本轮用户想干什么。分类法按**要拉什么资源**设计，不按语义好听设计——
/// 分出来的类别如果不改变我们的行为，那它就没有存在价值。
enum ConversationIntent: String, Equatable, Sendable {
    /// 致谢、确认、闲聊。
    case smalltalk
    /// 通用知识，不涉及"我"。
    case knowledge
    /// 承接本会话上文（"那这个呢""再详细点"）。
    case followUp
    /// 指向旧会话（"上次我们说的那个"）。
    case recall
    /// 个性化（"我今天该做什么""我哪块弱"）。
    case profile
    /// 针对当前代码 / 报错。
    case codeDebug
    /// 问模型自身或应用怎么用。
    case meta
}

/// 本轮需要哪些资源。跨会话检索是这里唯一真正昂贵的一项。
struct ConversationContextNeeds: OptionSet, Sendable {
    let rawValue: Int
    static let crossConversationRAG = ConversationContextNeeds(rawValue: 1 << 0)
    static let none: ConversationContextNeeds = []
}

struct ConversationIntentResolution: Equatable, Sendable {
    enum Confidence: Equatable, Sendable {
        /// 规则足够确定，不必再花一次模型调用。
        case confident
        /// 需要上文才能判断（指代句），值得交给模型。
        case ambiguous
    }

    var intent: ConversationIntent
    var needs: ConversationContextNeeds
    var confidence: Confidence
    /// 规则层认出"这是一句指代句"，但认不出指代谁。
    var mentionsReference: Bool

    var wantsRetrieval: Bool { needs.contains(.crossConversationRAG) }
}

extension ConversationContextNeeds: Equatable {}

/// 规则层：零成本，每轮必跑。
///
/// 它不回答"指代的是谁"——那要上文，交给模型。它只回答两件便宜的事：
/// **这一轮要不要检索**，以及**这是不是一句需要上文才能判断的指代句**。
enum ConversationIntentPolicy {
    /// 明确指向历史的措辞。命中即检索——这类问题不检索几乎必然答错。
    private static let historyCues = [
        "上次", "上回", "上一次", "之前", "先前", "刚才", "刚刚", "早些时候", "前面说",
        "我们讨论", "我们聊", "你说过", "你提过", "你之前", "聊过", "说过的", "提到过",
        "复盘", "回顾", "还记得"
    ]

    /// 第一人称所有格 / 个性化任务。指向用户自己的上下文，通用知识答不了。
    private static let personalCues = [
        "我的", "我们的", "我之前", "我刚", "我现在", "我在做", "帮我复盘",
        "根据我", "结合我", "适合我", "给我推荐", "我这边", "我掌握", "我哪"
    ]

    /// 显式代词与追问式省略。**认出"有指代"就够了，不必知道指代谁。**
    private static let referenceCues = [
        "它", "他", "她", "这个", "那个", "那道", "这道", "上面", "刚说的", "刚才说的",
        "继续", "接着", "延续", "再详细", "再说说", "展开讲", "换一种", "还有别的", "那这个"
    ]

    /// 问模型自身或应用。
    private static let metaCues = ["你是什么模型", "你是谁", "什么模型", "哪个模型", "怎么设置", "怎么配置"]

    /// 闲聊 / 确认。
    private static let smalltalkCues = ["你好", "在吗", "谢谢", "多谢", "好的", "收到", "嗯", "哈喽", "hello", "hi"]

    static func resolve(
        query: String,
        previous: ConversationIntentResolution? = nil,
        directory: [ConversationMemoryDirectoryEntry] = [],
        hasHostContext: Bool = false
    ) -> ConversationIntentResolution {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let lowered = trimmed.lowercased()

        // 信息量太低：连判断都不值得。
        let informationCharacters = trimmed.unicodeScalars.count {
            !CharacterSet.whitespacesAndNewlines.contains($0)
                && !CharacterSet.punctuationCharacters.contains($0)
        }
        let isShort = informationCharacters <= 8
        if isShort, smalltalkCues.contains(where: lowered.contains) {
            return ConversationIntentResolution(
                intent: .smalltalk, needs: .none, confidence: .confident, mentionsReference: false
            )
        }
        if metaCues.contains(where: trimmed.contains) {
            return ConversationIntentResolution(
                intent: .meta, needs: .none, confidence: .confident, mentionsReference: false
            )
        }

        // 强信号：本句自带足以定案的词，不看上文，也覆盖任何继承。
        if historyCues.contains(where: trimmed.contains) {
            return ConversationIntentResolution(
                intent: .recall, needs: .crossConversationRAG,
                confidence: .confident, mentionsReference: true
            )
        }
        if personalCues.contains(where: trimmed.contains) {
            return ConversationIntentResolution(
                intent: .profile, needs: .crossConversationRAG,
                confidence: .confident, mentionsReference: false
            )
        }
        // 用户自己的专有名词（题名、代号）是"该检索"最强的廉价信号。
        if ConversationMemoryPolicy.mentionsDirectoryTerm(trimmed, directory: directory) {
            return ConversationIntentResolution(
                intent: .recall, needs: .crossConversationRAG,
                confidence: .confident, mentionsReference: false
            )
        }

        // 指代句：规则层只认出"有指代"，指代谁要上文。
        // 关键设计——`followUp` **继承上一轮的资源需求**：
        // "再详细点"跟在 recall 后面仍要检索，跟在 knowledge 后面就不用。
        // 这是规则层做不到、必须带上文的地方。
        let hasReference = referenceCues.contains(where: trimmed.contains)
            || (isShort && trimmed.hasSuffix("呢"))
        if hasReference {
            // 没有上一轮可继承时兜底成"要检索"：首轮就说"力扣 42 那道题"的人，
            // 指代的必然是别的会话里的东西，判成不检索必然答错。
            let inherited = previous?.needs ?? .crossConversationRAG
            return ConversationIntentResolution(
                intent: .followUp,
                needs: inherited,
                // 继承只是先验，不是结论：交给模型层复核。
                confidence: .ambiguous,
                mentionsReference: true
            )
        }

        if hasHostContext {
            return ConversationIntentResolution(
                intent: .codeDebug, needs: .none, confidence: .confident, mentionsReference: false
            )
        }
        // 兜底要检索。这里曾经返回 `.none`，理由是"快排怎么写"不该翻旧会话——
        // 但规则层分不清"快排怎么写"和"先排序再用左右两个指针往中间夹"：后者是
        // 用户在改述自己上一轮的写法，字面上同样没有任何历史线索。真实语料实测，
        // 那版兜底误拦 20/26 条正当检索，recall@5 从 98.1% 塌到 23.1%。
        //
        // 能分辨这两者的是 cross-encoder，不是关键词表。精排后的整批准入在同一份
        // 语料上挡住 20/20 负例且零误杀，所以判断权交给它，规则层只负责排除
        // 明显不需要检索的轮次（闲聊、问模型自身）。
        return ConversationIntentResolution(
            intent: .knowledge, needs: .crossConversationRAG,
            confidence: .confident, mentionsReference: false
        )
    }
}
