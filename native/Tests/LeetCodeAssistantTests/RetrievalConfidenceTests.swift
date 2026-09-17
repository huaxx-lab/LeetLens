import Foundation
import XCTest
@testable import LeetCodeAssistant

/// 四维置信度闸门。权重与阈值由真实语料 46 条查询（26 正 / 20 负）网格搜出来，
/// 约束是一条正例都不能漏，再最大化拦住的负例数——实测 18/20。
final class RetrievalConfidenceTests: XCTestCase {
    private func match(_ id: String, relevance: Double, coverage: Double) -> ConversationMemoryMatch {
        ConversationMemoryMatch(
            conversationID: id, title: id, content: "", score: 0,
            messageIDs: [], relevance: relevance, coverage: coverage
        )
    }

    // MARK: - 为什么不能直接看排序分

    /// RRF 按名次算：单路召回时第一名恒定 `1/(k+1)`，归一化后永远是同一个值。
    /// 它能排序，但天生没有"有多相关"的概念——所以闸门只能读校准值。
    func testFusionScoreIsConstantAcrossRanksAndCannotGateAbstention() {
        let maximumRRF = (1 + ReciprocalRankFusion.denseWeight) / (ReciprocalRankFusion.rankConstant + 1)
        let topOnly = ReciprocalRankFusion.score(ranks: [1, nil], weights: [1, ReciprocalRankFusion.denseWeight])
        XCTAssertEqual(topOnly / maximumRRF, 0.5, accuracy: 0.001, "单路第一名恒为上限的一半，与内容无关")
    }

    func testCalibratedRelevanceIsIndependentOfCoverage() {
        // 覆盖率是独立一维。把它揉进相关度，两维就重复了，拟合会把它的权重压到 0。
        let a = ConversationMemoryIndex.calibratedRelevance(bm25: 12, coverage: 0.2, dense: 0)
        let b = ConversationMemoryIndex.calibratedRelevance(bm25: 12, coverage: 1.0, dense: 0)
        XCTAssertEqual(a, b, accuracy: 0.0001)
    }

    func testCalibratedRelevanceSaturatesAndStaysInRange() {
        XCTAssertEqual(ConversationMemoryIndex.calibratedRelevance(bm25: 0, coverage: 1, dense: 0), 0)
        let huge = ConversationMemoryIndex.calibratedRelevance(bm25: 10_000, coverage: 1, dense: 0)
        XCTAssertLessThanOrEqual(huge, 1)
        XCTAssertGreaterThan(huge, 0.99)
    }

    // MARK: - 四维

    func testEmptyResultsAreNeverAcceptable() {
        let confidence = RetrievalConfidence.evaluate([])
        XCTAssertEqual(confidence.score, 0)
        XCTAssertFalse(confidence.isAcceptable)
    }

    func testStrongMultiEvidenceHitIsAccepted() {
        let confidence = RetrievalConfidence.evaluate([
            match("a", relevance: 0.80, coverage: 0.9),
            match("a", relevance: 0.60, coverage: 0.8),
            match("a", relevance: 0.45, coverage: 0.7)
        ])
        XCTAssertEqual(confidence.supportingCount, 3)
        XCTAssertTrue(confidence.isAcceptable)
    }

    /// 负例的典型形态：一个偶然的高 IDF 词把 BM25 顶上去，但只有孤零零一条证据、
    /// 覆盖率也低。
    func testLoneIncidentalMatchIsRejected() {
        let confidence = RetrievalConfidence.evaluate([
            match("a", relevance: 0.26, coverage: 0.25)
        ])
        XCTAssertEqual(confidence.supportingCount, 0)
        XCTAssertFalse(confidence.isAcceptable)
    }

    func testSupportingCountIsCappedAtThree() {
        let many = (0..<8).map { match("a\($0)", relevance: 0.9, coverage: 0.9) }
        XCTAssertEqual(RetrievalConfidence.evaluate(many).supportingCount, 3)
    }

    func testSupportingCountUsesTheRelevanceFloor() {
        let confidence = RetrievalConfidence.evaluate([
            match("a", relevance: 0.35, coverage: 0.9),
            match("b", relevance: 0.29, coverage: 0.9),
            match("c", relevance: 0.01, coverage: 0.9)
        ])
        XCTAssertEqual(confidence.supportingCount, 1, "只数超过 0.3 的")
    }

    /// RRF 的名次和校准相关度不一定同向，差值可能为负——那本身就是可疑信号，
    /// 不能让它把总分抬上去。
    func testNegativeMarginNeverInflatesTheScore() {
        let inverted = RetrievalConfidence(topRelevance: 0.5, margin: -0.4, supportingCount: 1, coverage: 0.5, indexedChunkCount: 400)
        let flat = RetrievalConfidence(topRelevance: 0.5, margin: 0, supportingCount: 1, coverage: 0.5, indexedChunkCount: 400)
        XCTAssertEqual(inverted.score, flat.score, accuracy: 0.0001)
    }

    func testSingleResultCountsAsFullMargin() {
        let confidence = RetrievalConfidence.evaluate([match("a", relevance: 0.7, coverage: 0.8)])
        XCTAssertEqual(confidence.margin, 1, "只有一条时没有竞争者，差值记满")
    }

    func testCoverageActuallyMovesTheDecision() {
        // 同样的相关度与证据数，只有覆盖率不同——第四维必须真的参与判断，
        // 否则等于白设一维。
        let base = RetrievalConfidence(topRelevance: 0.5, margin: 0.1, supportingCount: 2, coverage: 0.0, indexedChunkCount: 400)
        let covered = RetrievalConfidence(topRelevance: 0.5, margin: 0.1, supportingCount: 2, coverage: 1.0, indexedChunkCount: 400)
        XCTAssertEqual(covered.score - base.score, RetrievalConfidence.coverageWeight, accuracy: 0.0001)
    }

    /// 刚开始用的人只有一两条历史，天花板就是 1 条证据。
    /// 按固定的 3 折算会让这一维永远拿不满——冷启动用户完全召不回。
    func testColdStartUserWithASingleStrongMatchIsStillAccepted() {
        let confidence = RetrievalConfidence.evaluate(
            [match("only", relevance: 0.78, coverage: 0.9)],
            indexedChunkCount: 1
        )
        XCTAssertTrue(confidence.isAcceptable, "整个索引只有一块时也要能召回")
    }

    func testSingleWeakMatchIsStillRejectedOnASmallCorpus() {
        let confidence = RetrievalConfidence.evaluate(
            [match("only", relevance: 0.20, coverage: 0.2)],
            indexedChunkCount: 1
        )
        XCTAssertFalse(confidence.isAcceptable, "自适应不能变成无条件放行")
    }

    /// 关键区分：负例往往也只召回 1～2 条。**不能**因为"这次只召回一条"就放宽，
    /// 那样等于给每个负例的支撑维判满分（实测拦截率 90% → 70%）。
    func testLoneMatchOnALargeIndexIsNotGivenFullSupportCredit() {
        let confidence = RetrievalConfidence.evaluate(
            [match("only", relevance: 0.45, coverage: 0.4)],
            indexedChunkCount: 500
        )
        XCTAssertFalse(confidence.isAcceptable, "语料很大却只捞到一条弱证据，正是负例的形态")
    }

    func testWeightsSumToOneSoTheThresholdIsComparable() {
        let total = RetrievalConfidence.topRelevanceWeight
            + RetrievalConfidence.marginWeight
            + RetrievalConfidence.supportWeight
            + RetrievalConfidence.coverageWeight
        XCTAssertEqual(total, 1, accuracy: 0.0001)
    }

    func testPerfectResultScoresOneAndClampsAtTheTop() {
        let best = RetrievalConfidence(topRelevance: 1, margin: 1, supportingCount: 3, coverage: 1, indexedChunkCount: 400)
        XCTAssertEqual(best.score, 1, accuracy: 0.0001)
        let overflow = RetrievalConfidence(topRelevance: 2, margin: 2, supportingCount: 3, coverage: 2, indexedChunkCount: 400)
        XCTAssertLessThanOrEqual(overflow.score, 1.5, "越界输入不该把分数拉到离谱")
    }
}
