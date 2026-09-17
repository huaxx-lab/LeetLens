import Foundation
import XCTest
@testable import LeetCodeAssistant

final class ChunkCorpusAuditTests: XCTestCase {
    func testPrivateCorpusChunkStatistics() throws {
        guard let corpusPath = ProcessInfo.processInfo.environment["LEETLENS_EVAL_CORPUS"] else {
            throw XCTSkip("设置 LEETLENS_EVAL_CORPUS 才审计真实语料切块")
        }
        let conversations = try MemoryRetrievalEvalTests.conversations(atPath: corpusPath)
        var chunks: [ConversationChunker.Chunk] = []
        for conversation in conversations {
            chunks += ConversationChunker.chunks(
                title: conversation.title,
                archive: [conversation.contextSummary, conversation.aiSummary, conversation.summary],
                messages: conversation.messages.map { ($0.id, $0.role, $0.content) }
            )
        }
        let tokens = chunks.map { ConversationContextEstimator.estimateTextTokens($0.content) }.sorted()
        func percentile(_ value: Double) -> Int {
            guard !tokens.isEmpty else { return 0 }
            return tokens[min(tokens.count - 1, Int((Double(tokens.count - 1) * value).rounded()))]
        }
        let thought = chunks.count { $0.content.contains("<think") }
        let svg = chunks.count { $0.content.localizedCaseInsensitiveContains("<svg") }
        let brokenFences = chunks.count { $0.content.components(separatedBy: "```").count.isMultiple(of: 2) }
        let oversized = tokens.count { $0 > ConversationChunker.Limits.standard.targetTokens * 2 }
        print("CHUNK_AUDIT conversations=\(conversations.count) chunks=\(chunks.count) min=\(tokens.first ?? 0) p25=\(percentile(0.25)) p50=\(percentile(0.5)) p75=\(percentile(0.75)) p90=\(percentile(0.9)) p99=\(percentile(0.99)) max=\(tokens.last ?? 0) oversized=\(oversized) think=\(thought) svg=\(svg) brokenFences=\(brokenFences)")
        XCTAssertEqual(thought, 0)
        XCTAssertEqual(svg, 0)
        XCTAssertEqual(brokenFences, 0)
    }
}
