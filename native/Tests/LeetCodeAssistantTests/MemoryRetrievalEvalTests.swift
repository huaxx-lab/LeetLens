import Foundation
import XCTest
@testable import LeetCodeAssistant

/// 跨会话召回的离线评测。
///
/// 语料和查询集都不进仓库——语料是用户自己的对话。跑法：
///
///     LEETLENS_EVAL_CORPUS=~/Library/.../conversations.json \
///     LEETLENS_EVAL_QUERIES=/path/to/rag-queries.json \
///     swift test --filter MemoryRetrievalEvalTests
///
/// 没设环境变量就跳过，常规 `swift test` 不受影响。
/// 指标：命中率 hit@k（前 k 条里有没有正确会话）、recall@k（召回了几成正确会话）、
/// MRR（第一条正确结果排名的倒数），外加负例的"该空就空"通过率。
final class MemoryRetrievalEvalTests: XCTestCase {
    private struct Case: Decodable {
        let group: String
        let query: String
        let relevant: [String]
    }

    private struct Outcome {
        let testCase: Case
        let ranked: [String]
    }

    func testRetrievalQuality() async throws {
        guard let corpusPath = ProcessInfo.processInfo.environment["LEETLENS_EVAL_CORPUS"],
              let queryPath = ProcessInfo.processInfo.environment["LEETLENS_EVAL_QUERIES"]
        else { throw XCTSkip("设置 LEETLENS_EVAL_CORPUS 与 LEETLENS_EVAL_QUERIES 才跑评测") }

        let conversations = try Self.conversations(atPath: corpusPath)
        let cases = try JSONDecoder().decode([Case].self, from: Data(contentsOf: URL(fileURLWithPath: queryPath)))
        XCTAssertFalse(conversations.isEmpty, "语料是空的")

        // 索引只建一次：每条查询重建一遍要把整个语料重新向量化。
        let index = ConversationMemoryIndex()
        _ = await index.synchronize(conversations: conversations)

        var outcomes: [Outcome] = []
        for testCase in cases {
            let matches = await index.search(query: testCase.query, currentConversationID: "", limit: 10)
            // 走生产同一条闸门：评测数字必须反映用户真正会看到的结果。
            let indexedChunks = await index.documentCount
            let admitted = RetrievalConfidence.evaluate(matches, indexedChunkCount: indexedChunks)
                .isAcceptable ? matches : []
            outcomes.append(Outcome(testCase: testCase, ranked: admitted.map(\.conversationID)))
        }
        let summary = Self.report(outcomes, corpusSize: conversations.count)
        // 指标直接断言，不靠 print——xctest 会吞 stdout，靠肉眼看日志不可靠。
        // 这几条是真实语料上已经达到的水平，掉下去就是回归。
        XCTAssertGreaterThanOrEqual(summary.hit3, 0.90, "前 3 名命中率回归了")
        XCTAssertGreaterThanOrEqual(summary.recall5, 0.95, "recall@5 回归了")
        XCTAssertGreaterThanOrEqual(summary.mrr, 0.85, "排序质量回归了")
        XCTAssertGreaterThanOrEqual(summary.negativePass, 0.85, "负例拦截率回归了")
        XCTAssertEqual(summary.emptyRate, 0, accuracy: 0.0001, "有答案的查询不该被闸门拦掉")
    }

    struct Summary {
        let hit1: Double, hit3: Double, recall5: Double
        let mrr: Double, emptyRate: Double, negativePass: Double
    }

    // MARK: - 指标

    @discardableResult
    private static func report(_ outcomes: [Outcome], corpusSize: Int) -> Summary {
        let answered = outcomes.filter { !$0.testCase.relevant.isEmpty }
        let negatives = outcomes.filter { $0.testCase.relevant.isEmpty }

        func hitRate(at k: Int) -> Double {
            guard !answered.isEmpty else { return 0 }
            let hits = answered.count { outcome in
                outcome.ranked.prefix(k).contains { outcome.testCase.relevant.contains($0) }
            }
            return Double(hits) / Double(answered.count)
        }
        func recall(at k: Int) -> Double {
            guard !answered.isEmpty else { return 0 }
            let total = answered.reduce(0.0) { partial, outcome in
                let found = outcome.ranked.prefix(k).filter { outcome.testCase.relevant.contains($0) }
                return partial + Double(Set(found).count) / Double(outcome.testCase.relevant.count)
            }
            return total / Double(answered.count)
        }
        let mrr = answered.isEmpty ? 0 : answered.reduce(0.0) { partial, outcome in
            guard let rank = outcome.ranked.firstIndex(where: { outcome.testCase.relevant.contains($0) })
            else { return partial }
            return partial + 1.0 / Double(rank + 1)
        } / Double(answered.count)
        let emptyRate = answered.isEmpty ? 0 : Double(answered.count { $0.ranked.isEmpty }) / Double(answered.count)
        let negativePass = negatives.isEmpty ? 1 : Double(negatives.count { $0.ranked.isEmpty }) / Double(negatives.count)

        print("""

        ╔═══════════════════════════════════════════════
        ║ 语料 \(corpusSize) 个会话 · 查询 \(outcomes.count) 条（有答案 \(answered.count) / 负例 \(negatives.count)）
        ╠═══════════════════════════════════════════════
        ║ hit@1   \(pct(hitRate(at: 1)))      recall@1  \(pct(recall(at: 1)))
        ║ hit@3   \(pct(hitRate(at: 3)))      recall@3  \(pct(recall(at: 3)))
        ║ hit@5   \(pct(hitRate(at: 5)))      recall@5  \(pct(recall(at: 5)))
        ║ MRR@10  \(String(format: "%.3f", mrr))
        ║ 一条都没召回 \(pct(emptyRate))   负例该空就空 \(pct(negativePass))
        ╚═══════════════════════════════════════════════
        """)

        for group in Array(NSOrderedSet(array: outcomes.map(\.testCase.group))).compactMap({ $0 as? String }) {
            print("\n【\(group)】")
            for outcome in outcomes where outcome.testCase.group == group {
                let rank = outcome.ranked.firstIndex { outcome.testCase.relevant.contains($0) }
                let verdict: String
                if outcome.testCase.relevant.isEmpty {
                    verdict = outcome.ranked.isEmpty ? "✓ 空" : "✗ 返回了 \(outcome.ranked.count) 条"
                } else if let rank {
                    verdict = "✓ 第 \(rank + 1) 名"
                } else {
                    verdict = outcome.ranked.isEmpty ? "✗ 没召回（被门槛拦掉）" : "✗ 前 10 名里没有"
                }
                print("  \(verdict.padding(toLength: 22, withPad: " ", startingAt: 0)) \(outcome.testCase.query)")
            }
        }
        return Summary(
            hit1: hitRate(at: 1), hit3: hitRate(at: 3), recall5: recall(at: 5),
            mrr: mrr, emptyRate: emptyRate, negativePass: negativePass
        )
    }

    private static func pct(_ value: Double) -> String {
        String(format: "%5.1f%%", value * 100)
    }

    // MARK: - 语料

    static func conversations(atPath path: String) throws -> [ConversationSummary] {
        let expanded = NSString(string: path).expandingTildeInPath
        let data = try Data(contentsOf: URL(fileURLWithPath: expanded))
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }
        return root.compactMap { id, value in
            guard let value = value as? [String: Any] else { return nil }
            let messages = (value["messages"] as? [[String: Any]] ?? []).compactMap { raw -> ConversationTranscriptMessage? in
                guard let role = raw["role"] as? String, let content = raw["content"] as? String else { return nil }
                return ConversationTranscriptMessage(
                    id: raw["id"] as? String ?? UUID().uuidString,
                    role: role,
                    content: content,
                    createdAt: date(raw["createdAt"])
                )
            }
            return ConversationSummary(
                id: id,
                title: value["title"] as? String ?? "",
                summary: value["summary"] as? String ?? "",
                updatedAt: date(value["updatedAt"]),
                messageCount: messages.count,
                messages: messages
            )
        }
    }

    private static func date(_ value: Any?) -> Date {
        guard let milliseconds = (value as? NSNumber)?.doubleValue else { return .now }
        return Date(timeIntervalSince1970: milliseconds / 1_000)
    }
}
