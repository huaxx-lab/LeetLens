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
    static let revision = 2

    struct Chunk: Equatable {
        var content: String
        var messageIDs: [String]
    }

    struct Limits: Equatable, Sendable {
        /// 软目标：达到后，在**下一个完整语义单元之前**落块。
        /// 不是硬上限；一个句子或一个代码块本身更大时，整体单独成块。
        var targetTokens = 360
        /// 希望回带的上下文量。实际 overlap 为不超过该目标的若干完整语义单元；
        /// 最后一条完整句子稍大时允许带到 `overlapSlack`，再大则不重叠。
        var overlapTokens = 56
        var overlapSlack = 1.5

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
                if isAtomicMarkdownBlock(block) {
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
            let overlap = carriesOverlap ? overlapUnits(from: pending, limits: limits) : []
            pending = overlap
            pendingTokens = overlap.reduce(0) { $0 + $1.tokens }
        }

        for unit in units {
            // 代码和普通文本不粘在一起：代码单独成块，可按代码关键词准确召回；
            // 也避免下一块的 overlap 夹着半段代码语境。
            if unit.kind == .code {
                flush()
                result.append(render(
                    units: [unit],
                    title: title,
                    continuity: isFirst ? "" : continuity
                ))
                isFirst = false
                pending.removeAll(keepingCapacity: true)
                pendingTokens = 0
                continue
            }

            // 只在完整 unit 之前判断。即使本句本身超过 target，也整体放入，绝不切半句。
            if !pending.isEmpty, pendingTokens + unit.tokens > limits.targetTokens {
                flush()
                // 若 overlap 本身 + 新句仍放不下，先落掉 overlap；不能因为重叠制造一个超大混合块。
                if !pending.isEmpty, pendingTokens + unit.tokens > limits.targetTokens {
                    pending.removeAll(keepingCapacity: true)
                    pendingTokens = 0
                }
            }
            pending.append(unit)
            pendingTokens += unit.tokens
        }
        flush()
        return deduplicated(result)
    }

    /// 从尾部选择若干完整 prose unit。代码绝不作为 overlap；第一句过长就不重叠。
    private static func overlapUnits(from units: [Unit], limits: Limits) -> [Unit] {
        var result: [Unit] = []
        var tokens = 0
        let maximum = Int((Double(limits.overlapTokens) * limits.overlapSlack).rounded(.down))
        for unit in units.reversed() {
            guard unit.kind == .prose else { break }
            if result.isEmpty, unit.tokens > maximum { return [] }
            if !result.isEmpty, tokens + unit.tokens > limits.overlapTokens { break }
            result.insert(unit, at: 0)
            tokens += unit.tokens
            if tokens >= limits.overlapTokens { break }
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
