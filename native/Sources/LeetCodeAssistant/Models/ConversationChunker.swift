import Foundation

/// 对话写入 RAG 索引时使用的结构化投影。
///
/// 原始 message 是不可变事实源；这里生成的 chunk 只是检索投影，可以随切分版本重建。
/// 切分层级：会话摘要 → 一问一答的 turn → Markdown 块 → 完整语义单元。
///
/// 关键不变量：
/// - token 数只是**软预算**，从不拿字符位置当切点；
/// - 普通文本只在完整句子 / 完整列表项 / 段落边界切；
/// - overlap 只回带完整语义单元，绝不出现半句话；
/// - fenced code block 是原子单元，不从中间截断；
/// - `<think>`、内嵌图片和视觉代码不进入检索，但原始 message 完整保留在 ledger/会话存储里。
enum ConversationChunker {
    /// 每次改变检索投影语义都递增。进程内同步据此强制重建；磁盘向量仍按内容哈希安全复用。
    static let revision = 3

    struct Chunk: Equatable {
        var content: String
        var messageIDs: [String]
    }

    struct Limits: Equatable, Sendable {
        /// 软目标：攒到它就落块。不是硬上限——最后一个单元会让块略微超出，
        /// 单个句子或代码块本身更大时整体单独成块。
        var targetTokens = 360
        /// 最小块。低于它的残块并进相邻块，不单独入库：
        /// `**示例 2**` 这种只有标签、正文一个字都没有的块，在 BM25 里靠稀有词
        /// 也能挤进候选，纯属噪声，而元数据前缀还比正文长。
        var minimumTokens = 120
        /// 硬上限。只有"单个语义单元本身就超过它"时才允许突破——那种情况只能整块入库，
        /// 因为切开就会破坏"绝不切半句 / 绝不切断代码块"这条不变量。
        var maximumTokens = 620
        /// 重叠预算：目标块的 20%。实测旧值 56（约 15%）配合下面两条"放弃重叠"的
        /// 提前退出，真实语料上中位重叠率是 **0%**、57% 的相邻块完全不重叠——
        /// 等于重叠这件事名存实亡。
        var overlapTokens = 88
        /// 单条句子略超预算时允许带到 `overlapTokens * overlapSlack`。
        /// 再大就只能放弃——切开它就会产生半句话。
        var overlapSlack = 1.6

        static let standard = Limits()
    }

    private enum UnitKind: Equatable {
        case prose
        case code
    }

    private struct Unit: Equatable {
        let text: String
        let messageID: String?
        let role: String?
        let kind: UnitKind

        var tokens: Int { ConversationContextEstimator.estimateTextTokens(text) }
    }

    private struct Turn {
        var messages: [(id: String, role: String, text: String)] = []

        var question: String {
            guard let user = messages.first(where: { $0.role == "user" }) else { return "" }
            let units = semanticUnits(in: user.text, messageID: user.id, role: user.role)
            // 承接头也不截半句。第一句太长就只靠会话标题，不制造一条残句。
            guard let first = units.first(where: { $0.kind == .prose }), first.tokens <= 48 else { return "" }
            return first.text
        }
    }

    // MARK: - Public entry

    static func chunks(
        title: String,
        archive: [String],
        messages: [(id: String, role: String, content: String)],
        limits: Limits = .standard
    ) -> [Chunk] {
        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        var result: [Chunk] = []

        let archiveText = archive
            .map { sanitize($0, role: "assistant") }
            .filter { !$0.isEmpty }
            .reduce(into: [String]()) { values, value in
                if !values.contains(value) { values.append(value) }
            }
            .joined(separator: "\n")
        if !archiveText.isEmpty {
            let units = semanticUnits(in: archiveText, messageID: nil, role: nil)
            result.append(contentsOf: pack(
                units: units,
                title: cleanTitle,
                continuity: "会话摘要",
                limits: limits,
                carriesOverlap: false
            ))
        }

        for turn in turns(from: messages) {
            let units = turn.messages.flatMap { message in
                semanticUnits(in: message.text, messageID: message.id, role: message.role)
            }
            guard !units.isEmpty else { continue }
            result.append(contentsOf: pack(
                units: units,
                title: cleanTitle,
                continuity: turn.question,
                limits: limits,
                carriesOverlap: true
            ))
        }
        return result
    }

    // MARK: - Projection cleanup

    /// 清洗只作用于检索投影，绝不回写原消息。
    static func sanitize(_ source: String, role: String) -> String {
        var value = source
        if role == "assistant" {
            value = replacing(#"<think(?:\s+duration=\"\d+\")?>[\s\S]*?</think>"#, in: value, with: "")
            value = replacing(#"!\[[^\]\n]{0,160}\]\([^\)\n]+\)"#, in: value, with: "[图片]")
            value = replacing(#"<img\b[^>]*>"#, in: value, with: "[图片]")
            value = replacing(#"```(?:svg|mermaid)\s*[\s\S]*?```"#, in: value, with: "[已生成图解]")
        }
        return value
            .replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func replacing(_ pattern: String, in source: String, with replacement: String) -> String {
        source.replacingOccurrences(of: pattern, with: replacement, options: [.regularExpression, .caseInsensitive])
    }

    // MARK: - Turns

    private static func turns(from messages: [(id: String, role: String, content: String)]) -> [Turn] {
        var result: [Turn] = []
        var current = Turn()
        for message in messages where ["user", "assistant"].contains(message.role) {
            let text = sanitize(message.content, role: message.role)
            guard !text.isEmpty else { continue }
            if message.role == "user", !current.messages.isEmpty {
                result.append(current)
                current = Turn()
            }
            current.messages.append((message.id, message.role, text))
        }
        if !current.messages.isEmpty { result.append(current) }
        return result
    }

    // MARK: - Markdown-aware semantic units

    /// 代码块保持整体；普通段落切成完整句子；Markdown 列表的一整项算一个单元。
    private static func semanticUnits(in source: String, messageID: String?, role: String?) -> [Unit] {
        var result: [Unit] = []
        var proseLines: [String] = []
        var codeLines: [String] = []
        var inCode = false

        func appendProse() {
            guard !proseLines.isEmpty else { return }
            for block in proseBlocks(from: proseLines) where !block.isEmpty {
                if let rows = tableUnits(in: block) {
                    // 表格：整张放得下就整张进，放不下才按行切，且**每行都补回表头**。
                    // 不补表头的话 `| 融合 | 96.2% |` 单独出现时没人知道这几列是什么。
                    result.append(contentsOf: rows.map {
                        Unit(text: $0, messageID: messageID, role: role, kind: .prose)
                    })
                } else if isAtomicMarkdownBlock(block) {
                    // 列表项 + 它的缩进续行是一个语义单元。若再按句号切一次，
                    // "- 结论。\n  解释。" 仍会被劈开，等于前面的 Markdown 识别白做。
                    result.append(Unit(text: block, messageID: messageID, role: role, kind: .prose))
                } else {
                    result.append(contentsOf: sentences(in: block).map {
                        Unit(text: $0, messageID: messageID, role: role, kind: .prose)
                    })
                }
            }
            proseLines.removeAll(keepingCapacity: true)
        }

        for line in source.components(separatedBy: "\n") {
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                if inCode {
                    codeLines.append(line)
                    result.append(Unit(
                        text: codeLines.joined(separator: "\n"),
                        messageID: messageID,
                        role: role,
                        kind: .code
                    ))
                    codeLines.removeAll(keepingCapacity: true)
                    inCode = false
                } else {
                    appendProse()
                    codeLines.append(line)
                    inCode = true
                }
            } else if inCode {
                codeLines.append(line)
            } else {
                proseLines.append(line)
            }
        }
        // 历史里可能有流式中断留下的未闭合 fence。补一个闭合 fence，仍作为完整代码块处理。
        if !codeLines.isEmpty {
            codeLines.append("```")
            result.append(Unit(
                text: codeLines.joined(separator: "\n"),
                messageID: messageID,
                role: role,
                kind: .code
            ))
        }
        appendProse()
        return result
    }

    /// 列表项自身及其缩进续行必须保持原子性；token 预算只能决定它前后在哪落块，
    /// 不能把一项内部的"结论"和"解释"分开。
    /// 表格整张放得下就不拆。超过这个预算才按行切——
    /// 目标块 360，一张 240 token 的表整块进去仍留得下上下文。
    private static let tableWholeLimit = 240

    /// Markdown 表格识别。返回 nil 表示这不是表格。
    ///
    /// 判据要两条同时成立：每行都以 `|` 开头，且第二行是 `|---|---|` 这种分隔行。
    /// 只看 `|` 会把"竖线当分隔符的普通文本"误判成表格。
    private static func tableUnits(in block: String) -> [String]? {
        let lines = block.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard lines.count >= 3 else { return nil }
        guard lines.allSatisfy({ $0.hasPrefix("|") }) else { return nil }
        let separator = lines[1]
        guard separator.range(
            of: #"^\|(?:\s*:?-{2,}:?\s*\|)+$"#, options: .regularExpression
        ) != nil else { return nil }

        // 整张放得下就整块入库：拆开反而丢了行与行之间的对比关系。
        if ConversationContextEstimator.estimateTextTokens(block) <= tableWholeLimit {
            return [block]
        }
        let header = lines[0]
        let body = lines.dropFirst(2)
        guard !body.isEmpty else { return [block] }
        // 每行独立成单元，自带表头与分隔行——单独被召回时仍是一张合法的小表。
        return body.map { "\(header)\n\(separator)\n\($0)" }
    }

    private static func isAtomicMarkdownBlock(_ text: String) -> Bool {
        text.range(of: #"^\s*(?:[-*+]\s+|\d+[.)]\s+)"#, options: .regularExpression) != nil
    }

    /// 空行、标题、引用与列表项都是天然的语义边界。列表项的续行归到该项，不拆半项。
    private static func proseBlocks(from lines: [String]) -> [String] {
        var result: [String] = []
        var current: [String] = []
        let boundary = try? NSRegularExpression(pattern: #"^\s*(?:#{1,6}\s+|[-*+]\s+|\d+[.)]\s+|>\s+)"#)

        func flush() {
            let value = current.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !value.isEmpty { result.append(value) }
            current.removeAll(keepingCapacity: true)
        }

        for line in lines {
            if line.trimmingCharacters(in: .whitespaces).isEmpty {
                flush()
                continue
            }
            let range = NSRange(line.startIndex..<line.endIndex, in: line)
            if boundary?.firstMatch(in: line, range: range) != nil {
                flush()
                current.append(line)
            } else {
                current.append(line)
            }
        }
        flush()
        return result
    }

    // MARK: - Sentence boundaries

    /// 终止符和其后的引号/括号都留在本句；小数、域名和 `Math.abs` 的点不算句号。
    static func sentences(in source: String) -> [String] {
        var result: [String] = []
        var current = ""
        let terminators: Set<Character> = ["。", "！", "？", "；", "…", "\n", "!", "?", ";", "."]
        let closers: Set<Character> = ["”", "』", "」", "）", ")", "》", "\"", "'", "…"]
        let characters = Array(source)
        var index = 0

        while index < characters.count {
            let character = characters[index]
            current.append(character)
            index += 1
            guard terminators.contains(character) else { continue }
            if character == "." {
                let previous = index >= 2 ? characters[index - 2] : nil
                let next = index < characters.count ? characters[index] : nil
                // 小数、方法/域名、缩写的点都不是句末；英文句末通常后接空白或结束。
                if let next, !next.isWhitespace { continue }
                if previous?.isNumber == true, next?.isNumber == true { continue }
            }
            while index < characters.count,
                  terminators.contains(characters[index]) || closers.contains(characters[index]) {
                current.append(characters[index])
                index += 1
            }
            let value = current.trimmingCharacters(in: .whitespacesAndNewlines)
            if !value.isEmpty { result.append(value) }
            current = ""
        }
        let value = current.trimmingCharacters(in: .whitespacesAndNewlines)
        if !value.isEmpty { result.append(value) }
        return result
    }

    /// 给意图 / 指代小模型裁剪最近消息。复用和 RAG 切块同一套 Markdown 语义边界：
    /// 代码块、列表项、普通句子都只能整块进出，绝不因为预算从中间切开。
    static func semanticTail(in source: String, role: String, budgetTokens: Int) -> String? {
        guard budgetTokens > 0 else { return nil }
        let clean = sanitize(source, role: role)
        let units = semanticUnits(in: clean, messageID: nil, role: role)
        var selected: [Unit] = []
        var used = 0
        for unit in units.reversed() {
            guard unit.tokens <= budgetTokens, used + unit.tokens <= budgetTokens else { break }
            selected.append(unit)
            used += unit.tokens
        }
        guard !selected.isEmpty else { return nil }
        return selected.reversed().map(\.text).joined(separator: "\n")
    }

    static func semanticHead(in source: String, role: String, budgetTokens: Int) -> String? {
        guard budgetTokens > 0 else { return nil }
        let clean = sanitize(source, role: role)
        let units = semanticUnits(in: clean, messageID: nil, role: role)
        var selected: [Unit] = []
        var used = 0
        for unit in units {
            guard unit.tokens <= budgetTokens, used + unit.tokens <= budgetTokens else { break }
            selected.append(unit)
            used += unit.tokens
        }
        guard !selected.isEmpty else { return nil }
        return selected.map(\.text).joined(separator: "\n")
    }

    // MARK: - Packing with whole-unit overlap

    private static func pack(
        units: [Unit],
        title: String,
        continuity: String,
        limits: Limits,
        carriesOverlap: Bool
    ) -> [Chunk] {
        guard !units.isEmpty else { return [] }
        var result: [Chunk] = []
        var pending: [Unit] = []
        var pendingTokens = 0
        var isFirst = true

        func flush() {
            guard !pending.isEmpty else { return }
            result.append(render(
                units: pending,
                title: title,
                continuity: isFirst ? "" : continuity
            ))
            isFirst = false
            // overlap 只回带完整散文单元，代码永不作为重叠——见 overlapUnits。
            let overlap = carriesOverlap ? overlapUnits(from: pending, limits: limits) : []
            pending = overlap
            pendingTokens = overlap.reduce(0) { $0 + $1.tokens }
        }

        for unit in units {
            // 单个单元本身就超过硬上限（一整段长代码、一个超长段落）：它只能整块成块。
            // 先把手头攒的处理掉——够大就自己落一块，不够大就跟着这个大单元一起走，
            // 免得留下一个几十 token 的残块。
            if unit.tokens > limits.maximumTokens {
                if pendingTokens > 0, pendingTokens < limits.minimumTokens {
                    pending.append(unit)
                } else {
                    flush()
                    pending = [unit]
                }
                pendingTokens = pending.reduce(0) { $0 + $1.tokens }
                flush()
                pending.removeAll(keepingCapacity: true)
                pendingTokens = 0
                continue
            }

            // 加进来会突破硬上限：先落块。判断只在**完整单元之前**做，绝不切半句。
            if !pending.isEmpty, pendingTokens + unit.tokens > limits.maximumTokens {
                flush()
                if !pending.isEmpty, pendingTokens + unit.tokens > limits.maximumTokens {
                    // overlap 加新单元仍然放不下：丢掉 overlap，不为了重叠制造超大混合块。
                    pending.removeAll(keepingCapacity: true)
                    pendingTokens = 0
                }
            }

            pending.append(unit)
            pendingTokens += unit.tokens

            // 攒够目标就落块。这里**允许最后一个单元把块顶过 target**——
            // 旧实现是"加上会超就先落"，于是前一块永远停在 target 之下，
            // 真实语料上中位数只有 158，不到目标的一半。
            if pendingTokens >= limits.targetTokens { flush() }
        }
        flush()
        // 收尾残块太小就并进前一块：宁可最后一块偏大，也不留一个检索不动的碎片。
        if result.count >= 2, let last = result.last,
           ConversationContextEstimator.estimateTextTokens(last.content) < limits.minimumTokens {
            let tail = result.removeLast()
            let previous = result.removeLast()
            result.append(Chunk(
                content: previous.content + "\n" + strippedHeader(of: tail.content),
                messageIDs: previous.messageIDs + tail.messageIDs.filter { !previous.messageIDs.contains($0) }
            ))
        }
        return deduplicated(result)
    }

    /// 合并残块时去掉它自带的标题 / 承接头，避免同一块里出现两份元数据。
    private static func strippedHeader(of content: String) -> String {
        content
            .replacingOccurrences(of: #"(?m)\A【[^\n]+】\s*\n?"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"(?m)\A（承接问题：[^\n]+）\s*\n?"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 回带的重叠**永远是完整语义单元**：完整句子、完整列表项、或完整代码块。
    /// 任何情况下都不会出现半句话——这是切分层最硬的一条不变量。
    ///
    /// 三处曾让重叠静默归零，实测 57% 的相邻块因此完全不重叠：
    /// 1. 结尾是代码就直接 break。而"解释 + 代码"正是最常见的结尾形态。
    /// 2. 最后一句稍长就整个放弃，连它前面的短句也不再看。
    /// 3. 预算只有 56，约 15%。
    private static func overlapUnits(from units: [Unit], limits: Limits) -> [Unit] {
        let maximum = Int((Double(limits.overlapTokens) * limits.overlapSlack).rounded(.down))
        var result: [Unit] = []
        var tokens = 0

        for unit in units.reversed() {
            // 超预算的单元跳过，继续往前找放得下的——而不是就此放弃整个重叠。
            // 顺序仍然保持原文顺序（insert at 0），不会出现倒序拼接。
            // 超预算的单元跳过去继续往前找。只在**还没攒到任何东西**时才跳——
            // 已经攒到了就停，否则重叠会跨过一个大句子，拼出上下不相连的两段。
            guard unit.tokens <= maximum else {
                if result.isEmpty { continue } else { break }
            }
            guard tokens + unit.tokens <= maximum else { break }
            result.insert(unit, at: 0)
            tokens += unit.tokens
            if tokens >= limits.overlapTokens { break }
        }

        // 代码块可以作为重叠，但只在"它自己就够小"时——大段代码重复两遍既占预算
        // 又会让两块在 BM25 下几乎同分，失去区分度。
        if result.isEmpty, let last = units.last, last.kind == .code, last.tokens <= limits.overlapTokens {
            return [last]
        }
        return result
    }

    private static func render(units: [Unit], title: String, continuity: String) -> Chunk {
        var lines: [String] = []
        if !title.isEmpty { lines.append("【\(title)】") }
        if !continuity.isEmpty { lines.append("（承接问题：\(continuity)）") }

        var previousRole: String?
        var ids: [String] = []
        var seenIDs = Set<String>()
        for unit in units {
            var text = unit.text
            if let role = unit.role, role != previousRole {
                text = "\(role == "user" ? "用户" : "AI")：\(text)"
                previousRole = role
            }
            lines.append(text)
            if let id = unit.messageID, seenIDs.insert(id).inserted { ids.append(id) }
        }
        return Chunk(content: lines.joined(separator: "\n"), messageIDs: ids)
    }

    private static func deduplicated(_ chunks: [Chunk]) -> [Chunk] {
        var seen = Set<String>()
        return chunks.filter { chunk in
            let key = chunk.content.trimmingCharacters(in: .whitespacesAndNewlines)
            return !key.isEmpty && seen.insert(key).inserted
        }
    }
}
