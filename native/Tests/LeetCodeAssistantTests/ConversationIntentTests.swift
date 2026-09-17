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

    func testGeneralKnowledgeDoesNotTriggerRetrieval() {
        let result = resolve("快排怎么写")
        XCTAssertEqual(result.intent, .knowledge)
        XCTAssertFalse(result.wantsRetrieval, "通用知识问题不该去翻旧会话")
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

    func testExplicitHistoryCueAlwaysRetrieves() {
        for query in ["上次我们说的那个", "你之前提过的写法", "帮我复盘一下"] {
            let result = resolve(query)
            XCTAssertTrue(result.wantsRetrieval, query)
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

    func testTheSameFollowUpAfterAKnowledgeTurnDoesNotRetrieve() {
        let previous = resolve("快排怎么写")
        let followUp = resolve("那这个呢", previous: previous)
        XCTAssertEqual(followUp.intent, .followUp)
        XCTAssertFalse(followUp.wantsRetrieval, "跟在通用知识后面就不必检索")
    }

    func testFollowUpWithoutAnyHistoryDoesNotInventANeed() {
        let result = resolve("再详细点")
        XCTAssertEqual(result.intent, .followUp)
        XCTAssertFalse(result.wantsRetrieval)
        XCTAssertTrue(result.mentionsReference)
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
