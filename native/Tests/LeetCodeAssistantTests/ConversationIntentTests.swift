import Foundation
import XCTest
@testable import LeetCodeAssistant

/// 规则层零成本、每轮必跑。它不回答"指代的是谁"——那要上文；
/// 它只回答两件便宜的事：这一轮要不要检索，以及这是不是一句指代句。
final class ConversationIntentTests: XCTestCase {
    private func directory(_ titles: [String]) -> [ConversationMemoryDirectoryEntry] {
        titles.enumerated().map { index, title in
            ConversationMemoryDirectoryEntry(
                conversationID: "c\(index)", title: title, gist: "", updatedAt: .now
            )
        }
    }

    private func resolve(
        _ query: String,
        previous: ConversationIntentResolution? = nil,
        titles: [String] = [],
        hasHostContext: Bool = false
    ) -> ConversationIntentResolution {
        ConversationIntentPolicy.resolve(
            query: query,
            previous: previous,
            directory: directory(titles),
            hasHostContext: hasHostContext
        )
    }

    // MARK: - 不该检索的轮次

    /// 这里曾经断言"通用知识不检索"。真实语料把它推翻了：规则层分不清
    /// "快排怎么写"和"先排序再用左右两个指针往中间夹"——后者是用户在改述自己
    /// 上一轮的写法，字面上同样没有任何历史线索。那版兜底误拦 20/26 条正当检索，
    /// recall@5 从 98.1% 塌到 23.1%（`RerankImpactTests`）。
    ///
    /// 判断权交给 cross-encoder：精排后的整批准入在同一份语料上挡住 20/20 负例
    /// 且零误杀。规则层只负责排除明显不需要检索的轮次。
    func testGeneralKnowledgeDefersToTheReranker() {
        let result = resolve("快排怎么写")
        XCTAssertEqual(result.intent, .knowledge)
        XCTAssertTrue(result.wantsRetrieval, "规则层认不出来的，交给精排闸门判，别自己先毙掉")
        XCTAssertEqual(result.confidence, .confident, "确定的事不该再花一次模型调用")
    }

    func testSmalltalkAndMetaAreCheapAndRetrievalFree() {
        for query in ["你好", "谢谢", "收到"] {
            let result = resolve(query)
            XCTAssertEqual(result.intent, .smalltalk, query)
            XCTAssertFalse(result.wantsRetrieval, query)
        }
        let meta = resolve("你是什么模型")
        XCTAssertEqual(meta.intent, .meta)
        XCTAssertFalse(meta.wantsRetrieval)
    }

    func testHostContextMakesItACodeDebugTurnWithoutCrossConversationSearch() {
        let result = resolve("这段为什么超时", hasHostContext: true)
        XCTAssertEqual(result.intent, .codeDebug)
        XCTAssertFalse(result.wantsRetrieval, "当前代码已经随宿主上下文带上了")
    }

    // MARK: - 该检索的轮次

    func testExplicitHistoryCueAlwaysRetrievesAndRequestsCoreferenceResolution() {
        for query in ["上次我们说的那个", "你之前提过的写法", "帮我复盘一下"] {
            let result = resolve(query)
            XCTAssertTrue(result.wantsRetrieval, query)
            XCTAssertEqual(result.confidence, .ambiguous, "要检索是硬判定，但指代对象仍需结合上文改写")
        }
    }

    func testFirstPersonPersonalQuestionRetrieves() {
        let result = resolve("我哪块比较弱")
        XCTAssertEqual(result.intent, .profile)
        XCTAssertTrue(result.wantsRetrieval)
    }

    /// 用户自己的专有名词是"该检索"最强的廉价信号。
    /// 门槛是 4 个中文字（`mentionsDirectoryTerm` 的既有取值，宁可漏记不可错记），
    /// 所以"接雨水"这种三字题名靠目录词撞不上——那类要靠别的信号。
    func testDirectoryTermIsAStrongCheapSignal() {
        let result = resolve(
            "字母异位词分组当时是怎么做的",
            titles: ["字母异位词分组代码修正"]
        )
        XCTAssertTrue(result.wantsRetrieval)
        XCTAssertEqual(result.intent, .recall)
    }

    /// 三字题名撞不到目录门槛，但只要句子里有明确的历史线索照样检索——
    /// 两条信号是互补的，不能指望单独一条覆盖全部。
    func testShortProblemNameStillRetrievesThroughAnExplicitHistoryCue() {
        let result = resolve("接雨水那题上次我怎么错的", titles: ["接雨水单格积水切入方向"])
        XCTAssertTrue(result.wantsRetrieval)
    }

    // MARK: - 继承：规则层做不到、必须带上文的那部分

    func testFollowUpInheritsRetrievalFromTheRecallTurnBeforeIt() {
        let previous = resolve("上次我们说的那个")
        XCTAssertTrue(previous.wantsRetrieval)

        let followUp = resolve("那这个呢", previous: previous)
        XCTAssertEqual(followUp.intent, .followUp)
        XCTAssertTrue(followUp.wantsRetrieval, "同一句追问，跟在 recall 后面就要检索")
        XCTAssertEqual(followUp.confidence, .ambiguous, "继承只是先验，值得交给模型复核")
    }

    /// 继承机制本身还在，但"不检索"的来源只剩闲聊与 meta：
    /// 知识轮次现在也要检索，所以跟在它后面的追问同样要检索。
    func testFollowUpAfterSmalltalkStaysRetrievalFree() {
        let previous = resolve("你好")
        XCTAssertFalse(previous.wantsRetrieval)
        let followUp = resolve("那这个呢", previous: previous)
        XCTAssertEqual(followUp.intent, .followUp)
        XCTAssertFalse(followUp.wantsRetrieval, "跟在闲聊后面的追问没有可检索的东西")
    }

    /// 没有上一轮可继承时兜底成"要检索"。首轮就说"力扣 42 那道题"的人，
    /// 指代的必然在别的会话里，判成不检索必然答错。
    func testFollowUpWithoutAnyHistoryRetrieves() {
        let result = resolve("再详细点")
        XCTAssertEqual(result.intent, .followUp)
        XCTAssertTrue(result.wantsRetrieval, "无上文可继承时，宁可检索也不要凭空断定不需要")
        XCTAssertTrue(result.mentionsReference)
        XCTAssertEqual(result.confidence, .ambiguous, "指代谁仍然要上文，交给模型层复核")
    }

    /// 本句自带强信号时，继承必须被覆盖。
    func testStrongSignalOverridesInheritance() {
        let previous = resolve("快排怎么写")
        let result = resolve("上次那道题我怎么错的", previous: previous)
        XCTAssertTrue(result.wantsRetrieval, "本句已经明确指向历史，不能被继承压住")
    }

    func testZeroAnaphoraShortQuestionIsRecognisedAsAReference() {
        let previous = resolve("上次我们说的那个")
        let result = resolve("复杂度呢", previous: previous)
        XCTAssertEqual(result.intent, .followUp)
        XCTAssertTrue(result.mentionsReference, "中文常省略主语，也算指代")
        XCTAssertTrue(result.wantsRetrieval)
    }
}
