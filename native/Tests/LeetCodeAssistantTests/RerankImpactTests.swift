import Foundation
import XCTest
@testable import LeetCodeAssistant

/// 检索全链路评测，按生产设计的真实顺序跑：
///
///   两路召回（BM25 + 千问向量）→ RRF 融合 → cross-encoder 精排 → 四维置信度整批准入
///
/// 置信度闸门**必须在精排之后**：只有 cross-encoder 的分数才是真相关度，
/// 拿 BM25 的近似分提前弃权会误杀，精排后再逐条平阈值砍会丢 recall。
///
///     LEETLENS_EVAL_CORPUS=… LEETLENS_EVAL_QUERIES=… \
///     LEETLENS_RERANK_BASE=https://<workspace>.cn-beijing.maas.aliyuncs.com \
///     LEETLENS_RERANK_KEY_FILE=~/.dashscope-key \
///     LEETLENS_RERANK_REPORT=/tmp/ab.txt swift test --filter RerankImpactTests
///
/// Key 只从文件读，不进源码、不进参数、不打印。报告写文件——xctest 会吞 stdout。
final class RerankImpactTests: XCTestCase {
    private struct Case: Decodable { let group: String; let query: String; let relevant: [String] }
    private struct Run { let testCase: Case; let ranked: [String] }
    private struct Metrics {
        let h1: Double, r1: Double, r3: Double, r5: Double, mrr: Double, neg: Double, lost: Int
    }

    private var report: [String] = []
    private func say(_ line: String) { report.append(line) }

    func testFullRetrievalPipeline() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let corpusPath = env["LEETLENS_EVAL_CORPUS"],
              let queryPath = env["LEETLENS_EVAL_QUERIES"],
              let apiBase = env["LEETLENS_RERANK_BASE"],
              let keyFile = env["LEETLENS_RERANK_KEY_FILE"],
              let reportPath = env["LEETLENS_RERANK_REPORT"]
        else { throw XCTSkip("缺少评测环境变量") }

        let apiKey = try String(contentsOfFile: NSString(string: keyFile).expandingTildeInPath, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let rerankModel = env["LEETLENS_RERANK_MODEL"] ?? "qwen3.7-text-rerank"
        let embedModel = env["LEETLENS_EMBED_MODEL"] ?? "text-embedding-v4"

        let conversations = try MemoryRetrievalEvalTests.conversations(atPath: corpusPath)
        let cases = try JSONDecoder().decode([Case].self, from: Data(contentsOf: URL(fileURLWithPath: queryPath)))
        let positives = cases.count { !$0.relevant.isEmpty }
        let negatives = cases.count { $0.relevant.isEmpty }

        // 第一路：BM25（现状基线）
        let lexical = ConversationMemoryIndex()
        _ = await lexical.synchronize(conversations: conversations)
        let chunks = await lexical.documentCount

        // 两路：BM25 + 千问向量，RRF 融合
        let embedder = try QwenConversationEmbeddingProvider(
            apiBase: apiBase, apiKey: apiKey, model: embedModel, dimension: 1_024)
        let hybrid = ConversationMemoryIndex(useSemanticEmbeddings: true, embeddingProvider: embedder)
        _ = await hybrid.synchronize(conversations: conversations)
        let dense = await hybrid.canReclaimVectors
        let embedded = await hybrid.lastSyncEmbeddingCount
        XCTAssertTrue(dense, "向量没灌完，dense 那一路是空的，融合会退化成单路 BM25")

        let reranker = try QwenTextReranker(apiBase: apiBase, apiKey: apiKey, model: rerankModel)
        say("语料 \(conversations.count) 会话 / \(chunks) chunk，向量 \(embedded) 条（\(embedModel)）")
        say("查询 \(positives) 正 + \(negatives) 负，精排 \(rerankModel)")

        // 规则层只分类。这里量两件事：规则能当场定案的有多少（省掉的模型调用），
        // 以及规则先验直接判成"不检索"的里面有没有误伤。
        let directory = ConversationMemoryDirectory.entries(from: conversations, excluding: "")
        var narrowSkipped = Set<String>(), productionSkipped = Set<String>()
        var wronglySkipped: [String] = []
        var settledCount = 0
        for testCase in cases {
            let c = ConversationIntentPolicy.classify(query: testCase.query, directory: directory)
            if c.certainty == .settled { settledCount += 1 }
            if c.intent == .smalltalk || c.intent == .meta { narrowSkipped.insert(testCase.query) }
            let prior = ConversationRoutePlan(
                route: ConversationRoute.route(for: c.intent), rerankAvailable: true
            )
            if c.certainty == .settled, !prior.retrievesMemory {
                productionSkipped.insert(testCase.query)
                if !testCase.relevant.isEmpty {
                    wronglySkipped.append("[\(c.intent.rawValue)] \(testCase.query)")
                }
            }
        }
        say("规则当场定案 \(settledCount)/\(cases.count)，其余交给模型路由")

        var bm25: [Run] = [], fused: [Run] = [], full: [Run] = [], production: [Run] = []
        var dump: [[String: Any]] = []
        for testCase in cases {
            let skip = narrowSkipped.contains(testCase.query)

            // ① BM25 单路 + 精排前置信度（现状）
            let lex = await lexical.search(query: testCase.query, currentConversationID: "", limit: 10)
            let lexOK = RetrievalConfidence.evaluate(lex, indexedChunkCount: chunks).isAcceptable
            bm25.append(Run(testCase: testCase, ranked: lexOK && !skip ? lex.map(\.conversationID) : []))

            // ② 两路 RRF 融合，不精排
            let fus = await hybrid.search(query: testCase.query, currentConversationID: "", limit: 10)
            let fusOK = RetrievalConfidence.evaluate(fus, indexedChunkCount: chunks).isAcceptable
            fused.append(Run(testCase: testCase, ranked: fusOK && !skip ? fus.map(\.conversationID) : []))

            // ③ 两路融合 → 精排 → 精排分进四维置信度 → 整批准入
            var ranked: [String] = []
            let poolSource = env["LEETLENS_POOL"] == "bm25" ? lexical : hybrid
            let pool = await poolSource.candidates(query: testCase.query, currentConversationID: "", limit: 24)
            if !pool.isEmpty {
                let hits = try await reranker.rerank(
                    query: testCase.query,
                    documents: pool.enumerated().map {
                        TextRerankDocument(id: String($0.offset), text: $0.element.content)
                    },
                    topN: pool.count
                )
                var seen = Set<String>()
                var scored: [ConversationMemoryMatch] = []
                for hit in hits where pool.indices.contains(hit.originalIndex) {
                    var match = pool[hit.originalIndex]
                    guard seen.insert(match.conversationID).inserted else { continue }
                    match.relevance = hit.relevanceScore   // 第一维换成 cross-encoder 的真分数
                    scored.append(match)
                }
                if RetrievalConfidence.admitsReranked(scored) {
                    ranked = scored.prefix(10).map(\.conversationID)
                }
                dump.append([
                    "query": testCase.query,
                    "positive": !testCase.relevant.isEmpty,
                    "relevant": testCase.relevant,
                    "scores": scored.map { ["id": $0.conversationID, "rerank": $0.relevance, "coverage": $0.coverage] }
                ])
            }
            full.append(Run(testCase: testCase, ranked: skip ? [] : ranked))
            production.append(Run(testCase: testCase,
                                  ranked: productionSkipped.contains(testCase.query) ? [] : ranked))
        }

        let a = Self.metrics(bm25), b = Self.metrics(fused)
        let c = Self.metrics(full), d = Self.metrics(production)
        say("")
        say("方案                       hit@1 rec@1 rec@3 rec@5    MRR 负例挡 误杀")
        for (name, m) in [("① BM25 单路", a), ("② 两路 RRF 融合", b),
                          ("③ ②＋精排＋精排后闸门", c), ("④ ③＋规则先验", d)] {
            say(name.padding(toLength: 26, withPad: " ", startingAt: 0)
                + [m.h1, m.r1, m.r3, m.r5].map { String(format: "%6.1f%%", $0 * 100) }.joined()
                + String(format: "%7.3f", m.mrr) + String(format: "%6.1f%%", m.neg * 100)
                + String(format: "%5d", m.lost))
        }
        say("")
        say("规则先验直接判成不检索、但其实有答案的 \(wronglySkipped.count)/\(positives)：")
        for q in wronglySkipped { say("  ✗ \(q)") }

        if let dumpPath = env["LEETLENS_RERANK_DUMP"] {
            try JSONSerialization.data(withJSONObject: dump, options: [.prettyPrinted])
                .write(to: URL(fileURLWithPath: NSString(string: dumpPath).expandingTildeInPath))
        }
        try report.joined(separator: "\n").write(
            toFile: NSString(string: reportPath).expandingTildeInPath, atomically: true, encoding: .utf8)

        guard env["LEETLENS_RERANK_DUMP"] == nil else { return }
        XCTAssertGreaterThanOrEqual(c.r5, a.r5, "全链路 recall@5 不允许低于 BM25 基线")
        XCTAssertGreaterThan(c.h1, a.h1, "精排必须把 hit@1 顶上去")
        XCTAssertEqual(c.neg, 1.0, accuracy: 0.0001, "负例该被全部拦下")
        XCTAssertEqual(c.lost, 0, "不该有查询丢掉自己的答案")
    }

    private static func metrics(_ runs: [Run]) -> Metrics {
        let pos = runs.filter { !$0.testCase.relevant.isEmpty }
        let neg = runs.filter { $0.testCase.relevant.isEmpty }
        func hit(_ k: Int) -> Double {
            Double(pos.count { r in r.ranked.prefix(k).contains { r.testCase.relevant.contains($0) } })
                / Double(pos.count)
        }
        func recall(_ k: Int) -> Double {
            pos.reduce(0.0) { acc, r in
                acc + Double(Set(r.ranked.prefix(k)).intersection(r.testCase.relevant).count)
                    / Double(r.testCase.relevant.count)
            } / Double(pos.count)
        }
        let mrr = pos.reduce(0.0) { acc, r in
            guard let i = r.ranked.firstIndex(where: { r.testCase.relevant.contains($0) }) else { return acc }
            return acc + 1.0 / Double(i + 1)
        } / Double(pos.count)
        return Metrics(
            h1: hit(1), r1: recall(1), r3: recall(3), r5: recall(5), mrr: mrr,
            neg: neg.isEmpty ? 1 : Double(neg.count { $0.ranked.isEmpty }) / Double(neg.count),
            lost: pos.count { $0.ranked.isEmpty })
    }
}
