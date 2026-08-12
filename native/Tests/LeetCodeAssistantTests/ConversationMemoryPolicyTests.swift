import Foundation
import Testing
@testable import LeetCodeAssistant

@Suite("跨对话记忆分层")
struct ConversationMemoryPolicyTests {
    private func entry(
        id: String = "c1",
        title: String,
        gist: String = "",
        daysAgo: Int = 0
    ) -> ConversationMemoryDirectoryEntry {
        ConversationMemoryDirectoryEntry(
            conversationID: id,
            title: title,
            gist: gist,
            updatedAt: Date.now.addingTimeInterval(-Double(daysAgo) * 86_400)
        )
    }

    private var directory: [ConversationMemoryDirectoryEntry] {
        [
            entry(id: "c1", title: "三数之和排序双指针解法", gist: "去重边界"),
            entry(id: "c2", title: "Java栈与队列存储数组的用法", gist: "集合框架"),
            entry(id: "c3", title: "绘制鹈鹕骑自行车的SVG动画代码")
        ]
    }

    @Test("没有历史会话时不注入任何记忆")
    func emptyDirectoryInjectsNothing() {
        #expect(ConversationMemoryPolicy.tier(for: "上次我们聊到哪了", directory: []) == .none)
    }

    @Test("信息量过低的输入连目录都不给")
    func lowInformationSkipsEverything() {
        for query in ["好的", "谢谢", "嗯嗯", "行", "?"] {
            #expect(
                ConversationMemoryPolicy.tier(for: query, directory: directory) == .none,
                "\(query) 不该触发记忆注入"
            )
        }
    }

    @Test("通用知识问题只给目录，不跑全量检索")
    func generalQuestionStaysAtIndexTier() {
        #expect(
            ConversationMemoryPolicy.tier(for: "快速排序的平均时间复杂度是多少", directory: directory) == .index
        )
        #expect(
            ConversationMemoryPolicy.tier(for: "帮我写一个二分查找的模板", directory: directory) == .index
        )
    }

    @Test("指向历史的措辞升级到全量检索")
    func historyCuesEscalate() {
        for query in [
            "上次那个方案后来怎么改的",
            "我们讨论过的去重写法再讲一遍",
            "你之前提过一个更快的做法",
            "接着上面的思路继续优化一下"
        ] {
            #expect(
                ConversationMemoryPolicy.tier(for: query, directory: directory) == .retrieve,
                "\(query) 应该触发检索"
            )
        }
    }

    @Test("第一人称所有格升级到全量检索")
    func personalCuesEscalate() {
        #expect(
            ConversationMemoryPolicy.tier(for: "根据我最近的练习情况给点建议", directory: directory) == .retrieve
        )
        #expect(
            ConversationMemoryPolicy.tier(for: "我的代码里哪一步最费时间呢", directory: directory) == .retrieve
        )
    }

    @Test("命中会话标题里的专有名词就检索")
    func directoryTermEscalates() {
        // "三数之和" 是用户自己的历史话题，属于最强的廉价信号。
        #expect(
            ConversationMemoryPolicy.tier(for: "三数之和还有别的解法吗", directory: directory) == .retrieve
        )
        #expect(
            ConversationMemoryPolicy.tier(for: "svg 动画那段能改成循环播放吗", directory: directory) == .retrieve
        )
    }

    @Test("高频虚词不算命中，避免误检索")
    func stopTermsDoNotEscalate() {
        let noisy = [entry(title: "这个问题怎么实现比较好")]
        #expect(ConversationMemoryPolicy.tier(for: "红黑树怎么实现旋转", directory: noisy) == .index)
    }

    @Test("归一化剥掉标点与高频虚词")
    func normalizationStripsFiller() {
        #expect(ConversationMemoryPolicy.normalized("红黑树怎么实现旋转？") == "红黑树旋转")
        // "与" 是实义词的一部分，不剥；"用法"、"的" 才是噪声。
        #expect(ConversationMemoryPolicy.normalized("Java 栈与队列的用法") == "java栈与队列")
    }

    @Test("最长公共子串")
    func longestCommonSubstring() {
        #expect(ConversationMemoryPolicy.longestCommonSubstring("三数之和排序双指针", "三数之和还有别") == "三数之和")
        #expect(ConversationMemoryPolicy.longestCommonSubstring("abc", "xyz").isEmpty)
    }

    @Test("单个通用词重合不足以触发检索")
    func singleGenericTermStaysAtIndex() {
        let noisy = [
            entry(id: "a", title: "三数之和排序双指针解法"),
            entry(id: "b", title: "归并排序的稳定性")
        ]
        // 只共享 "排序" 两个字，够不到 4 字门槛，不该把旧会话拽出来。
        #expect(ConversationMemoryPolicy.tier(for: "堆排序的空间复杂度", directory: noisy) == .index)
    }

    @Test("单个足够长的稀有词可以触发检索")
    func distinctiveTermEscalates() {
        let directory = [entry(id: "a", title: "鹈鹕骑自行车动画")]
        #expect(ConversationMemoryPolicy.tier(for: "那个自行车动画能循环吗", directory: directory) == .retrieve)
    }

    @Test("目录置顶优先、其次按最近更新，并裁到上限")
    func directoryOrdersPinnedFirst() {
        let conversations = (0..<20).map { index in
            ConversationSummary(
                id: "c\(index)",
                title: "会话 \(index)",
                summary: "摘要 \(index)",
                updatedAt: Date.now.addingTimeInterval(-Double(index) * 60),
                messageCount: 2,
                messages: [
                    ConversationTranscriptMessage(
                        id: "m\(index)",
                        role: "user",
                        content: "内容",
                        createdAt: .now
                    )
                ],
                isPinned: index == 19
            )
        }
        let entries = ConversationMemoryDirectory.entries(from: conversations, excluding: "c0")
        #expect(entries.count == ConversationMemoryDirectory.entryLimit)
        #expect(entries.first?.conversationID == "c19")
        #expect(!entries.contains { $0.conversationID == "c0" })
    }

    @Test("目录提示词包含标题与概要，且标明不是事实来源")
    func directoryPromptShape() throws {
        let prompt = try #require(ConversationMemoryDirectory.prompt(for: directory))
        #expect(prompt.contains("三数之和排序双指针解法"))
        #expect(prompt.contains("去重边界"))
        #expect(prompt.contains("不是事实来源"))
    }
}
