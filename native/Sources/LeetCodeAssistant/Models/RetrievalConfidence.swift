import Foundation

/// 要不要把检索结果注入上下文的四维判断。
///
/// **为什么不能直接看排序分**：RRF 按名次算，单路召回时第一名恒定 `1/(k+1)`，
/// 归一化后永远是同一个值——它能排序，但天生没有"有多相关"的概念。
/// 融合两路垃圾，它照样给出一个排得很整齐的垃圾列表。
/// 所以弃权判断读的是校准过的 `relevance`，不是名次分。
///
/// 权重与阈值不是拍脑袋定的：用真实语料 46 条查询（26 正 / 20 负）网格搜出来，
/// 约束是**一条正例都不能漏**，再最大化拦住的负例数。
/// 复现：`RetrievalConfidenceTests` + `MemoryRetrievalEvalTests`。
struct RetrievalConfidence: Equatable, Sendable {
    /// 第一条的校准相关度。最直接的信号。
    let topRelevance: Double
    /// 一二名的相对差距。差距大说明"确实有一个明显更像的"；
    /// 可能为负——RRF 的名次和校准相关度不一定同向，那本身就是可疑信号。
    let margin: Double
    /// 相关度超过 0.3 的条数，最多记 3 条。
    /// 真问题通常有多段证据；偶然撞词往往只有孤零零一条。
    let supportingCount: Int
    /// 第一条覆盖了查询里多少有信息量的词。
    ///
    /// 这一维专治"词面相关、语义无关"：负例的典型形态是一个高 IDF 的词把
    /// BM25 顶上去（`Docker 容器怎么挂载卷` 只撞上 `容器`），而覆盖率骗不了人。
    /// 它必须独立于 `topRelevance`——把覆盖率折扣揉进相关度，两维就重复了，
    /// 拟合会直接把它的权重压到 0，等于白设一维。
    let coverage: Double

    static let topRelevanceWeight = 0.25
    static let marginWeight = 0.20
    static let supportWeight = 0.40
    static let coverageWeight = 0.15
    /// 低于它就整批丢弃。取正例最低分往下留 3% 余量。
    static let acceptanceThreshold = 0.62
    /// 算作"有效支撑"的相关度下限。
    static let supportingRelevanceFloor = 0.30
    static let maximumSupportingCount = 3

    /// **整个索引**里有多少个块可供检索——不是本次召回了几条。
    ///
    /// 这两件事必须分开。阈值是在 27 个会话的语料上拟合的；刚开始用的人可能只有
    /// 一两条历史，那时候 `supportingCount` 的天花板客观上就是 1，按固定的 3 折算
    /// 会让这一维永远拿不满，**冷启动用户完全召不回**。
    ///
    /// 但绝不能改成"按本次召回条数折算"：负例的典型形态恰恰就是只召回 1～2 条，
    /// 那样等于给每个负例的支撑维都判满分——实测负例拦截率会从 90% 掉到 70%。
    let indexedChunkCount: Int

    var score: Double {
        // 只有索引本身给不出三条候选时才降低天花板。
        let ceiling = max(1, min(indexedChunkCount, Self.maximumSupportingCount))
        let support = min(Double(supportingCount) / Double(ceiling), 1)
        return Self.topRelevanceWeight * max(0, topRelevance)
            + Self.marginWeight * max(0, margin)
            + Self.supportWeight * support
            + Self.coverageWeight * max(0, min(1, coverage))
    }

    var isAcceptable: Bool { score >= Self.acceptanceThreshold }

    static func evaluate(
        _ matches: [ConversationMemoryMatch],
        indexedChunkCount: Int = Int.max
    ) -> RetrievalConfidence {
        guard let top = matches.first else {
            return RetrievalConfidence(
                topRelevance: 0, margin: 0, supportingCount: 0, coverage: 0,
                indexedChunkCount: indexedChunkCount
            )
        }
        let relevances = matches.map(\.relevance)
        let margin: Double = if relevances.count >= 2, top.relevance > 0 {
            (top.relevance - relevances[1]) / top.relevance
        } else {
            top.relevance > 0 ? 1 : 0
        }
        return RetrievalConfidence(
            topRelevance: top.relevance,
            margin: margin,
            supportingCount: min(relevances.count { $0 > supportingRelevanceFloor }, maximumSupportingCount),
            coverage: top.coverage,
            indexedChunkCount: indexedChunkCount
        )
    }
}
