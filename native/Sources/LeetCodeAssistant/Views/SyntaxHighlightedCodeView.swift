import AppKit
import SwiftUI

/// 聊天代码块的 SwiftUI 同构实现。可编辑的刷题区仍使用 CodeMirror；其余只读代码
/// 都走这个组件，并严格跟随 `ConversationCodeBlockStyle` 的头部、底色、圆角、字号与复制反馈。
/// 高亮器是本地轻量实现，但容器交互和视觉不再另起一套。
struct SyntaxHighlightedCodeView: View {
    let code: String
    let language: String
    var showsHeader = true
    var maxHeight: CGFloat? = nil

    @State private var copied = false
    @State private var renderCache = RenderCacheBox()
    /// 双轴 ScrollView 的视口宽度：内容窄于视口时 SwiftUI 会把它居中，
    /// 只能把内容自己撑到视口宽（`minWidth` + leading）来抵消。
    @State private var viewportWidth: CGFloat = 0

    var body: some View {
        VStack(spacing: 0) {
            if showsHeader {
                HStack(spacing: 8) {
                    Text(displayLanguage)
                        .font(.appScaled(size: 12, weight: .regular))
                        .foregroundStyle(ConversationCodeBlockStyle.secondaryForeground)
                    Spacer()
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(code, forType: .string)
                        copied = true
                        Task { @MainActor in
                            try? await Task.sleep(for: .seconds(1.2))
                            copied = false
                        }
                    } label: {
                        Image(systemName: copied ? "checkmark" : "doc.on.doc")
                            .font(.appScaled(size: 13, weight: .regular))
                            .frame(
                                width: ConversationCodeBlockStyle.copyControlSize,
                                height: ConversationCodeBlockStyle.copyControlSize
                            )
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(copied ? AppDesign.ColorToken.success : ConversationCodeBlockStyle.secondaryForeground)
                    .background(Color.primary.opacity(0.001), in: RoundedRectangle(cornerRadius: 7))
                    .help(copied ? "已复制" : "复制代码")
                }
                .padding(.leading, 12)
                .padding(.trailing, 8)
                .frame(height: ConversationCodeBlockStyle.headerHeight)
            }

            // 不限高时只开横向：嵌在长页面里的代码块若也接管竖向滚动，
            // 鼠标停在代码上滚动就推不动外层页面了。
            ScrollView(maxHeight == nil ? .horizontal : [.horizontal, .vertical]) {
                Text(highlighted.text)
                    .font(.appScaled(size: ConversationCodeBlockStyle.fontSize, design: .monospaced))
                    .lineSpacing(ConversationCodeBlockStyle.lineSpacing)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: true, vertical: true)
                    .padding(.horizontal, ConversationCodeBlockStyle.horizontalPadding)
                    .padding(.top, ConversationCodeBlockStyle.topPadding)
                    .padding(.bottom, ConversationCodeBlockStyle.bottomPadding)
                    // 双轴 ScrollView（限高时）会把窄内容居中；单轴不会。
                    // 撑到视口宽再左对齐，两种模式的观感才一致。
                    .frame(minWidth: viewportWidth, alignment: .leading)
            }
            .floatingScrollIndicators(maxHeight == nil ? .horizontal : [.horizontal, .vertical])
            // 撑满宽度要在 ScrollView 外面做：放进横向 ScrollView 里的
            // `maxWidth: .infinity` 会被当成"内容有无限宽"，代码整段被推到中间去。
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(maxHeight: maxHeight)
            .background {
                GeometryReader { proxy in
                    Color.clear
                        .task(id: proxy.size.width) { viewportWidth = proxy.size.width }
                }
            }
        }
        .background(ConversationCodeBlockStyle.background)
        .clipShape(RoundedRectangle(
            cornerRadius: ConversationCodeBlockStyle.cornerRadius,
            style: .continuous
        ))
    }

    private var displayLanguage: String {
        let value = language.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? "text" : value.lowercased()
    }

    /// 只在 `code` 变化时重算：body 每次求值都跑一遍正则，
    /// 几万字的失败用例在滚动、悬停时会反复卡顿。
    private var highlighted: SyntaxCodeHighlighter.Rendered {
        if let cached = renderCache.value, cached.source == code { return cached }
        // 纯文本（编译信息、失败用例、输出）不着色：给几万个数字上色没有阅读价值。
        let rendered = SyntaxCodeHighlighter.render(code, highlights: displayLanguage != "text")
        renderCache.value = rendered
        return rendered
    }
}

/// 不参与 SwiftUI 观察的缓存盒子：写它不会触发重绘，也就不会在 body 里递归更新。
private final class RenderCacheBox {
    var value: SyntaxCodeHighlighter.Rendered?
}

enum SyntaxCodeHighlighter {
    /// 超过这个长度不再逐 token 着色，也不整段排版。
    ///
    /// 力扣的失败用例动辄 10⁵ 个数字、几十万字符：着色没有阅读价值，
    /// 而 SwiftUI 的 Text 排版几十万字符本身就要卡上好几秒。
    /// 复制按钮拿的仍是完整原文，这里只影响显示。
    static let highlightCharacterLimit = 20_000
    static let displayCharacterLimit = 60_000

    struct Rendered {
        let source: String
        let text: AttributedString
        let runCount: Int
        let isTruncated: Bool
    }

    /// 生成**一个**扁平的 `AttributedString`。
    ///
    /// 以前是 `tokens.reduce(Text("")) { $0 + Text(token) }`：每个 `+` 包一层
    /// `ConcatenatedTextStorage`，树深等于 token 数，SwiftUI 解析时逐层递归。
    /// 实测约 6 000 个 token（3 000 个数字的数组）就把主线程栈打穿——
    /// 提交答案出错时，失败用例 / 实际输出正好走这里，表现为提交后直接闪退。
    static func render(_ source: String, highlights: Bool = true) -> Rendered {
        let utf16Count = source.utf16.count
        let isTruncated = utf16Count > displayCharacterLimit
        let visible = isTruncated ? truncatedPrefix(of: source) : source

        var text = AttributedString()
        var runCount = 0
        if !highlights || utf16Count > highlightCharacterLimit {
            text = AttributedString(visible)
            runCount = visible.isEmpty ? 0 : 1
        } else {
            // 相邻同色 token 合并成一段：逗号、空格和数字交替时能少一半 run。
            var pending = ""
            var pendingStyle: Style?
            func flush() {
                guard let style = pendingStyle, !pending.isEmpty else { return }
                var run = AttributedString(pending)
                run.foregroundColor = Token.color(for: style)
                text.append(run)
                runCount += 1
                pending = ""
            }
            for token in tokens(in: visible) {
                if token.style != pendingStyle {
                    flush()
                    pendingStyle = token.style
                }
                pending += token.value
            }
            flush()
        }

        if isTruncated {
            var note = AttributedString("\n\n…… 内容过长，只显示前 \(displayCharacterLimit / 1000)K 字符（共 \(utf16Count) 字符），复制按钮会复制完整内容")
            note.foregroundColor = Token.color(for: .comment)
            text.append(note)
            runCount += 1
        }
        return Rendered(source: source, text: text, runCount: runCount, isTruncated: isTruncated)
    }

    /// 按 UTF-16 截断，但不切断代理对。
    private static func truncatedPrefix(of source: String) -> String {
        let utf16 = source.utf16
        var end = utf16.index(utf16.startIndex, offsetBy: displayCharacterLimit)
        while end > utf16.startIndex, String.Index(end, within: source) == nil {
            end = utf16.index(before: end)
        }
        return String(source[..<(String.Index(end, within: source) ?? source.endIndex)])
    }

    struct Token {
        let value: String
        let style: Style

        var color: Color { Self.color(for: style) }

        static func color(for style: Style) -> Color {
            switch style {
            case .plain: .primary
            case .comment: Color(nsColor: .secondaryLabelColor)
            case .string: Color(nsColor: .systemGreen)
            case .number: Color(nsColor: .systemBlue)
            case .keyword: Color(nsColor: .systemPink)
            case .type: Color(nsColor: .systemTeal)
            }
        }
    }

    enum Style { case plain, comment, string, number, keyword, type }

    private static let expression: NSRegularExpression = {
        let keywords = [
            "abstract", "as", "async", "await", "break", "case", "catch", "class", "const", "continue",
            "def", "default", "delete", "do", "else", "enum", "export", "extends", "false", "final", "finally",
            "for", "from", "func", "function", "if", "implements", "import", "in", "instanceof", "interface",
            "lambda", "let", "new", "nil", "null", "override", "package", "pass", "private", "protected",
            "protocol", "public", "raise", "return", "static", "struct", "super", "switch", "this", "throw",
            "throws", "true", "try", "typealias", "typeof", "var", "virtual", "void", "while", "with", "yield"
        ].joined(separator: "|")
        let types = [
            "Array", "Boolean", "Character", "Double", "Float", "HashMap", "HashSet", "Integer", "List", "Long",
            "Map", "Object", "Optional", "Queue", "Set", "Stack", "String", "StringBuilder", "TreeMap", "TreeSet",
            "bool", "char", "double", "float", "int", "long", "short", "size_t", "uint", "vector"
        ].joined(separator: "|")
        let pattern = #"(?s)(//[^\n]*|/\*.*?\*/|#[^\n]*)|(\"(?:\\.|[^\"\\])*\"|'(?:\\.|[^'\\])*')|\b(0[xX][0-9a-fA-F]+|\d+(?:\.\d+)?)\b|\b("#
            + keywords + #")\b|\b("# + types + #")\b"#
        return try! NSRegularExpression(pattern: pattern)
    }()

    static func tokens(in source: String) -> [Token] {
        guard !source.isEmpty else { return [] }
        let text = source as NSString
        let fullRange = NSRange(location: 0, length: text.length)
        let matches = expression.matches(in: source, range: fullRange)
        guard !matches.isEmpty else { return [Token(value: source, style: .plain)] }

        var result: [Token] = []
        var cursor = 0
        for match in matches {
            if match.range.location > cursor {
                result.append(Token(
                    value: text.substring(with: NSRange(location: cursor, length: match.range.location - cursor)),
                    style: .plain
                ))
            }
            let style: Style
            if match.range(at: 1).location != NSNotFound { style = .comment }
            else if match.range(at: 2).location != NSNotFound { style = .string }
            else if match.range(at: 3).location != NSNotFound { style = .number }
            else if match.range(at: 4).location != NSNotFound { style = .keyword }
            else { style = .type }
            result.append(Token(value: text.substring(with: match.range), style: style))
            cursor = NSMaxRange(match.range)
        }
        if cursor < text.length {
            result.append(Token(
                value: text.substring(with: NSRange(location: cursor, length: text.length - cursor)),
                style: .plain
            ))
        }
        return result
    }
}
