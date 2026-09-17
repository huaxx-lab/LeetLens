import Foundation
import XCTest
@testable import LeetCodeAssistant

final class RetrievalBenchmarkTests: XCTestCase {
    private struct Fixture: Decodable {
        struct Document: Decodable { let id: String; let title: String; let text: String }
        struct Query: Decodable { let group: String; let query: String; let relevant: [String] }
        let documents: [Document]
        let queries: [Query]
    }

    private struct Metrics {
        let recall5: Double
        let mrr: Double
        let negativePass: Double
        let hit1: Double
    }

    func testSyntheticBenchmarkPrintsBM25DenseAndRRFMetrics() async throws {
        guard ProcessInfo.processInfo.environment["LEETLENS_RUN_RAG_BENCHMARK"] == "1" else {
            throw XCTSkip("设置 LEETLENS_RUN_RAG_BENCHMARK=1 运行召回基准")
        }
        let fixture = try loadFixture()
        let index = ConversationMemoryIndex()
        await index.synchronize(conversations: conversations(fixture.documents))
        for strategy in ConversationMemoryRetrievalStrategy.allCases {
            let rankings = await rankings(index: index, fixture: fixture, strategy: strategy)
            printMetrics(label: strategy.rawValue, metrics(rankings: rankings, fixture: fixture))
        }
        for weight in stride(from: 0.0, through: 1.0, by: 0.1) {
            let weighted = ConversationMemoryIndex(denseRRFWeight: weight)
            await weighted.synchronize(conversations: conversations(fixture.documents))
            let values = await rankings(index: weighted, fixture: fixture, strategy: .reciprocalRankFusion)
            printMetrics(label: String(format: "RRF dense=%.1f", weight), metrics(rankings: values, fixture: fixture))
        }
    }

    /// 合成文本可以安全发往外部。真实历史评测需单独明确授权。
    func testSyntheticQwenRerankerBenchmark() async throws {
        guard ProcessInfo.processInfo.environment["LEETLENS_RUN_LIVE_RERANK_BENCHMARK"] == "1",
              let dataDirectory = ProcessInfo.processInfo.environment["LEETLENS_EVAL_DATA_DIR"],
              let provider = ProcessInfo.processInfo.environment["LEETLENS_EVAL_RERANK_PROVIDER"]
        else { throw XCTSkip("设置 live rerank 环境变量才调用 qwen3.7") }

        let fixture = try loadFixture()
        let service = ChatService(dataDirectory: URL(fileURLWithPath: NSString(string: dataDirectory).expandingTildeInPath))
        let embedding = try await service.makeConversationEmbeddingProvider(providerID: provider)
        let index = ConversationMemoryIndex(
            useSemanticEmbeddings: false,
            embeddingProvider: embedding
        )
        await index.synchronize(conversations: conversations(fixture.documents))
        let reranker = try await service.makeTextReranker(providerID: provider)

        let localRRF = await rankings(index: index, fixture: fixture, strategy: .reciprocalRankFusion)
        printMetrics(label: "qwen embedding RRF", metrics(rankings: localRRF, fixture: fixture))

        var scored: [[(id: String, score: Double)]] = []
        for (offset, query) in fixture.queries.enumerated() {
            let candidates = await index.candidates(query: query.query, currentConversationID: "", limit: 24)
            if candidates.isEmpty { scored.append([]); continue }
            let hits = try await reranker.rerank(
                query: query.query,
                documents: candidates.enumerated().map { index, candidate in
                    TextRerankDocument(id: String(index), text: candidate.content)
                },
                topN: candidates.count
            )
            var seen = Set<String>()
            scored.append(hits.compactMap { hit in
                guard candidates.indices.contains(hit.originalIndex) else { return nil }
                let id = candidates[hit.originalIndex].conversationID
                return seen.insert(id).inserted ? (id, hit.relevanceScore) : nil
            })
            print("qwen progress \(offset + 1)/\(fixture.queries.count)")
        }

        for threshold in stride(from: 0.0, through: 0.9, by: 0.1) {
            let rankings = scored.map { row in row.filter { $0.score >= threshold }.map(\.id) }
            printMetrics(label: String(format: "qwen t=%.1f", threshold), metrics(rankings: rankings, fixture: fixture))
        }
    }

    func testWordTokenizerNeverCreatesCrossBoundaryChineseBigrams() {
        let poetry = ConversationMemoryIndex.tokens(in: "帮我写一首关于秋天的诗")
        XCTAssertFalse(poetry.contains("我写"))
        XCTAssertFalse(poetry.contains("写一"))
        XCTAssertFalse(poetry.contains("天的"))
        let docker = ConversationMemoryIndex.tokens(in: "Docker 容器怎么挂载卷")
        XCTAssertFalse(docker.contains("器怎"))
        XCTAssertTrue(docker.contains("docker"))
        XCTAssertTrue(docker.contains("容器"))
    }

    func testRRFRewardsAgreementWithoutComparingRawScoreScales() {
        let both = ReciprocalRankFusion.score(ranks: [1, 10])
        let sparseOnly = ReciprocalRankFusion.score(ranks: [1, nil])
        let denseOnly = ReciprocalRankFusion.score(ranks: [nil, 1])
        XCTAssertGreaterThan(both, sparseOnly)
        XCTAssertEqual(sparseOnly, denseOnly)
        XCTAssertGreaterThan(ReciprocalRankFusion.score(ranks: [1, nil]), ReciprocalRankFusion.score(ranks: [2, nil]))
    }

    private func rankings(
        index: ConversationMemoryIndex,
        fixture: Fixture,
        strategy: ConversationMemoryRetrievalStrategy
    ) async -> [[String]] {
        var output: [[String]] = []
        for query in fixture.queries {
            output.append(await index.search(
                query: query.query,
                currentConversationID: "",
                limit: 10,
                strategy: strategy
            ).map(\.conversationID))
        }
        return output
    }

    private func metrics(rankings: [[String]], fixture: Fixture) -> Metrics {
        let positiveIndices = fixture.queries.indices.filter { !fixture.queries[$0].relevant.isEmpty }
        let negativeIndices = fixture.queries.indices.filter { fixture.queries[$0].relevant.isEmpty }
        let recall = positiveIndices.reduce(0.0) { total, index in
            let relevant = Set(fixture.queries[index].relevant)
            return total + Double(Set(rankings[index].prefix(5)).intersection(relevant).count) / Double(relevant.count)
        } / Double(max(1, positiveIndices.count))
        let reciprocal = positiveIndices.reduce(0.0) { total, index in
            guard let rank = rankings[index].firstIndex(where: { fixture.queries[index].relevant.contains($0) }) else { return total }
            return total + 1 / Double(rank + 1)
        } / Double(max(1, positiveIndices.count))
        let hit1 = Double(positiveIndices.count { index in
            rankings[index].first.map(fixture.queries[index].relevant.contains) == true
        }) / Double(max(1, positiveIndices.count))
        let negative = Double(negativeIndices.count { rankings[$0].isEmpty }) / Double(max(1, negativeIndices.count))
        return Metrics(recall5: recall, mrr: reciprocal, negativePass: negative, hit1: hit1)
    }

    private func printMetrics(label: String, _ value: Metrics) {
        print(String(format: "METRIC %-18@ hit@1=%5.1f%% recall@5=%5.1f%% MRR=%0.3f negative=%5.1f%%",
                     label as NSString, value.hit1 * 100, value.recall5 * 100, value.mrr, value.negativePass * 100))
    }

    private func loadFixture() throws -> Fixture {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appending(path: "Fixtures/rag-retrieval-benchmark.json")
        return try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url))
    }

    private func conversations(_ documents: [Fixture.Document]) -> [ConversationSummary] {
        documents.enumerated().map { index, document in
            ConversationSummary(
                id: document.id,
                title: document.title,
                summary: "",
                updatedAt: Date(timeIntervalSince1970: Double(index + 1)),
                messageCount: 1,
                messages: [ConversationTranscriptMessage(
                    id: "m-\(document.id)", role: "assistant", content: document.text, createdAt: .now
                )]
            )
        }
    }
}

/// 分词的两条边界：**跨词伪 token 要杀掉，词内碎片要补回来**。
/// 只做前者会把"和为K的子数组"打成一串孤立单字，整句只剩一个多字词，
/// 连准入门槛都过不了——实测那条查询从第 1 名直接掉到召不回。
final class ChineseTokenizationBoundaryTests: XCTestCase {
    func testAdjacentSingleCharacterFragmentsAreRecombined() {
        let tokens = ConversationMemoryIndex.tokens(in: "和为 K 的子数组这题要写什么代码")
        XCTAssertTrue(tokens.contains("子数"), "被过度切分的同一个词要补回二元组")
        XCTAssertTrue(tokens.contains("数组"))
    }

    func testStopWordsAndPunctuationBreakTheFragmentRun() {
        // "的" 是停用词，不能把它两侧的字粘成一个词。
        let tokens = ConversationMemoryIndex.tokens(in: "树的插")
        XCTAssertFalse(tokens.contains("树插"), "被停用词隔开的两个字不是一个词")
    }

    func testCrossWordBoundaryBigramsStayGone() {
        // 这几个是旧的整段滑窗造出来的伪词：稀有 → IDF 最高 → 主导 BM25。
        let docker = ConversationMemoryIndex.tokens(in: "Docker 容器怎么挂载卷")
        XCTAssertFalse(docker.contains("器怎"), "容器|怎么 之间是真实词边界")
        let poetry = ConversationMemoryIndex.tokens(in: "帮我写一首关于秋天的诗")
        XCTAssertFalse(poetry.contains("天的"), "秋天|的 之间是真实词边界")
        XCTAssertFalse(poetry.contains("我写"))
    }

    func testMultiCharacterWordsStillContributeTheirOwnSubwords() {
        let tokens = ConversationMemoryIndex.tokens(in: "最小覆盖子串")
        XCTAssertTrue(tokens.contains("最小"))
    }
}
