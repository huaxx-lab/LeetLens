import Foundation

/// AI 在编辑器里就地标注的一处问题：哪几行、为什么错、改成什么。
///
/// 行号 1 起算、闭区间。`original` 是生成那一刻这几行的原文——用户之后改了代码，
/// 行号会漂，靠它在附近重新找到位置；找不到就说明这几行已经被改过，建议作废。
struct CodeReviewSuggestion: Identifiable, Hashable, Codable, Sendable {
    enum Severity: String, Codable, Sendable {
        /// 编译 / 运行必错。
        case error
        /// 逻辑或边界问题，会导致答案错误。
        case warning
        /// 性能或写法建议。
        case hint
    }

    var id: String
    var startLine: Int
    var endLine: Int
    var severity: Severity
    var title: String
    var explanation: String
    var original: String
    var replacement: String
}

/// 模型原样吐出来的一条。字段全部宽松解码：少一个键不该让整批建议作废。
struct CodeReviewRawIssue: Decodable, Sendable {
    var startLine = 0
    var endLine = 0
    var severity = ""
    var title = ""
    var explanation = ""
    var original = ""
    var replacement = ""

    private enum CodingKeys: String, CodingKey {
        case startLine, endLine, severity, title, explanation, original, replacement, line
    }

    init(startLine: Int, endLine: Int, severity: String = "error", title: String = "", explanation: String = "", original: String, replacement: String) {
        self.startLine = startLine
        self.endLine = endLine
        self.severity = severity
        self.title = title
        self.explanation = explanation
        self.original = original
        self.replacement = replacement
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let single = Self.int(container, .line)
        startLine = Self.int(container, .startLine) ?? single ?? 0
        endLine = Self.int(container, .endLine) ?? startLine
        severity = (try? container.decodeIfPresent(String.self, forKey: .severity)) ?? ""
        title = (try? container.decodeIfPresent(String.self, forKey: .title)) ?? ""
        explanation = (try? container.decodeIfPresent(String.self, forKey: .explanation)) ?? ""
        original = (try? container.decodeIfPresent(String.self, forKey: .original)) ?? ""
        replacement = (try? container.decodeIfPresent(String.self, forKey: .replacement)) ?? ""
    }

    /// 模型有时把行号写成字符串 "8"。
    private static func int(_ container: KeyedDecodingContainer<CodingKeys>, _ key: CodingKeys) -> Int? {
        if let value = try? container.decodeIfPresent(Int.self, forKey: key) { return value }
        if let text = try? container.decodeIfPresent(String.self, forKey: key) { return Int(text.trimmingCharacters(in: .whitespaces)) }
        return nil
    }
}

struct CodeReviewResponse: Decodable, Sendable {
    var issues: [CodeReviewRawIssue] = []

    private enum CodingKeys: String, CodingKey { case issues }

    init(issues: [CodeReviewRawIssue]) { self.issues = issues }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        issues = (try? container.decodeIfPresent([CodeReviewRawIssue].self, forKey: .issues)) ?? []
    }
}

/// 力扣判题环境里默认可用的东西。代码是提交到力扣跑的，不是本地工程：
/// Java 已经 `import java.util.*` 等常用包，写 `java.util.HashMap` 或补 import 都是噪音。
enum LeetCodeJudgeEnvironment {
    /// 写进提示词的一句话，按语言给。
    static func promptNote(language: String) -> String {
        switch LeetCodeEditorLanguage.normalized(language) {
        case "java":
            "代码提交到力扣判题环境运行：java.util.*、java.util.function.*、java.util.stream.* 已默认导入。不要写 import，不要用全限定类名（写 Map、HashMap、Deque，不写 java.util.Map）。"
        case "cpp", "c":
            "代码提交到力扣判题环境运行：已包含 <bits/stdc++.h> 且 using namespace std。不要写 #include，不要加 std:: 前缀。"
        case "python3":
            "代码提交到力扣判题环境运行：typing、collections、heapq、bisect、math、functools、itertools 已可直接使用。不要写 import。"
        default:
            "代码提交到力扣判题环境运行，常用标准库已默认导入，不要写 import。"
        }
    }

    /// 模型还是写了的话，客户端兜底清掉：只动确定安全的部分。
    /// Java 去掉 `java.util.` / `java.util.function.` / `java.util.stream.` 限定名（后面紧跟大写类名），
    /// 删掉这几个包的 import 行；`java.util.concurrent` 这类子包不在默认导入里，保持原样。
    static func simplify(_ code: String, language: String) -> String {
        guard LeetCodeEditorLanguage.normalized(language) == "java", !code.isEmpty else { return code }
        let lines = code.components(separatedBy: "\n").filter { line in
            line.range(of: #"^\s*import\s+java\.util\.(?:\*|[A-Z]\w*|function\.(?:\*|[A-Z]\w*)|stream\.(?:\*|[A-Z]\w*))\s*;\s*$"#, options: .regularExpression) == nil
        }
        return lines.joined(separator: "\n")
            .replacingOccurrences(of: #"\bjava\.util\.(?:function\.|stream\.)?(?=[A-Z])"#, with: "", options: .regularExpression)
    }
}

/// 建议的校验、落位与应用。全是纯函数。
enum CodeReviewPolicy {
    static let maximumSuggestions = 5
    /// 原文对不上时，在原行号上下这么多行里找。
    static let relocationRadius = 8

    /// 把模型给的原始建议变成能放进编辑器的建议：
    /// 原文找不到位置的丢掉（多半是模型抄错了代码）；替换后和原文一样的丢掉；
    /// 区间与前面已收下的重叠的丢掉——两条建议改同一行，接受一条另一条就错位了。
    static func resolve(_ issues: [CodeReviewRawIssue], code: String, language: String = "", idPrefix: String = UUID().uuidString) -> [CodeReviewSuggestion] {
        let lines = splitLines(code)
        var accepted: [CodeReviewSuggestion] = []
        for (index, issue) in issues.enumerated() {
            guard accepted.count < maximumSuggestions else { break }
            let start = issue.startLine, end = max(issue.startLine, issue.endLine)
            let original = issue.original.isEmpty && start >= 1 && end <= lines.count
                ? lines[(start - 1)...(end - 1)].joined(separator: "\n")
                : issue.original
            guard let range = locate(original: original, near: start, span: end - start + 1, in: lines) else { continue }
            let exactOriginal = lines[(range.lowerBound - 1)...(range.upperBound - 1)].joined(separator: "\n")
            let replacement = reindent(LeetCodeJudgeEnvironment.simplify(issue.replacement, language: language), like: exactOriginal)
            guard normalized(replacement) != normalized(exactOriginal) else { continue }
            guard !accepted.contains(where: { $0.startLine <= range.upperBound && range.lowerBound <= $0.endLine }) else { continue }
            accepted.append(CodeReviewSuggestion(
                id: "\(idPrefix)-\(index)",
                startLine: range.lowerBound,
                endLine: range.upperBound,
                severity: CodeReviewSuggestion.Severity(rawValue: issue.severity.lowercased()) ?? .warning,
                title: String(issue.title.trimmingCharacters(in: .whitespacesAndNewlines).prefix(40)),
                explanation: String(issue.explanation.trimmingCharacters(in: .whitespacesAndNewlines).prefix(160)),
                original: exactOriginal,
                replacement: replacement
            ))
        }
        return accepted.sorted { $0.startLine < $1.startLine }
    }

    /// 代码改过之后重新找位置。原文已经不在了就返回 nil（建议作废）。
    static func relocate(_ suggestion: CodeReviewSuggestion, in code: String) -> CodeReviewSuggestion? {
        let lines = splitLines(code)
        let span = suggestion.endLine - suggestion.startLine + 1
        guard let range = locate(original: suggestion.original, near: suggestion.startLine, span: span, in: lines) else { return nil }
        var moved = suggestion
        moved.startLine = range.lowerBound
        moved.endLine = range.upperBound
        return moved
    }

    /// 接受一条建议后的代码。位置对不上返回 nil。
    static func apply(_ suggestion: CodeReviewSuggestion, to code: String) -> String? {
        guard let located = relocate(suggestion, in: code) else { return nil }
        var lines = splitLines(code)
        let replacement = suggestion.replacement.isEmpty ? [] : splitLines(suggestion.replacement)
        lines.replaceSubrange((located.startLine - 1)...(located.endLine - 1), with: replacement)
        return lines.joined(separator: "\n")
    }

    /// AI 的回答里有没有点到具体行（"第 8 行""第 3–5 行""line 12""L7"）。
    /// 点到了才值得再花一次请求把它变成编辑器里的标注。
    static func mentionsSpecificLines(_ text: String) -> Bool {
        text.range(of: #"第\s*\d+\s*(?:[-–~至到]\s*\d+\s*)?行|\bline\s*\d+|\bL\d+\b"#, options: [.regularExpression, .caseInsensitive]) != nil
    }

    // MARK: - 内部

    private static func locate(original: String, near line: Int, span: Int, in lines: [String]) -> ClosedRange<Int>? {
        let target = splitLines(original)
        let needle = target.map(normalized)
        guard !lines.isEmpty, !needle.allSatisfy(\.isEmpty) else { return nil }
        let count = max(1, target.count)
        guard count <= lines.count else { return nil }

        func matches(at start: Int) -> Bool {
            guard start >= 1, start + count - 1 <= lines.count else { return false }
            for offset in 0..<count where normalized(lines[start - 1 + offset]) != needle[offset] {
                return false
            }
            return true
        }

        // 先看原位置，再由近及远往两边找——同样的一行（比如 `}`）可能出现很多次，就近最可能是它。
        let anchor = min(max(line, 1), lines.count)
        if matches(at: anchor) { return anchor...(anchor + count - 1) }
        for distance in 1...relocationRadius {
            if matches(at: anchor - distance) { return (anchor - distance)...(anchor - distance + count - 1) }
            if matches(at: anchor + distance) { return (anchor + distance)...(anchor + distance + count - 1) }
        }
        _ = span
        return nil
    }

    /// 比较时忽略所有空白：模型抄代码时常把 `for(int i=0;` 写成 `for (int i = 0;`。
    static func normalized(_ value: String) -> String {
        value.filter { !$0.isWhitespace }
    }

    static func splitLines(_ value: String) -> [String] {
        value.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
    }

    /// 模型给的替换代码经常丢了缩进。原文首行有缩进、替换代码首行却顶格时，
    /// 整段按原文首行的缩进平移（段内的相对缩进保留）。
    static func reindent(_ replacement: String, like original: String) -> String {
        guard !replacement.isEmpty else { return replacement }
        let indent = String(splitLines(original).first?.prefix { $0 == " " || $0 == "\t" } ?? "")
        let lines = splitLines(replacement)
        guard !indent.isEmpty, let first = lines.first, !(first.first == " " || first.first == "\t") else { return replacement }
        return lines.map { $0.isEmpty ? $0 : indent + $0 }.joined(separator: "\n")
    }
}
