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
    /// 双轴 ScrollView 的视口宽度：内容窄于视口时 SwiftUI 会把它居中，
    /// 只能把内容自己撑到视口宽（`minWidth` + leading）来抵消。
    @State private var viewportWidth: CGFloat = 0

    var body: some View {
        VStack(spacing: 0) {
            if showsHeader {
                HStack(spacing: 8) {
                    Text(displayLanguage)
                        .font(.system(size: 12, weight: .regular))
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
                            .font(.system(size: 13, weight: .regular))
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
                highlightedText
                    .font(.system(size: ConversationCodeBlockStyle.fontSize, design: .monospaced))
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

    private var highlightedText: Text {
        SyntaxCodeHighlighter.tokens(in: code).reduce(Text("")) { partial, token in
            partial + Text(verbatim: token.value).foregroundColor(token.color)
        }
    }
}

private enum SyntaxCodeHighlighter {
    struct Token {
        let value: String
        let style: Style

        var color: Color {
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
