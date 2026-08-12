import SwiftUI

/// 模型写出来的短文本按行内 Markdown 渲染。
///
/// 提示、要点、追问这类内容是模型自由发挥的，它随时可能写 `**加粗**` 或者 `` `nums[i]` ``。
/// 原样摆上去就是一串星号和反引号，读起来像没渲染完的网页。
///
/// 只做行内：块级结构（列表、围栏代码）在这些小卡片里没有排版空间，
/// 而且提示本来就禁止给出完整代码。解析失败一律退回纯文本——
/// 格式问题绝不能把内容本身吞掉。
enum InlineMarkdown {
    static func attributed(
        _ source: String,
        codeFont: Font = .system(.callout, design: .monospaced)
    ) -> AttributedString {
        let trimmed = source.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return AttributedString("") }
        guard var value = try? AttributedString(
            markdown: trimmed,
            options: AttributedString.MarkdownParsingOptions(
                allowsExtendedAttributes: true,
                // 保留换行：提示经常是"一句结论 + 一句追问"两行，合成一行就读不出层次。
                interpretedSyntax: .inlineOnlyPreservingWhitespace,
                failurePolicy: .returnPartiallyParsedIfPossible
            )
        ) else {
            return AttributedString(trimmed)
        }
        for run in value.runs where run.inlinePresentationIntent?.contains(.code) == true {
            value[run.range].font = codeFont
        }
        return value
    }
}
