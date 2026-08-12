import Foundation

enum ConversationGenerationPhase: String {
    case generating
    case cancelled
    case failed
}

struct ConversationGenerationSnapshot: Equatable {
    let conversationID: String
    let messageID: String
    var content: String
    var phase: ConversationGenerationPhase
    var detail: String?
    var reasoning = ""
    var toolCalls: [String] = []
    var startedAt = Date.now
    var providerID = ""
    var model = ""

    var elapsedSeconds: Int {
        max(1, Int(Date.now.timeIntervalSince(startedAt).rounded()))
    }

    var storedContent: String {
        guard !reasoning.isEmpty else { return content }
        return "<think duration=\"\(elapsedSeconds)\">\n\(reasoning)\n</think>\n\n" + content
    }
}

struct ConversationRuntimeIdentity: Equatable, Sendable {
    let providerID: String
    let providerName: String
    let model: String

    var systemPrompt: String {
        let resolvedName = providerName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? providerID
            : providerName
        let resolvedModel = model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "供应商默认模型（未提供模型标识）"
            : model
        return """
        【本轮运行时模型信息】
        本轮实际供应商：\(resolvedName)（\(providerID)）
        本轮实际模型标识：\(resolvedModel)
        这是应用在发送请求时冻结的可信运行时信息。历史回答、历史思考、跨会话检索片段中的模型自述均可能来自其他模型，不得沿用。若用户询问当前模型或供应商，只能依据本段回答；不要根据旧对话猜测身份。
        """
    }
}

struct QueuedConversationDraft: Identifiable, Equatable {
    let id = UUID()
    let text: String
    let artifacts: [ConversationArtifact]
}

enum ConversationQueueContent {
    private static let legacyPrefix = "【衔接任务】请结合上一条回答，继续处理下面的用户新增要求。"
    private static let legacyUserMarker = "【用户新增要求】"

    static func userContent(for drafts: [QueuedConversationDraft]) -> String {
        drafts.map(\.text)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")
    }

    static func continuityPrompt() -> String {
        "【内部连续性说明】最近的用户消息是在上一条回答生成期间排队发送的补充。请结合上一轮已生成的内容继续处理，不要复述本内部说明。"
    }

    static func visibleContent(fromStored content: String) -> String {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix(legacyPrefix),
              let markerRange = trimmed.range(of: legacyUserMarker)
        else { return content }
        let userContent = String(trimmed[markerRange.upperBound...])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return userContent.replacingOccurrences(
            of: #"(?m)^【补充\s+\d+】\s*\n?"#,
            with: "",
            options: .regularExpression
        )
    }
}

struct ConversationRevision: Hashable {
    let updatedAtMilliseconds: Int64
    let messageCount: Int
}

struct QuestionRailItem: Identifiable, Equatable {
    let id: String
    let question: String
    let answer: String
}

enum QuestionRailDeriver {
    static func derive(messages: [ConversationTranscriptMessage]) -> [QuestionRailItem] {
        messages.enumerated().compactMap { index, message in
            guard message.role == "user", let question = message.content.questionNavigationPreview else { return nil }
            let answer = messages.dropFirst(index + 1).first { $0.role == "assistant" }
            return QuestionRailItem(
                id: message.id,
                question: question,
                answer: answer?.content.answerNavigationPreview ?? "等待回答"
            )
        }
    }
}

struct ConversationStreamDelta: Equatable {
    var content = ""
    var reasoning = ""
    var toolCalls: [String] = []

    var isEmpty: Bool { content.isEmpty && reasoning.isEmpty && toolCalls.isEmpty }

    mutating func append(_ chunk: ChatStreamChunk) {
        switch chunk {
        case .text(let value):
            content += value
        case .reasoning(let value):
            reasoning += value
        case .toolCall(let name):
            if !toolCalls.contains(name) { toolCalls.append(name) }
        }
    }
}

@MainActor
final class ConversationStreamBatcher {
    private var pending = ConversationStreamDelta()
    private var flushTask: Task<Void, Never>?
    private let interval: Duration
    private let apply: @MainActor (ConversationStreamDelta) -> Void

    init(interval: Duration = .milliseconds(50), apply: @escaping @MainActor (ConversationStreamDelta) -> Void) {
        self.interval = interval
        self.apply = apply
    }

    func append(_ chunk: ChatStreamChunk) {
        pending.append(chunk)
        guard flushTask == nil else { return }
        flushTask = Task { [weak self] in
            try? await Task.sleep(for: self?.interval ?? .milliseconds(50))
            guard !Task.isCancelled else { return }
            self?.flush()
        }
    }

    func flush() {
        flushTask?.cancel()
        flushTask = nil
        guard !pending.isEmpty else { return }
        let delta = pending
        pending = ConversationStreamDelta()
        apply(delta)
    }

    func cancel() {
        flushTask?.cancel()
        flushTask = nil
        pending = ConversationStreamDelta()
    }
}

struct ConversationContextSnapshot: Equatable {
    var outputs: [ContextItem]
    var sources: [ContextItem]

    var isEmpty: Bool { outputs.isEmpty && sources.isEmpty }

    func merging(_ other: ConversationContextSnapshot) -> ConversationContextSnapshot {
        func unique(_ values: [ContextItem]) -> [ContextItem] {
            var seen = Set<String>()
            return values.filter { item in
                seen.insert(item.url.map { "url:\($0)" } ?? item.id).inserted
            }
        }
        return ConversationContextSnapshot(
            outputs: unique(outputs + other.outputs),
            sources: unique(sources + other.sources)
        )
    }
}

enum ContextSourceCategory: String, CaseIterable, Identifiable {
    case web = "网页"
    case image = "图片"
    case video = "视频"
    case file = "文件"

    var id: String { rawValue }

    var systemImage: String {
        switch self {
        case .web: "globe"
        case .image: "photo.on.rectangle.angled"
        case .video: "play.rectangle"
        case .file: "doc"
        }
    }
}

struct ContextSourceGroup: Identifiable, Equatable {
    let category: ContextSourceCategory
    let items: [ContextItem]
    var id: ContextSourceCategory { category }
}

enum ContextSourceGrouping {
    static func groups(for items: [ContextItem]) -> [ContextSourceGroup] {
        ContextSourceCategory.allCases.compactMap { category in
            let matches = items.filter { $0.sourceCategory == category }
            return matches.isEmpty ? nil : ContextSourceGroup(category: category, items: matches)
        }
    }
}

extension ContextItem {
    var sourceCategory: ContextSourceCategory {
        if tool == .video || systemImage == "play.rectangle" { return .video }
        let lower = (url ?? "").lowercased()
        let imageHosts = ["images.unsplash.com", "unsplash.com", "pexels.com", "pixabay.com", "pxhere.com", "loremflickr.com", "placekitten.com"]
        let imageExtensions = [".png", ".jpg", ".jpeg", ".gif", ".webp", ".avif", ".svg"]
        if systemImage == "photo"
            || imageHosts.contains(where: lower.contains)
            || imageExtensions.contains(where: { lower.split(separator: "?").first?.hasSuffix($0) == true }) {
            return .image
        }
        if tool == .preview || tool == .run || tool == .evidence || lower.hasPrefix("file:") { return .file }
        return .web
    }
}

enum ConversationContextDeriver {
    static func derive(messages: [ConversationTranscriptMessage]) -> ConversationContextSnapshot {
        guard !messages.isEmpty else { return ConversationContextSnapshot(outputs: [], sources: []) }
        var outputs: [ContextItem] = []
        var sources: [ContextItem] = []
        var seen = Set<String>()

        for message in messages where message.role == "user" {
            let fields = markedFields(in: message.content)
            if let selection = fields["浏览器当前选区"], !selection.isEmpty {
                let metadata = fields
                    .filter { $0.key != "浏览器当前选区" }
                    .map(\.value)
                    .joined(separator: "\n")
                if let sourceURL = externalLinks(in: metadata).first?.url {
                    append(
                        ContextItem(
                            id: "selection:\(message.id)",
                            title: "浏览器当前选区",
                            subtitle: preview(selection),
                            systemImage: "selection.pin.in.out",
                            tool: .browser,
                            url: sourceURL
                        ),
                        to: &sources,
                        seen: &seen
                    )
                }
            }

            for artifact in message.artifacts where !artifact.url.isEmpty {
                append(
                    ContextItem(
                        id: "artifact:\(artifact.url)",
                        title: artifact.title.isEmpty ? "会话附件" : artifact.title,
                        subtitle: artifact.type == "image" ? "对话中的图片" : "对话附件",
                        systemImage: artifact.type == "image" ? "photo" : "paperclip",
                        tool: .preview,
                        url: artifact.url
                    ),
                    to: &sources,
                    seen: &seen
                )
            }
        }

        for message in messages where message.role == "assistant" {
            for artifact in message.artifacts where !artifact.url.isEmpty {
                let isRemoteSource = artifact.url.hasPrefix("https://") || artifact.url.hasPrefix("http://")
                let item = ContextItem(
                    id: "artifact:\(artifact.url)",
                    title: artifact.title.isEmpty ? (isRemoteSource ? "外部资源" : "生成文件") : artifact.title,
                    subtitle: isRemoteSource ? sourceSubtitle(for: artifact.url) : "本次任务输出",
                    systemImage: artifact.type == "image" ? "photo" : "doc",
                    tool: isRemoteSource ? .browser : .preview,
                    url: artifact.url
                )
                if isRemoteSource {
                    append(item, to: &sources, seen: &seen)
                } else {
                    append(item, to: &outputs, seen: &seen)
                }
            }

            for link in externalLinks(in: message.content) {
                let isVideo = isVideoURL(link.url)
                append(
                    ContextItem(
                        id: "link:\(link.url)",
                        title: link.title,
                        subtitle: sourceSubtitle(for: link.url),
                        systemImage: isVideo ? "play.rectangle" : "globe",
                        tool: isVideo ? .video : .browser,
                        url: link.url
                    ),
                    to: &sources,
                    seen: &seen
                )
            }
        }

        return ConversationContextSnapshot(outputs: outputs, sources: sources)
    }

    private static func markedFields(in content: String) -> [String: String] {
        let pattern = #"【([^】]+)】([\s\S]*?)(?=\n\s*【[^】]+】|$)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [:] }
        let range = NSRange(content.startIndex..<content.endIndex, in: content)
        return regex.matches(in: content, range: range).reduce(into: [:]) { result, match in
            guard
                let keyRange = Range(match.range(at: 1), in: content),
                let valueRange = Range(match.range(at: 2), in: content)
            else { return }
            result[String(content[keyRange])] = String(content[valueRange])
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    private static func append(_ item: ContextItem, to items: inout [ContextItem], seen: inout Set<String>) {
        let identity = item.url.map { "url:\($0)" } ?? item.id
        guard seen.insert(identity).inserted else { return }
        items.append(item)
    }

    private static func preview(_ text: String, limit: Int = 56) -> String {
        let compact = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return compact.count > limit ? String(compact.prefix(limit)) + "..." : compact
    }

    private static func externalLinks(in content: String) -> [(title: String, url: String)] {
        let markdownPattern = #"\[([^\]\n]{1,160})\]\((https?://[^)\s]{1,2048})\)"#
        let barePattern = #"https?://[^\s<>()\[\]]{1,2048}"#
        guard let markdownRegex = try? NSRegularExpression(pattern: markdownPattern, options: .caseInsensitive),
              let bareRegex = try? NSRegularExpression(pattern: barePattern, options: .caseInsensitive)
        else { return [] }
        let range = NSRange(content.startIndex..<content.endIndex, in: content)
        var links = markdownRegex.matches(in: content, range: range).compactMap { match -> (title: String, url: String)? in
            guard let titleRange = Range(match.range(at: 1), in: content),
                  let urlRange = Range(match.range(at: 2), in: content)
            else { return nil }
            return (String(content[titleRange]), String(content[urlRange]))
        }
        var seen = Set(links.map(\.url))
        for match in bareRegex.matches(in: content, range: range) {
            guard let urlRange = Range(match.range, in: content) else { continue }
            let value = String(content[urlRange]).trimmingCharacters(in: CharacterSet(charactersIn: ".,;:!?，。；：！？"))
            guard seen.insert(value).inserted, let url = URL(string: value) else { continue }
            let title = url.host(percentEncoded: false)?.replacingOccurrences(of: "www.", with: "") ?? "网页来源"
            links.append((title, value))
        }
        return links
    }

    private static func sourceSubtitle(for value: String) -> String {
        guard let url = URL(string: value), let host = url.host(percentEncoded: false) else { return "外部来源" }
        return host.replacingOccurrences(of: "www.", with: "")
    }

    private static func isVideoURL(_ value: String) -> Bool {
        let host = URL(string: value)?.host(percentEncoded: false)?.lowercased() ?? ""
        return host.contains("bilibili.com") || host.contains("youtube.com") || host == "youtu.be"
    }
}

struct ContextUsageSnapshot: Equatable {
    let estimatedInputTokens: Int
    let availableInputTokens: Int
    let compressionTriggerTokens: Int
    let tokensUntilCompression: Int
    let utilization: Double
    let shouldCompress: Bool
    let messageCount: Int
    let imageCount: Int
}

struct ConversationContextBaseline: Equatable {
    let estimatedInputTokens: Int
    let messageCount: Int
    let imageCount: Int
}

enum ConversationContextEstimator {
    static func estimate(
        messages: [ConversationTranscriptMessage],
        draft: String,
        settings: LegacySettingsSnapshot
    ) -> ContextUsageSnapshot {
        estimate(baseline: baseline(messages: messages), draft: draft, settings: settings)
    }

    static func baseline(messages: [ConversationTranscriptMessage]) -> ConversationContextBaseline {
        let estimated = messages.reduce(0) { partial, message in
            let userImages = message.role == "user" ? message.artifacts.filter { $0.type == "image" }.count : 0
            return partial + 4 + estimateTextTokens(message.content) + userImages * 96
        }
        let imageCount = Set(
            messages
                .filter { $0.role == "user" }
                .flatMap(\.artifacts)
                .filter { $0.type == "image" }
                .map(\.url)
        ).count
        return ConversationContextBaseline(
            estimatedInputTokens: estimated,
            messageCount: messages.count,
            imageCount: imageCount
        )
    }

    static func estimate(
        baseline: ConversationContextBaseline,
        draft: String,
        settings: LegacySettingsSnapshot
    ) -> ContextUsageSnapshot {
        let trimmedDraft = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasDraft = !trimmedDraft.isEmpty
        let draftTokens = hasDraft ? 4 + estimateTextTokens(draft) : 0
        let contextWindow = max(512, Int(settings.contextWindowTokens))
        let reserved = min(max(0, Int(settings.reservedOutputTokens)), max(0, contextWindow - 256))
        let available = max(256, contextWindow - reserved)
        let threshold = min(max(settings.compressionThreshold, 0.5), 0.99)
        let trigger = max(1, Int(Double(available) * threshold))
        let estimated = baseline.estimatedInputTokens + draftTokens
        return ContextUsageSnapshot(
            estimatedInputTokens: estimated,
            availableInputTokens: available,
            compressionTriggerTokens: trigger,
            tokensUntilCompression: max(0, trigger - estimated),
            utilization: min(1, Double(estimated) / Double(available)),
            shouldCompress: estimated >= trigger,
            messageCount: baseline.messageCount + (hasDraft ? 1 : 0),
            imageCount: baseline.imageCount
        )
    }

    static func estimateTextTokens(_ text: String) -> Int {
        guard !text.isEmpty else { return 0 }
        var eastAsian = 0.0
        var latinOrDigits = 0.0
        var punctuation = 0.0
        var whitespace = 0.0
        var other = 0.0
        for scalar in text.unicodeScalars {
            let value = scalar.value
            if (0x3400...0x9fff).contains(value)
                || (0xf900...0xfaff).contains(value)
                || (0x20000...0x323af).contains(value)
                || (0x3040...0x30ff).contains(value)
                || (0xac00...0xd7af).contains(value) {
                eastAsian += 1
            } else if (0x30...0x39).contains(value)
                || (0x41...0x5a).contains(value)
                || (0x61...0x7a).contains(value)
                || value == 0x5f {
                latinOrDigits += 1
            } else if value <= 0x20 || value == 0xa0 || value == 0x3000 {
                whitespace += 1
            } else if value < 0x80 {
                punctuation += 1
            } else {
                other += 1
            }
        }
        return max(1, Int(ceil(eastAsian + latinOrDigits / 3.5 + punctuation / 2 + whitespace / 12 + other)))
    }
}

extension String {
    var questionNavigationPreview: String? {
        var source = self
        if let marker = source.range(of: "【浏览器当前选区】") {
            source = String(source[marker.upperBound...])
        }
        source = source.replacingOccurrences(of: #"```[\s\S]*?```"#, with: " ", options: .regularExpression)
        let candidates = source.split(whereSeparator: \.isNewline).map {
            String($0).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let ignoredPrefixes = ["<", "</", "<!--", "//", "/*", "*", "stroke-", "fill=", "viewBox=", "d=", "<path", "<circle", "<animate"]
        guard let line = candidates.first(where: { line in
            guard line.count >= 4, !ignoredPrefixes.contains(where: line.hasPrefix) else { return false }
            let codeSignals = ["stroke-width", "stroke-linecap", "stroke-linejoin", "attributeName=", "repeatCount=", "<svg", "</svg>"]
            guard !codeSignals.contains(where: line.contains) else { return false }
            return line.range(of: #"[\p{Han}？?]"#, options: .regularExpression) != nil
        }) else { return nil }
        return String(line.prefix(54))
    }

    var answerNavigationPreview: String {
        replacingOccurrences(of: #"```[\s\S]*?```"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: "#", with: "")
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first(where: { !$0.isEmpty })
            .map { String($0.prefix(54)) } ?? "已回答"
    }
}

enum ConversationContextManager {
    private static let omission = "【上下文说明】较早消息已按上下文预算压缩；以下保留首个问题、历史摘要和最近对话。"

    static func build(
        messages: [ConversationTranscriptMessage],
        contextSummary: String,
        settings: LegacySettingsSnapshot
    ) -> [ChatRequestMessage] {
        let snapshot = messages
            .filter { ["user", "assistant"].contains($0.role) }
            .map(sanitizedMessage)
        guard !snapshot.isEmpty else { return [] }

        let estimated = snapshot.reduce(0) { $0 + 4 + ConversationContextEstimator.estimateTextTokens($1.content) }
        let available = max(256, Int(settings.contextWindowTokens - settings.reservedOutputTokens))
        let threshold = Int(Double(available) * min(max(settings.compressionThreshold, 0.5), 0.99))
        guard estimated >= threshold else { return snapshot }

        let target = Int(Double(available) * min(max(settings.postCompressionRatio, 0.5), settings.compressionThreshold))
        let firstUser = snapshot.first { $0.role == "user" }
        var prefix: [ChatRequestMessage] = []
        if let firstUser { prefix.append(firstUser) }
        if !contextSummary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            prefix.append(ChatRequestMessage(
                role: "system",
                content: "【历史对话摘要】\n\(contextSummary.trimmingCharacters(in: .whitespacesAndNewlines))"
            ))
        }
        prefix.append(ChatRequestMessage(role: "system", content: omission))

        let fixedTokens = prefix.reduce(0) { $0 + 4 + ConversationContextEstimator.estimateTextTokens($1.content) }
        let tailBudget = max(1, target - fixedTokens)
        let recentLimit = max(6, Int(settings.recentMessages))
        var tail: [ChatRequestMessage] = []
        var tailTokens = 0
        for message in snapshot.reversed() {
            if message.role == firstUser?.role && message.content == firstUser?.content { continue }
            let tokens = 4 + ConversationContextEstimator.estimateTextTokens(message.content)
            if tail.count >= 6, tailTokens + tokens > tailBudget { break }
            tail.append(message)
            tailTokens += tokens
            if tail.count >= recentLimit { break }
        }
        return prefix + Array(tail.reversed())
    }

    private static func sanitizedMessage(_ message: ConversationTranscriptMessage) -> ChatRequestMessage {
        var content = message.content
        if message.role == "assistant" {
            content = replacing(#"<think(?:\s+duration=\"\d+\")?>[\s\S]*?</think>"#, in: content, with: "")
            content = replacing(#"!\[[^\]\n]{0,160}\]\([^\)\n]+\)"#, in: content, with: "")
            content = replacing(#"<img\b[^>]*>"#, in: content, with: "")
            content = replacing(#"```(?:svg|mermaid)\s*[\s\S]*?```"#, in: content, with: "[已生成图解，视觉内容不回灌上下文]")
        } else {
            let titles = message.artifacts
                .filter { $0.type == "image" }
                .map { $0.title.isEmpty ? "用户上传图片" : $0.title }
            if !titles.isEmpty {
                content += "\n\n【用户附件】\n" + titles.map { "- \($0)" }.joined(separator: "\n")
            }
        }
        content = content.replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return ChatRequestMessage(role: message.role, content: content)
    }

    private static func replacing(_ pattern: String, in source: String, with replacement: String) -> String {
        source.replacingOccurrences(of: pattern, with: replacement, options: [.regularExpression, .caseInsensitive])
    }
}
