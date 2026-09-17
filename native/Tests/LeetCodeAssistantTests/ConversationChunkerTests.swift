import XCTest
@testable import LeetCodeAssistant

final class ConversationChunkerTests: XCTestCase {
    private let tight = ConversationChunker.Limits(
        targetTokens: 20,
        overlapTokens: 6,
        overlapSlack: 1.5
    )

    func testShortQuestionAndAnswerStayInOneChunk() {
        let chunks = make(messages: [
            ("u1", "user", "接雨水为什么要看左右最高柱子？"),
            ("a1", "assistant", "因为当前位置能装多少水，由较短的一侧决定。")
        ], limits: .standard)

        XCTAssertEqual(chunks.count, 1)
        XCTAssertEqual(chunks[0].messageIDs, ["u1", "a1"])
        XCTAssertTrue(chunks[0].content.contains("用户：接雨水为什么"))
        XCTAssertTrue(chunks[0].content.contains("AI：因为当前位置"))
    }

    func testOverlapContainsOnlyWholeSentences() {
        let source = "第一句说明背景。第二句给出条件。第三句解释原因。第四句写出结论。第五句补充边界。"
        let chunks = make(messages: [("a", "assistant", source)], limits: tight)
        XCTAssertGreaterThan(chunks.count, 1)

        let known = Set(ConversationChunker.sentences(in: source))
        for chunk in chunks {
            let body = chunk.content
                .components(separatedBy: "\n")
                .filter { !$0.hasPrefix("【") && !$0.hasPrefix("（承接问题：") }
                .joined(separator: "\n")
                .replacingOccurrences(of: "AI：", with: "")
            for sentence in ConversationChunker.sentences(in: body) {
                XCTAssertTrue(known.contains(sentence), "chunk 中出现了原文没有的半句：\(sentence)")
            }
        }

        func normalizedSentences(_ chunk: ConversationChunker.Chunk) -> Set<String> {
            let body = chunk.content
                .components(separatedBy: "\n")
                .filter { !$0.hasPrefix("【") && !$0.hasPrefix("（承接问题：") }
                .joined(separator: "\n")
                .replacingOccurrences(of: #"^(?:用户|AI)："#, with: "", options: .regularExpression)
                .replacingOccurrences(of: #"\n(?:用户|AI)："#, with: "\n", options: .regularExpression)
            return Set(ConversationChunker.sentences(in: body))
        }
        let firstSentences = normalizedSentences(chunks[0])
        let secondSentences = normalizedSentences(chunks[1])
        let overlap = firstSentences.intersection(secondSentences)
        XCTAssertFalse(overlap.isEmpty, "预算允许时应该重叠至少一个完整句子")
        XCTAssertTrue(overlap.allSatisfy(known.contains), "重叠必须来自原文的完整句子")
    }

    func testLongSingleSentenceIsNeverCutAtTokenBudget() {
        let sentence = "这是一个故意写得非常非常长而且没有任何中间句号的句子，用来证明软预算不会从一句话的中间砍断，即便它显著超过目标 token 数也要整体放进一个块里。"
        let chunks = make(messages: [("u", "user", sentence)], limits: tight)
        XCTAssertEqual(chunks.count, 1)
        XCTAssertTrue(chunks[0].content.contains(sentence))
    }

    func testMarkdownListItemAndContinuationStayAtomic() {
        let source = """
        建议如下：
        - 第一项有完整说明。
          这是第一项的续行，不能被拆成孤立上下文。
        - 第二项也有说明。
        """
        let chunks = make(messages: [("a", "assistant", source)], limits: tight)
        XCTAssertTrue(chunks.contains { chunk in
            chunk.content.contains("- 第一项有完整说明。")
                && chunk.content.contains("这是第一项的续行，不能被拆成孤立上下文。")
        })
    }

    func testFencedCodeBlockIsAtomicAndNotUsedAsOverlap() {
        let code = """
        ```java
        class Solution {
            int add(int a, int b) {
                return a + b;
            }
        }
        ```
        """
        let chunks = make(messages: [
            ("u", "user", "帮我看这段代码。"),
            ("a", "assistant", "先看完整函数。\n\(code)\n然后检查边界。最后给出结论。")
        ], limits: tight)
        let codeChunks = chunks.filter { $0.content.contains("class Solution") }
        XCTAssertEqual(codeChunks.count, 1, "完整代码块只能出现一次，不能作为 overlap 复制")
        XCTAssertEqual(codeChunks[0].content.components(separatedBy: "```").count - 1, 2)
        XCTAssertTrue(codeChunks[0].content.contains("return a + b;"))
    }

    func testUnclosedCodeFenceIsClosedAsOneAtomicBlock() {
        let chunks = make(messages: [("a", "assistant", "```java\nclass A {\n  void f() {}")], limits: tight)
        XCTAssertEqual(chunks.count, 1)
        XCTAssertTrue(chunks[0].content.hasSuffix("```"))
        XCTAssertEqual(chunks[0].content.components(separatedBy: "```").count - 1, 2)
    }

    func testRetrievalProjectionRemovesReasoningAndVisualPayloadsWithoutTouchingSource() {
        let source = """
        <think duration="42">内部推理不能进 RAG。还带有隐私式草稿。</think>
        正式答案第一句。正式答案第二句。
        ```svg
        <svg><path d="M0 0"/></svg>
        ```
        ![图](https://example.com/a.png)
        """
        let clean = ConversationChunker.sanitize(source, role: "assistant")
        XCTAssertFalse(clean.contains("内部推理"))
        XCTAssertFalse(clean.contains("<svg"))
        XCTAssertFalse(clean.contains("example.com"))
        XCTAssertTrue(clean.contains("正式答案第一句"))
        XCTAssertTrue(source.contains("内部推理"), "sanitize 只能返回投影，不能改原 message")
    }

    func testUserThinkLikeTextIsNotRemoved() {
        let source = "用户贴出来的 <think>字样</think> 是问题的一部分"
        XCTAssertEqual(ConversationChunker.sanitize(source, role: "user"), source)
    }

    func testSentenceBoundaryKeepsDecimalsAndMemberAccessTogether() {
        let source = "复杂度是 O(n)。Math.abs(x) 不应从点号切开。版本是 3.14。下一句。"
        XCTAssertEqual(ConversationChunker.sentences(in: source), [
            "复杂度是 O(n)。",
            "Math.abs(x) 不应从点号切开。",
            "版本是 3.14。",
            "下一句。"
        ])
    }

    func testChunkRevisionParticipatesInIndexRevision() async {
        let conversation = ConversationSummary(
            id: "c",
            title: "测试",
            summary: "",
            updatedAt: .now,
            messageCount: 2,
            messages: [
                ConversationTranscriptMessage(id: "u", role: "user", content: "第一句。第二句。", createdAt: .now),
                ConversationTranscriptMessage(id: "a", role: "assistant", content: "回答。", createdAt: .now)
            ]
        )
        let index = ConversationMemoryIndex(useSemanticEmbeddings: false)
        let first = await index.synchronize(conversations: [conversation])
        let second = await index.synchronize(conversations: [conversation])
        XCTAssertEqual(first.inserted, ["c"])
        XCTAssertTrue(second.updated.isEmpty)
        // 编译期常量本身不能在测试里改；这一条至少钉住 revision 存在且为正，
        // 以后改变切分语义时 review 能明确看到必须递增。
        XCTAssertGreaterThan(ConversationChunker.revision, 0)
    }

    private func make(
        messages: [(id: String, role: String, content: String)],
        limits: ConversationChunker.Limits
    ) -> [ConversationChunker.Chunk] {
        ConversationChunker.chunks(
            title: "测试会话",
            archive: [],
            messages: messages,
            limits: limits
        )
    }
}

// MARK: - 重叠必须是完整语义单元

extension ConversationChunkerTests {
    /// 最硬的一条不变量：重叠回带的永远是完整句子 / 完整列表项 / 完整代码块。
    func testOverlapNeverCarriesHalfASentence() {
        let answer = """
        先说结论：用双指针。第一步是排序，让相同的数挨在一起。\
        第二步左右夹逼，遇到重复就跳过。第三步注意边界，左指针不能越过右指针。\
        最后复杂度是 O(n^2)，排序那一步是 O(n log n)。
        """
        let chunks = ConversationChunker.chunks(
            title: "三数之和",
            archive: [],
            messages: [("u1", "user", "怎么做"), ("a1", "assistant", answer)],
            limits: .init(targetTokens: 40, minimumTokens: 10, maximumTokens: 80, overlapTokens: 16)
        )
        XCTAssertGreaterThan(chunks.count, 1, "语料要足够切成多块才验证得了重叠")

        for chunk in chunks {
            let body = chunk.content
                .components(separatedBy: "\n")
                .filter { !$0.hasPrefix("【") && !$0.hasPrefix("（承接问题：") }
                .joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !body.isEmpty, !body.contains("```") else { continue }
            // 正文必须以句末标点收尾——出现半句话说明切在了句子中间。
            let last = body.last.map(String.init) ?? ""
            XCTAssertTrue(
                "。！？；：".contains(last) || body.hasSuffix("）") || body.hasSuffix(")"),
                "出现半句：…\(body.suffix(24))"
            )
        }
    }

    /// 重叠必须保持原文顺序，不能把跨过大句子的两段拼在一起。
    func testOverlapKeepsSourceOrder() {
        let answer = "第一句很短。" + String(repeating: "这是一个非常长的句子需要占掉很多预算", count: 12) + "。最后一句也很短。"
        let chunks = ConversationChunker.chunks(
            title: "顺序",
            archive: [],
            messages: [("u1", "user", "问"), ("a1", "assistant", answer)],
            limits: .init(targetTokens: 60, minimumTokens: 10, maximumTokens: 120, overlapTokens: 20)
        )
        for chunk in chunks {
            if let a = chunk.content.range(of: "第一句很短。"),
               let b = chunk.content.range(of: "最后一句也很短。") {
                XCTAssertLessThan(a.lowerBound, b.lowerBound, "重叠拼接把原文顺序打乱了")
            }
        }
    }

    /// 碎块不单独入库：只有标签、正文一个字都没有的块是纯噪声。
    func testTinyFragmentsAreMergedInsteadOfIndexedAlone() {
        let answer = "**示例 1**\n\n```java\nint a = 1;\n```\n\n**示例 2**\n\n```java\nint b = 2;\n```"
        let chunks = ConversationChunker.chunks(
            title: "示例",
            archive: [],
            messages: [("u1", "user", "给例子"), ("a1", "assistant", answer)],
            limits: .init(targetTokens: 360, minimumTokens: 120, maximumTokens: 620)
        )
        for chunk in chunks {
            let body = chunk.content
                .components(separatedBy: "\n")
                .filter { !$0.hasPrefix("【") && !$0.hasPrefix("（承接问题：") && !$0.isEmpty }
                .joined()
            XCTAssertFalse(body == "AI：**示例 1**" || body == "AI：**示例 2**", "标签被单独切成一块")
        }
    }
}
