import Foundation
import Testing
@testable import LeetCodeAssistant

@Suite("知识脑图")
struct KnowledgeGraphTests {
    private func record(
        id: String,
        title: String,
        path: [String],
        score: Double = 60,
        package: LearningStudyPackage? = nil
    ) -> LearningRecord {
        LearningRecord(
            id: id,
            kind: "knowledge",
            canonicalKey: "leetcode:\(id)",
            title: title,
            question: "",
            diagnosis: "",
            labels: [],
            prerequisiteLabels: [],
            knowledgePath: path,
            masteryScore: score,
            confidence: 0.5,
            evidenceCount: 1,
            evidence: [],
            sourceRefs: [],
            language: "java",
            dueAt: .now,
            reviewCount: 1,
            activeStudyPackage: package,
            latestAttempt: nil,
            activePackageAttemptCount: 0,
            updatedAt: .now
        )
    }

    @Test("知识路径拆成概念节点，题目挂在最后一级下")
    func derivesConceptChain() {
        let elements = KnowledgeGraphBuilder.derive(records: [
            record(id: "a", title: "三数之和", path: ["算法", "双指针"]),
            record(id: "b", title: "两数之和", path: ["算法", "哈希"])
        ])
        let ids = Set(elements.nodes.map(\.id))
        #expect(ids.contains(KnowledgeGraphBuilder.rootID))
        #expect(ids.contains(KnowledgeGraphBuilder.conceptID(path: ["算法"])))
        #expect(ids.contains(KnowledgeGraphBuilder.conceptID(path: ["算法", "双指针"])))
        #expect(ids.contains(KnowledgeGraphBuilder.nodeID(forRecord: "a")))
        // 「算法」只该出现一次，两条记录共用。
        #expect(elements.nodes.count { $0.title == "算法" } == 1)
        // 树边不带方向以外的语义，全是 tree 类型。
        #expect(elements.edges.allSatisfy { $0.type == "tree" })
    }

    @Test("没有知识路径的记录落到未分类，不会挂到根上")
    func fallsBackToUncategorized() {
        let elements = KnowledgeGraphBuilder.derive(records: [record(id: "a", title: "孤儿题", path: [])])
        let uncategorized = KnowledgeGraphBuilder.conceptID(path: ["未分类"])
        #expect(elements.nodes.contains { $0.id == uncategorized })
        #expect(
            elements.edges.contains {
                $0.source == uncategorized && $0.target == KnowledgeGraphBuilder.nodeID(forRecord: "a")
            }
        )
    }

    @Test("概念节点带下辖题目的平均掌握度")
    func aggregatesMastery() {
        let elements = KnowledgeGraphBuilder.derive(records: [
            record(id: "a", title: "A", path: ["算法"], score: 40),
            record(id: "b", title: "B", path: ["算法"], score: 80)
        ])
        let concept = elements.nodes.first { $0.id == KnowledgeGraphBuilder.conceptID(path: ["算法"]) }
        #expect(concept?.score == 60)
    }

    @Test("派生层没了的节点，人工层挂在上面的东西一起清掉")
    func reconcilesAgainstLiveNodes() {
        let deadRecord = KnowledgeGraphBuilder.nodeID(forRecord: "gone")
        let liveRecord = KnowledgeGraphBuilder.nodeID(forRecord: "alive")
        var overlay = KnowledgeGraphOverlay.empty
        overlay.childOrder = [
            deadRecord: ["gone-child"],
            liveRecord: [deadRecord, KnowledgeGraphBuilder.rootID]
        ]
        overlay.links = [
            .init(id: "l1", source: deadRecord, target: liveRecord),
            .init(id: "l2", source: liveRecord, target: KnowledgeGraphBuilder.rootID)
        ]
        overlay.noteCards = [
            .init(id: "note:1", anchorID: deadRecord, text: "挂在死节点上"),
            .init(id: "note:2", anchorID: liveRecord, text: "挂在活节点上")
        ]
        overlay.commentCards = [
            .init(id: "comment:1", anchorID: deadRecord, text: "死节点评论"),
            .init(id: "comment:2", anchorID: liveRecord, text: "活节点评论")
        ]

        let cleaned = overlay.reconciled(liveIDs: [liveRecord, KnowledgeGraphBuilder.rootID])
        // 评论已经并进笔记，所以死节点上的那条同样要被清掉。
        #expect(cleaned.commentCards.isEmpty)

        // 排序表里指向死节点的条目也要清掉，否则下次排布会按一个不存在的 id 排。
        #expect(cleaned.childOrder.keys.sorted() == [liveRecord])
        #expect(cleaned.childOrder[liveRecord] == [KnowledgeGraphBuilder.rootID])
        // 一端指向死节点的链接必须消失，否则画布上会留下指向空气的虚线。
        #expect(cleaned.links.map(\.id) == ["l2"])
        #expect(cleaned.noteCards.map(\.id) == ["note:2", "comment:2"])
    }

    @Test("旧版的单条笔记与笔记节点会迁进笔记卡片")
    func migratesLegacyNotes() {
        let anchor = KnowledgeGraphBuilder.nodeID(forRecord: "alive")
        var overlay = KnowledgeGraphOverlay.empty
        overlay.notes = [anchor: "旧的单条笔记"]
        overlay.customNodes = [.init(id: "note:1", title: "讲解片段", body: "正文", anchorID: anchor)]

        let migrated = overlay.migratingLegacy()

        #expect(migrated.notes.isEmpty)
        #expect(migrated.customNodes.isEmpty)
        #expect(migrated.noteCards.count == 2)
        #expect(migrated.noteCards.contains { $0.anchorID == anchor && $0.text == "旧的单条笔记" })
        #expect(migrated.noteCards.contains { $0.id == "note:1" && $0.text.contains("正文") })
        // 迁移必须幂等：读一次搬一次的话，每打开一回就多出一份重复笔记。
        #expect(migrated.migratingLegacy() == migrated)
    }

    @Test("一个节点可以挂多张笔记卡片")
    func keepsMultipleNotesPerNode() {
        let anchor = KnowledgeGraphBuilder.nodeID(forRecord: "alive")
        var overlay = KnowledgeGraphOverlay.empty
        overlay.noteCards = [
            .init(id: "n1", anchorID: anchor, text: "第一张"),
            .init(id: "n2", anchorID: anchor, text: "第二张"),
            .init(id: "n3", anchorID: "concept:别处", text: "别人的")
        ]

        #expect(overlay.noteCards(for: anchor).map(\.id) == ["n1", "n2"])
    }

    @Test("老版图文件缺少评论字段也能完整读取")
    func decodesOverlayWithoutComments() throws {
        let json = #"{"version":1,"revision":7,"links":[],"noteCards":[{"id":"n1","anchorID":"knowledge-root","text":"旧笔记","createdAt":"2026-08-12T00:00:00Z"}],"childOrder":{},"notes":{},"customNodes":[],"collapsed":[],"didSeedCollapse":true,"updatedAt":"2026-08-12T00:00:00Z"}"#
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let overlay = try decoder.decode(KnowledgeGraphOverlay.self, from: Data(json.utf8))
        #expect(overlay.revision == 7)
        #expect(overlay.noteCards.map(\.id) == ["n1"])
        #expect(overlay.commentCards.isEmpty)
    }

    @Test("旧版复盘评论并进笔记：只有一种「挂在节点上的一段话」")
    func mergesCommentsIntoNotes() {
        var overlay = KnowledgeGraphOverlay.empty
        let concept = KnowledgeGraphBuilder.conceptID(path: ["算法"])
        overlay.noteCards = [.init(id: "n1", anchorID: KnowledgeGraphBuilder.rootID, text: "全局策略")]
        overlay.commentCards = [
            .init(id: "c1", anchorID: KnowledgeGraphBuilder.rootID, text: "本周复盘"),
            .init(id: "c2", anchorID: concept, text: "双指针仍需练习"),
            .init(id: "c3", anchorID: concept, text: "   ")
        ]

        let migrated = overlay.migratingLegacy()

        #expect(migrated.commentCards.isEmpty)
        #expect(migrated.noteCards(for: KnowledgeGraphBuilder.rootID).map(\.id) == ["n1", "c1"])
        // 空白评论没有内容，搬过去只会变成一张点不动的空卡片。
        #expect(migrated.noteCards(for: concept).map(\.id) == ["c2"])
        // 迁移必须幂等：再读一次不能又多出一份重复笔记。
        #expect(migrated.migratingLegacy() == migrated)
        #expect(migrated.hasUserContent)
    }

    @Test("合流只加手工链接，笔记不再是独立节点")
    func mergesOverlayIntoElements() {
        let derived = KnowledgeGraphBuilder.derive(records: [record(id: "a", title: "A", path: ["算法"])])
        let anchor = KnowledgeGraphBuilder.nodeID(forRecord: "a")
        var overlay = KnowledgeGraphOverlay.empty
        overlay.noteCards = [.init(id: "note:1", anchorID: anchor, text: "正文")]
        overlay.links = [.init(id: "l1", source: anchor, target: KnowledgeGraphBuilder.conceptID(path: ["算法"]))]

        let merged = KnowledgeGraphBuilder.merge(derived: derived, overlay: overlay)

        // 笔记摞在锚点卡片里，不占一个节点，也不多出一条树边。
        #expect(!merged.nodes.contains { $0.id == "note:1" })
        #expect(merged.nodes.count == derived.nodes.count)
        #expect(merged.edges.contains { $0.id == "l1" && $0.type == "link" })
    }

    @Test("讲解来自学习包，没生成过就是空的")
    func lessonComesFromStudyPackage() {
        let plain = record(id: "a", title: "A", path: ["算法"])
        #expect(KnowledgeGraphBuilder.lessonMarkdown(plain).isEmpty)

        let package = LearningStudyPackage(
            id: "p1",
            lesson: LearningLesson(
                overview: "双指针从两端向内收缩",
                keyPoints: ["每次移动较矮的一侧"],
                pitfalls: ["别把面积算成两边之和"],
                example: "while (l < r) {}"
            ),
            exercise: LearningExercise(
                type: "short_answer", title: "", prompt: "p", instructions: "",
                language: "java", starterCode: "", choices: [], examples: [],
                constraints: [], rubric: [], referenceAnswer: ""
            ),
            generatedAt: .now,
            model: "test"
        )
        let withLesson = record(id: "a", title: "A", path: ["算法"], package: package)
        let markdown = KnowledgeGraphBuilder.lessonMarkdown(withLesson)
        #expect(markdown.contains("双指针从两端向内收缩"))
        #expect(markdown.contains("- 每次移动较矮的一侧"))
        #expect(markdown.contains("```java"))

        // 派生层直接带上讲解，脑图不另存一份副本。
        let elements = KnowledgeGraphBuilder.derive(records: [withLesson])
        let node = elements.nodes.first { $0.recordID == "a" }
        #expect(node?.lesson == markdown)
    }

    @Test("节点 id 稳定：同样的输入两次派生结果一致")
    func derivationIsStable() {
        let records = [
            record(id: "a", title: "A", path: ["算法", "双指针"]),
            record(id: "b", title: "B", path: ["算法"])
        ]
        let first = KnowledgeGraphBuilder.derive(records: records)
        let second = KnowledgeGraphBuilder.derive(records: records)
        #expect(first.nodes.map(\.id) == second.nodes.map(\.id))
        #expect(first.edges.map(\.id) == second.edges.map(\.id))
    }
}

@Suite("写代码时的 AI 提示")
struct CodingHintTests {
    private func decode(_ json: String) throws -> CodingHint {
        try JSONDecoder().decode(CodingHint.self, from: Data(json.utf8))
    }

    @Test("模型少给字段也不至于整条提示废掉")
    func toleratesMissingFields() throws {
        let hint = try decode(#"{"hint":"想想两端往中间收缩时面积怎么变"}"#)
        #expect(hint.hint.contains("收缩"))
        #expect(hint.title.isEmpty)
        #expect(hint.checkpoints.isEmpty)
        #expect(hint.question.isEmpty)
        #expect(hint.level == 1)
    }

    @Test("checkpoints 写成一句话也能收下")
    func acceptsCheckpointsAsString() throws {
        let hint = try decode(#"{"hint":"h","checkpoints":"先确认循环终止条件"}"#)
        #expect(hint.checkpoints == ["先确认循环终止条件"])
    }

    @Test("正常数组照收")
    func acceptsCheckpointArray() throws {
        let hint = try decode(#"{"hint":"h","checkpoints":["a","b"],"question":"为什么？","title":"方向"}"#)
        #expect(hint.checkpoints == ["a", "b"])
        #expect(hint.question == "为什么？")
        #expect(hint.title == "方向")
    }

    @Test("级别决定标题，1/2/3 分别是方向、卡点、下一步")
    func levelTitles() {
        #expect(CodingHint(level: 1).levelTitle == "方向")
        #expect(CodingHint(level: 2).levelTitle == "卡点")
        #expect(CodingHint(level: 3).levelTitle == "下一步")
    }

    @Test("确定性拦截完整代码，但允许一行定位提示")
    func rejectsSolutionLeakage() {
        #expect(!ChatService.codingHintLeaksSolution(CodingHint(
            hint: "检查 while (left < right) 的终止边界，并想想该移动哪一侧。"
        )))
        #expect(ChatService.codingHintLeaksSolution(CodingHint(
            hint: "完整代码如下：\n```java\nclass Solution { return answer; }\n```"
        )))
        #expect(ChatService.codingHintLeaksSolution(CodingHint(
            hint: "class Solution {\npublic int solve() {\nreturn 42;\n}\n}"
        )))
    }
}

@Suite("学习包的宽松解码")
struct LearningPackageDecodingTests {
    @Test("讲解少字段、给 null、把列表写成一句话都还能读出来")
    func tolerantLesson() throws {
        let json = #"{"overview":"双指针从两端收缩","keyPoints":"每次移动较矮的一侧","pitfalls":null}"#
        let lesson = try JSONDecoder().decode(LearningLesson.self, from: Data(json.utf8))
        #expect(lesson.overview == "双指针从两端收缩")
        #expect(lesson.keyPoints == ["每次移动较矮的一侧"])
        #expect(lesson.pitfalls.isEmpty)
        #expect(lesson.example.isEmpty)
        #expect(!lesson.isEmpty)
    }

    @Test("整份讲解都空才算真的没生成出来")
    func emptyLessonIsDetected() throws {
        let lesson = try JSONDecoder().decode(LearningLesson.self, from: Data("{}".utf8))
        #expect(lesson.isEmpty)
    }

    @Test("检测题缺字段不至于整包报废，题型有兜底")
    func tolerantExercise() throws {
        let json = #"{"prompt":"说说为什么移动较矮的一侧","choices":"A/B/C","rubric":[{"text":"讲清单调性"}]}"#
        let exercise = try JSONDecoder().decode(LearningExercise.self, from: Data(json.utf8))
        #expect(exercise.prompt.contains("较矮"))
        #expect(exercise.type == "short_answer")
        #expect(exercise.choices == ["A/B/C"])
        #expect(exercise.rubric == ["讲清单调性"])
        #expect(exercise.starterCode.isEmpty)
    }

    @Test("评分把分数写成字符串也认")
    func tolerantJudgment() throws {
        let json = #"{"score":"82","verdict":"pass","feedback":"思路对了","gaps":"边界没说清"}"#
        let judgment = try JSONDecoder().decode(LearningAttemptJudgment.self, from: Data(json.utf8))
        #expect(judgment.score == 82)
        #expect(judgment.gaps == ["边界没说清"])
        #expect(judgment.strengths.isEmpty)
    }
}
