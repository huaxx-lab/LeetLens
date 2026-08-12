import CryptoKit
import Foundation

actor LeetCodeHintTranslator {
    private let chatService: ChatService
    private let dataDirectory: URL

    init(dataDirectory: URL, session: URLSession = .shared) {
        self.dataDirectory = dataDirectory
        chatService = ChatService(dataDirectory: dataDirectory, session: session)
    }

    func chineseHints(titleSlug: String, hints: [String]) async throws -> [String] {
        guard !hints.isEmpty else { return [] }
        if hints.allSatisfy(Self.containsChinese) { return hints }

        let cacheKey = Self.cacheKey(titleSlug: titleSlug, hints: hints)
        if let data = await RedisClient.shared.get(cacheKey),
           let cached = try? JSONDecoder().decode([String].self, from: data),
           Self.isValid(cached, expectedCount: hints.count) {
            return cached
        }

        let payload = try JSONEncoder().encode(hints)
        let accounting = DeferredAIUsageAccounting()
        do {
            var output = ""
            for try await chunk in chatService.stream(
                messages: [
                    ChatRequestMessage(
                        role: "system",
                        content: "你是技术文档翻译器。把输入 JSON 数组逐项翻译为简体中文，保留代码、变量名和复杂度表达式；只返回同长度 JSON 字符串数组，不要解释。"
                    ),
                    ChatRequestMessage(role: "user", content: String(decoding: payload, as: UTF8.self))
                ],
                reasoningLevel: .off,
                taskRoute: .leetCodeAnalysis,
                deferredUsage: accounting
            ) {
                if case .text(let text) = chunk { output += text }
            }

            guard let start = output.firstIndex(of: "["),
                  let end = output.lastIndex(of: "]"),
                  start <= end,
                  let data = String(output[start...end]).data(using: .utf8),
                  let translated = try? JSONDecoder().decode([String].self, from: data),
                  Self.isValid(translated, expectedCount: hints.count)
            else { throw ChatServiceError.invalidResponse }
            try Task.checkCancellation()
            await accounting.commit(outcome: .succeeded, dataDirectory: dataDirectory)

            if let encoded = try? JSONEncoder().encode(translated) {
                await RedisClient.shared.setValue(encoded, for: cacheKey, ttl: 60 * 60 * 24 * 180)
            }
            return translated
        } catch let error where ChatService.isCancellation(error) {
            if !(await accounting.commitIfStaged(outcome: .cancelled, dataDirectory: dataDirectory)) {
                await recordPreflightFailure(outcome: .cancelled)
            }
            throw CancellationError()
        } catch {
            if !(await accounting.commitIfStaged(outcome: .failed, dataDirectory: dataDirectory)) {
                await recordPreflightFailure(outcome: .failed)
            }
            throw error
        }
    }

    private func recordPreflightFailure(outcome: AIUsageOutcome) async {
        await AIUsageLedger.shared.record(
            AIUsageEntry(
                taskRoute: .leetCodeAnalysis,
                conversationID: nil,
                providerID: "",
                usage: ConversationUsage(),
                outcome: outcome,
                durationMilliseconds: 0
            ),
            dataDirectory: dataDirectory
        )
    }

    private static func cacheKey(titleSlug: String, hints: [String]) -> String {
        let source = Data((titleSlug + "\n" + hints.joined(separator: "\n---\n")).utf8)
        let digest = SHA256.hash(data: source).map { String(format: "%02x", $0) }.joined()
        return "leetcode:hints:zh:v1:\(digest)"
    }

    private static func isValid(_ values: [String], expectedCount: Int) -> Bool {
        values.count == expectedCount
            && values.allSatisfy { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            && values.contains(where: containsChinese)
    }

    private static func containsChinese(_ value: String) -> Bool {
        value.unicodeScalars.contains { (0x4E00...0x9FFF).contains($0.value) }
    }
}
