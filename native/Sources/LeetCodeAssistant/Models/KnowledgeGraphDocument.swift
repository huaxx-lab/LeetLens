import Foundation

/// 脑图里"人加的那一层"：手工排序、链接、笔记卡片、折叠状态。
///
/// 派生层（知识点树、题目节点）永远由 `learningRecords` 现算，这一层只是覆盖在上面。
/// 两层分开存是为了让联动成立：AI 改了知识路径、或者某个知识点被删掉，
/// 派生层下一次读取就没有它了，这一层里挂在它身上的东西会被 `reconciled` 一起清掉，
/// 不会留下指向空气的虚线。
struct KnowledgeGraphOverlay: Codable, Sendable, Equatable {
    struct Link: Codable, Sendable, Equatable, Identifiable {
        var id: String
        var source: String
        var target: String
        var label: String = ""
        /// true = 单向（source → target），false = 双向。两者都画虚线，
        /// 靠箭头个数区分：单向一个头，双向两个头。
        var directed: Bool = false
        var createdAt: Date = .now
    }

    /// 挂在某个节点下面的一张笔记卡片。一个节点可以有多张，按加入顺序摞在卡片正文下面。
    ///
    /// `text` 是 Markdown 原文——渲染交给画布里的 markdown-it + highlight.js，
    /// 和聊天、题解用的是同一套轮子，所以代码块、列表、表格的样子处处一致。
    struct NoteCard: Codable, Sendable, Equatable, Identifiable {
        var id: String
        /// 挂在哪个节点上。锚点没了，这张卡片也就没有意义了。
        var anchorID: String
        var text: String
        var createdAt: Date = .now
    }

    /// 旧版遗留：曾经把"复盘评论"和"知识笔记"分成两种东西。
    ///
    /// 实际用下来它们是同一件事——都是挂在节点上的一段自己写的话，
    /// 分成两套只是让人每次都要先决定"这算笔记还是评论"。读到就迁进 `noteCards`，之后不再写。
    struct CommentCard: Codable, Sendable, Equatable, Identifiable {
        var id: String
        var anchorID: String
        var text: String
        var createdAt: Date = .now
    }

    /// 旧版遗留字段：一个节点只能存一条笔记。读到就迁进 `noteCards`，之后不再写。
    struct LegacyCustomNode: Codable, Sendable, Equatable {
        var id: String
        var title: String
        var body: String = ""
        var anchorID: String
        var createdAt: Date = .now
    }

    var version = 1
    /// 乐观锁：设置页、脑图页、导入按钮都可能写，对不上就合并而不是覆盖。
    var revision = 0
    /// 同一个父节点下，子节点的排列顺序。
    ///
    /// 拖卡片改的是这个，不是自由坐标：思维导图是排出来的，
    /// 一旦允许把卡片钉在任意位置，树一重排就到处是空洞和重叠。
    /// 没记到的子节点排在后面，保持派生顺序。
    var childOrder: [String: [String]] = [:]
    var links: [Link] = []
    var noteCards: [NoteCard] = []
    /// 旧版：复盘评论。只读不写，`migratingLegacy()` 会把它们并进 `noteCards`。
    var commentCards: [CommentCard] = []
    /// 旧版：节点 → 单条笔记。只读不写，`migratingLegacy()` 负责搬家。
    var notes: [String: String] = [:]
    /// 旧版：导入的讲解是一个独立子节点。同上，现在统一成笔记卡片。
    var customNodes: [LegacyCustomNode] = []
    /// 收起的节点。大图不折叠根本没法看，所以这是状态而不是临时 UI。
    var collapsed: [String] = []
    /// 是否已经设过默认折叠。第一次打开自动只留根与一级分支，
    /// 之后完全听用户的——包括用户把全部展开这种选择。
    var didSeedCollapse = false
    var updatedAt = Date.distantPast

    private enum CodingKeys: String, CodingKey {
        case version, revision, childOrder, links, noteCards, commentCards
        case notes, customNodes, collapsed, didSeedCollapse, updatedAt
    }

    init() {}

    /// 新字段一律按可选读取。`knowledge-graph.json` 是长期用户数据，升级应用时不能因为
    /// 老文件里没有 `commentCards` 就把整份人工笔记、链接和排序当成损坏数据丢掉。
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        version = try values.decodeIfPresent(Int.self, forKey: .version) ?? 1
        revision = try values.decodeIfPresent(Int.self, forKey: .revision) ?? 0
        childOrder = try values.decodeIfPresent([String: [String]].self, forKey: .childOrder) ?? [:]
        links = try values.decodeIfPresent([Link].self, forKey: .links) ?? []
        noteCards = try values.decodeIfPresent([NoteCard].self, forKey: .noteCards) ?? []
        commentCards = try values.decodeIfPresent([CommentCard].self, forKey: .commentCards) ?? []
        notes = try values.decodeIfPresent([String: String].self, forKey: .notes) ?? [:]
        customNodes = try values.decodeIfPresent([LegacyCustomNode].self, forKey: .customNodes) ?? []
        collapsed = try values.decodeIfPresent([String].self, forKey: .collapsed) ?? []
        didSeedCollapse = try values.decodeIfPresent(Bool.self, forKey: .didSeedCollapse) ?? false
        updatedAt = try values.decodeIfPresent(Date.self, forKey: .updatedAt) ?? .distantPast
    }

    static let empty = KnowledgeGraphOverlay()

    /// 把历史上那几种笔记形态统统搬进 `noteCards`。
    ///
    /// 旧版一个节点只能挂一条笔记，导入的讲解各自是一个独立子节点，复盘评论又是第三套；
    /// 现在只有一种东西——「挂在节点上的笔记卡片」，一个节点可以有好几张。
    /// 迁移就地做，用户不会看到自己写过的字凭空消失。
    func migratingLegacy() -> KnowledgeGraphOverlay {
        guard !notes.isEmpty || !customNodes.isEmpty || !commentCards.isEmpty else { return self }
        var result = self
        // 排序只是为了让迁移结果稳定，方便测。
        for (anchor, text) in notes.sorted(by: { $0.key < $1.key })
        where !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            result.noteCards.append(NoteCard(id: "note:legacy:\(anchor)", anchorID: anchor, text: text))
        }
        for custom in customNodes {
            let body = custom.body.trimmingCharacters(in: .whitespacesAndNewlines)
            let text = body.isEmpty ? custom.title : "**\(custom.title)**\n\n\(body)"
            result.noteCards.append(
                NoteCard(id: custom.id, anchorID: custom.anchorID, text: text, createdAt: custom.createdAt)
            )
        }
        // 评论沿用原来的 id：迁移因此是幂等的，同一条不会搬出两张卡片。
        for comment in commentCards
        where !comment.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            result.noteCards.append(
                NoteCard(
                    id: comment.id,
                    anchorID: comment.anchorID,
                    text: comment.text,
                    createdAt: comment.createdAt
                )
            )
        }
        result.notes = [:]
        result.customNodes = []
        result.commentCards = []
        return result
    }

    /// 丢掉所有指向不存在节点的东西。`liveIDs` 是派生层这一次算出来的全部节点。
    func reconciled(liveIDs: Set<String>) -> KnowledgeGraphOverlay {
        var result = migratingLegacy()
        result.noteCards = result.noteCards.filter { liveIDs.contains($0.anchorID) }
        result.links = result.links.filter { liveIDs.contains($0.source) && liveIDs.contains($0.target) }
        result.collapsed = result.collapsed.filter { liveIDs.contains($0) }
        result.childOrder = result.childOrder
            .filter { liveIDs.contains($0.key) }
            .mapValues { $0.filter { liveIDs.contains($0) } }
            .filter { !$0.value.isEmpty }
        return result
    }

    /// 某个节点下面的笔记卡片，按加入顺序。
    func noteCards(for nodeID: String) -> [NoteCard] {
        noteCards.filter { $0.anchorID == nodeID }
    }

    var hasUserContent: Bool {
        !links.isEmpty || !noteCards.isEmpty || !commentCards.isEmpty
            || !notes.isEmpty || !customNodes.isEmpty || !childOrder.isEmpty
    }
}

/// 脑图里真正被渲染的一个节点。派生层与人工层合流后的形态。
struct KnowledgeGraphElementNode: Equatable, Sendable {
    let id: String
    let title: String
    /// root / concept / record
    let kind: String
    /// 卡片里标题下面那行小字。思维导图的节点是带正文的卡片，不是光秃秃的气泡。
    let detail: String
    let score: Double?
    let haystack: String
    /// 题目节点才有；双击跳转要用。
    let recordID: String?
    /// AI 讲解（Markdown）。空 = 这道题还没生成过学习包。
    ///
    /// 讲解不是脑图自己的数据：它来自学习记录里的学习包，和今日复习、学习题库
    /// 读的是同一份。脑图只读、只在缺的时候请求补生成，不存副本——
    /// 存了副本就会出现"AI 讲解被改了脑图还是老的""同一道题生成两遍"。
    var lesson: String = ""
}

struct KnowledgeGraphElementEdge: Equatable, Sendable {
    let id: String
    let source: String
    let target: String
    /// tree（AI 派生的层级，实线）/ link（人工链接，虚线）
    let type: String
    let label: String
    /// 仅 link 有意义：单向为 true。
    var directed = false
}

struct KnowledgeGraphElements: Equatable, Sendable {
    var nodes: [KnowledgeGraphElementNode] = []
    var edges: [KnowledgeGraphElementEdge] = []

    var nodesByID: [String: KnowledgeGraphElementNode] {
        Dictionary(nodes.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    }
}

enum KnowledgeGraphBuilder {
    static let rootID = "knowledge-root"

    static func nodeID(forRecord id: String) -> String { "record:\(id)" }
    static func conceptID(path: [String]) -> String { "concept:" + path.joined(separator: "\u{1F}") }

    /// 派生层：知识路径拆成概念节点，题目挂在最后一级概念下。
    /// 纯函数，方便直接测。
    static func derive(records: [LearningRecord]) -> KnowledgeGraphElements {
        var nodes: [KnowledgeGraphElementNode] = []
        var edges: [KnowledgeGraphElementEdge] = []
        var seenConcepts: Set<String> = []
        var conceptScores: [String: (total: Double, count: Int)] = [:]

        nodes.append(
            KnowledgeGraphElementNode(
                id: rootID,
                title: "知识图谱",
                kind: "root",
                detail: "",
                score: nil,
                haystack: "知识图谱",
                recordID: nil
            )
        )

        for record in records {
            let path = record.knowledgePath
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            let normalized = path.isEmpty ? ["未分类"] : path
            var parentID = rootID
            var prefix: [String] = []

            for part in normalized {
                prefix.append(part)
                let id = conceptID(path: prefix)
                if seenConcepts.insert(id).inserted {
                    nodes.append(
                        KnowledgeGraphElementNode(
                            id: id,
                            title: part,
                            kind: "concept",
                            detail: "",
                            score: nil,
                            haystack: prefix.joined(separator: " "),
                            recordID: nil
                        )
                    )
                    edges.append(
                        KnowledgeGraphElementEdge(
                            id: "tree:\(parentID)->\(id)",
                            source: parentID,
                            target: id,
                            type: "tree",
                            label: ""
                        )
                    )
                }
                conceptScores[id, default: (0, 0)].total += record.effectiveMastery()
                conceptScores[id, default: (0, 0)].count += 1
                parentID = id
            }

            let recordNode = nodeID(forRecord: record.id)
            nodes.append(
                KnowledgeGraphElementNode(
                    id: recordNode,
                    title: record.title,
                    kind: "record",
                    // 卡片正文优先用诊断，没有就退回掌握度与证据数——
                    // 参考的思维导图节点都是带正文的卡片，只放标题信息量太薄。
                    // 不截断：截了就是"显示不全"，卡片会自己长高。
                    detail: record.diagnosis.isEmpty
                        ? "掌握 \(Int(record.effectiveMastery().rounded()))% · \(record.evidenceCount) 条证据"
                        : record.diagnosis,
                    // 脑图上的掌握度也按遗忘曲线折算，和今日复习、学习洞察是同一个数。
                    score: record.effectiveMastery(),
                    haystack: ([record.title] + record.labels + record.knowledgePath).joined(separator: " "),
                    recordID: record.id,
                    lesson: lessonMarkdown(record)
                )
            )
            edges.append(
                KnowledgeGraphElementEdge(
                    id: "tree:\(parentID)->\(recordNode)",
                    source: parentID,
                    target: recordNode,
                    type: "tree",
                    label: ""
                )
            )
        }

        // 概念节点也带上平均掌握度，弱项分组一眼能看出来。
        nodes = nodes.map { node in
            guard node.kind == "concept", let aggregate = conceptScores[node.id], aggregate.count > 0 else {
                return node
            }
            return KnowledgeGraphElementNode(
                id: node.id,
                title: node.title,
                kind: node.kind,
                detail: "\(aggregate.count) 项 · 平均 \(Int((aggregate.total / Double(aggregate.count)).rounded()))%",
                score: aggregate.total / Double(aggregate.count),
                haystack: node.haystack,
                recordID: nil
            )
        }
        return KnowledgeGraphElements(nodes: nodes, edges: edges)
    }

    /// 学习包里的讲解拼成 Markdown。
    ///
    /// 画布用的是项目里同一套 markdown-it + highlight.js，所以代码块、列表的样子
    /// 和聊天、题解完全一致，不用再养一套渲染逻辑。
    static func lessonMarkdown(_ record: LearningRecord) -> String {
        guard let lesson = record.activeStudyPackage?.lesson else { return "" }
        var parts: [String] = []
        let overview = lesson.overview.trimmingCharacters(in: .whitespacesAndNewlines)
        if !overview.isEmpty { parts.append(overview) }
        let points = lesson.keyPoints.filter { !$0.isEmpty }
        if !points.isEmpty {
            parts.append("**要点**\n" + points.map { "- \($0)" }.joined(separator: "\n"))
        }
        let pitfalls = lesson.pitfalls.filter { !$0.isEmpty }
        if !pitfalls.isEmpty {
            parts.append("**易错**\n" + pitfalls.map { "- \($0)" }.joined(separator: "\n"))
        }
        let example = lesson.example.trimmingCharacters(in: .whitespacesAndNewlines)
        if !example.isEmpty {
            // example 有时本身就带围栏，别再套一层，否则渲染出来是一坨反引号。
            parts.append(
                example.hasPrefix("```")
                    ? example
                    : "```\(record.language.isEmpty ? "text" : record.language)\n\(example)\n```"
            )
        }
        return parts.joined(separator: "\n\n")
    }

    /// 首次打开时的默认折叠：只留根和一级分支展开。
    /// 几十上百个节点全铺开时，缩到能看全整棵树，字就已经小到读不了了。
    static func defaultCollapsed(elements: KnowledgeGraphElements) -> [String] {
        var parentOf: [String: String] = [:]
        var hasChildren: Set<String> = []
        for edge in elements.edges where edge.type == "tree" {
            parentOf[edge.target] = edge.source
            hasChildren.insert(edge.source)
        }
        return elements.nodes.compactMap { node -> String? in
            guard hasChildren.contains(node.id) else { return nil }
            var depth = 0
            var cursor = node.id
            while let parent = parentOf[cursor], depth < 12 {
                cursor = parent
                depth += 1
            }
            return depth >= 1 ? node.id : nil
        }
    }

    /// 派生层 + 人工层合流。传进来的 overlay 应当已经 `reconciled` 过。
    ///
    /// 笔记不再是独立节点：它们摞在锚点卡片的正文下面，由画布那边渲染，
    /// 所以这里只合手工链接。
    static func merge(
        derived: KnowledgeGraphElements,
        overlay: KnowledgeGraphOverlay
    ) -> KnowledgeGraphElements {
        var result = derived
        for link in overlay.links {
            result.edges.append(
                KnowledgeGraphElementEdge(
                    id: link.id,
                    source: link.source,
                    target: link.target,
                    type: "link",
                    label: link.label,
                    directed: link.directed
                )
            )
        }
        return result
    }
}

/// `knowledge-graph.json` 的读写。和长期记忆一样用结构化文件而不是黑盒存储：
/// 用户能直接打开看、能改、能删。
actor KnowledgeGraphStore {
    static let shared = KnowledgeGraphStore()

    private var cache: [String: KnowledgeGraphOverlay] = [:]

    private func key(_ dataDirectory: URL) -> String { dataDirectory.standardizedFileURL.path }

    func overlay(dataDirectory: URL) -> KnowledgeGraphOverlay {
        if let cached = cache[key(dataDirectory)] { return cached }
        let loaded = load(dataDirectory: dataDirectory)
        cache[key(dataDirectory)] = loaded
        return loaded
    }

    /// `mutate` 拿到的是磁盘上的最新版本，所以并发写不会互相盖掉。
    @discardableResult
    func update(
        dataDirectory: URL,
        _ mutate: @Sendable (inout KnowledgeGraphOverlay) -> Void
    ) -> KnowledgeGraphOverlay {
        var current = load(dataDirectory: dataDirectory)
        mutate(&current)
        current.revision += 1
        current.updatedAt = .now
        persist(current, dataDirectory: dataDirectory)
        cache[key(dataDirectory)] = current
        return current
    }

    private func load(dataDirectory: URL) -> KnowledgeGraphOverlay {
        let url = dataDirectory.appending(path: "knowledge-graph.json")
        let decoder = JSONDecoder()
        // 必须和 `persist` 的编码策略一致，否则写出去的 ISO8601 读回来会解不出。
        decoder.dateDecodingStrategy = .iso8601
        guard let data = try? Data(contentsOf: url),
              let document = try? decoder.decode(KnowledgeGraphOverlay.self, from: data)
        else { return .empty }
        // 迁移是幂等的（id 由锚点决定），所以放在读的这一侧最省事：
        // 老文件不用等到有人写才转过来。
        return document.migratingLegacy()
    }

    private func persist(_ overlay: KnowledgeGraphOverlay, dataDirectory: URL) {
        try? FileManager.default.createDirectory(
            at: dataDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let url = dataDirectory.appending(path: "knowledge-graph.json")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(overlay) else { return }
        try? data.write(to: url, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
