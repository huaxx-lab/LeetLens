import Foundation

/// 把力扣编译器 / 运行时已经给出的行号直接投影到编辑器。
/// 这是确定性本地解析，不需要请求 AI；AI 审查只处理没有明确行号的逻辑问题。
enum LeetCodeJudgeDiagnosticParser {
    static let maximumIssues = 12

    static func parse(_ result: LeetCodeJudgeResult, codeLineCount: Int) -> [LeetCodeEditorIssue] {
        guard codeLineCount > 0 else { return [] }
        var issues: [LeetCodeEditorIssue] = []
        append(from: result.compileError, fallback: "编译错误", codeLineCount: codeLineCount, to: &issues)
        append(from: result.runtimeError, fallback: "运行错误", codeLineCount: codeLineCount, to: &issues)

        var seen = Set<String>()
        return issues.filter { issue in
            seen.insert("\(issue.line)|\(issue.message)").inserted
        }
        .prefix(maximumIssues)
        .map { $0 }
    }

    private static func append(
        from raw: String,
        fallback: String,
        codeLineCount: Int,
        to issues: inout [LeetCodeEditorIssue]
    ) {
        let source = sanitized(raw)
        guard !source.isEmpty else { return }
        let lines = source.components(separatedBy: .newlines)
        let globalMessage = firstMeaningfulMessage(in: lines) ?? fallback

        // `Line 21: error: ...`、`Line 7: Char 12: error: ...`、`line 5, column 3: ...`
        collect(
            pattern: #"(?i)\bline\s+(\d+)(?:\s*[:,]\s*(?:char(?:acter)?|column)\s*\d+)?\s*:\s*(.*)$"#,
            lines: lines,
            fallback: globalMessage,
            codeLineCount: codeLineCount,
            to: &issues
        )

        // clang / gcc / JavaScript：`solution.cpp:7:5: error: ...`、`Solution.java:21: ...`
        collect(
            pattern: #"(?i)(?:^|[/\\])?(?:solution|main)\.(?:java|cpp|cc|c|py|py3|js|ts|swift|kt|go|rs):(\d+)(?::\d+)?[:)]?\s*(.*)$"#,
            lines: lines,
            fallback: globalMessage,
            codeLineCount: codeLineCount,
            to: &issues
        )

        // Python traceback：`File \"Solution.py\", line 5, in maxDepth`。
        collect(
            pattern: #"(?i)file\s+[\"'][^\"']*(?:solution|main)\.(?:py|py3)[\"']\s*,\s*line\s+(\d+)(?:\s*,\s*in\s+[^\n]+)?\s*$"#,
            lines: lines,
            fallback: globalMessage,
            codeLineCount: codeLineCount,
            messageFromFollowingLine: true,
            to: &issues
        )

        // Java stack frame：`at Solution.maxDepth(Solution.java:21)`。
        collect(
            pattern: #"(?i)\bat\s+(?:[\w$]+\.)*(?:solution|main)[\w$]*\.[^(]+\((?:solution|main)\.java:(\d+)\)"#,
            lines: lines,
            fallback: globalMessage,
            codeLineCount: codeLineCount,
            to: &issues
        )
    }

    private static func collect(
        pattern: String,
        lines: [String],
        fallback: String,
        codeLineCount: Int,
        messageFromFollowingLine: Bool = false,
        to issues: inout [LeetCodeEditorIssue]
    ) {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return }
        for (index, line) in lines.enumerated() {
            let range = NSRange(line.startIndex..<line.endIndex, in: line)
            guard let match = regex.firstMatch(in: line, range: range),
                  let lineRange = Range(match.range(at: 1), in: line),
                  let number = Int(line[lineRange]),
                  (1...codeLineCount).contains(number)
            else { continue }

            var message = ""
            if match.numberOfRanges > 2,
               let messageRange = Range(match.range(at: 2), in: line) {
                message = cleanMessage(String(line[messageRange]))
            }
            if messageFromFollowingLine || message.isEmpty {
                message = followingMessage(after: index, in: lines) ?? message
            }
            if message.isEmpty { message = fallback }
            issues.append(LeetCodeEditorIssue(line: number, message: String(message.prefix(240))))
        }
    }

    private static func sanitized(_ value: String) -> String {
        value
            .replacingOccurrences(of: #"\x1B\[[0-?]*[ -/]*[@-~]"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: "\r\n", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func cleanMessage(_ value: String) -> String {
        value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(
                of: #"^(?:(?:fatal\s+)?error|warning|exception)\s*:\s*"#,
                with: "",
                options: [.regularExpression, .caseInsensitive]
            )
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func followingMessage(after index: Int, in lines: [String]) -> String? {
        let candidates = lines.dropFirst(index + 1).prefix(6).compactMap { line -> String? in
            let value = cleanMessage(line)
            guard !value.isEmpty,
                  !value.allSatisfy({ "^~| ".contains($0) }),
                  !value.hasPrefix("at ")
            else { return nil }
            return value
        }
        // Python traceback 的下一行通常是源码，真正错误在再下一行的 `XxxError:`。
        return candidates.first(where: {
            $0.range(of: #"^[A-Za-z_$][\w.$]*(?:Error|Exception):"#, options: .regularExpression) != nil
        }) ?? candidates.first
    }

    private static func firstMeaningfulMessage(in lines: [String]) -> String? {
        for line in lines {
            let value = cleanMessage(line)
            guard !value.isEmpty,
                  value.range(of: #"(?i)^line\s+\d+"#, options: .regularExpression) == nil,
                  !value.hasPrefix("at "),
                  !value.allSatisfy({ "^~| ".contains($0) })
            else { continue }
            return value
        }
        return nil
    }
}
