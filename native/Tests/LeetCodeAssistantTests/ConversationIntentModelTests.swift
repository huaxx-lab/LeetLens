import Foundation
import XCTest
@testable import LeetCodeAssistant

final class ConversationIntentModelTests: XCTestCase {
    private final class StubProtocol: URLProtocol, @unchecked Sendable {
        private static let lock = NSLock()
        nonisolated(unsafe) private static var responseBody = Data()
        nonisolated(unsafe) private static var requests: [URLRequest] = []

        static func reset(body: String) {
            lock.withLock {
                responseBody = Data(body.utf8)
                requests = []
            }
        }

        static var captured: [URLRequest] { lock.withLock { requests } }

        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func startLoading() {
            let body = Self.lock.withLock { () -> Data in
                Self.requests.append(request)
                return Self.responseBody
            }
            guard let url = request.url,
                  let response = HTTPURLResponse(
                    url: url,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "text/event-stream"]
                  ) else {
                client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
                return
            }
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: body)
            client?.urlProtocolDidFinishLoading(self)
        }
        override func stopLoading() {}
    }
    private func message(_ id: String, _ role: String, _ content: String) -> ConversationTranscriptMessage {
        ConversationTranscriptMessage(id: id, role: role, content: content, createdAt: .now)
    }

    private static func bodyData(of request: URLRequest) -> Data? {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var result = Data()
        var buffer = [UInt8](repeating: 0, count: 4_096)
        while stream.hasBytesAvailable {
            let read = stream.read(&buffer, maxLength: buffer.count)
            guard read > 0 else { break }
            result.append(buffer, count: read)
        }
        return result
    }

    // MARK: - Window-proportional projection

    func testProjectionBudgetIsProportionalAndClamped() {
        XCTAssertEqual(ConversationIntentContextProjection.tokenBudget(availableInputTokens: 4_096), 256)
        XCTAssertEqual(ConversationIntentContextProjection.tokenBudget(availableInputTokens: 32_000), 1_280)
        XCTAssertEqual(ConversationIntentContextProjection.tokenBudget(availableInputTokens: 1_000_000), 4_096)
    }

    func testProjectionUsesOnlyMessagesBeforeCurrentAndKeepsCurrentVerbatim() throws {
        let messages = [
            message("u1", "user", "接雨水怎么做？"),
            message("a1", "assistant", "可以用单调栈，也可以双指针。"),
            message("u2", "user", "那这个复杂度呢？"),
            message("a2", "assistant", "这是未来消息，绝不能泄漏进指代消解。")
        ]
        let projection = try XCTUnwrap(ConversationIntentContextProjection.build(
            messages: messages,
            currentMessageID: "u2",
            contextSummary: "更老的摘要",
            directory: [
                ConversationMemoryDirectoryEntry(
                    conversationID: "private-id",
                    title: "接雨水双指针复盘",
                    gist: "讨论左右最高柱子",
                    updatedAt: .now
                )
            ],
            availableInputTokens: 32_000
        ))

        XCTAssertEqual(projection.currentQuery, "那这个复杂度呢？")
        XCTAssertEqual(projection.recentMessages.map(\.content), ["接雨水怎么做？", "可以用单调栈，也可以双指针。"])
        XCTAssertFalse(projection.recentMessages.contains { $0.content.contains("未来消息") })
        XCTAssertEqual(projection.conversationDirectory.map(\.title), ["接雨水双指针复盘"])
        let encoded = String(decoding: try JSONEncoder().encode(projection), as: UTF8.self)
        XCTAssertFalse(encoded.contains("private-id"), "目录 id 是本地标识，不需要发给模型")
        XCTAssertFalse(encoded.contains("tokenBudget"), "诊断字段不该占模型输入")
        XCTAssertLessThanOrEqual(projection.estimatedTokens, projection.tokenBudget)
    }

    func testProjectionSanitizesAssistantThoughtWithoutMutatingSource() throws {
        let source = "<think>私有推理</think>结论是双指针。\n![图](secret.png)"
        let messages = [
            message("u1", "user", "接雨水"),
            message("a1", "assistant", source),
            message("u2", "user", "再详细点")
        ]
        let projection = try XCTUnwrap(ConversationIntentContextProjection.build(
            messages: messages,
            currentMessageID: "u2",
            contextSummary: "",
            availableInputTokens: 32_000
        ))

        let assistant = try XCTUnwrap(projection.recentMessages.last)
        XCTAssertFalse(assistant.content.contains("私有推理"))
        XCTAssertFalse(assistant.content.contains("secret.png"))
        XCTAssertEqual(messages[1].content, source, "清洗只能作用于投影，原始 ledger 不许改")
    }

    func testProjectionNeverCutsOversizedCurrentQuery() {
        let huge = String(repeating: "这是一个完整但非常长的当前问题。", count: 200)
        XCTAssertNil(ConversationIntentContextProjection.build(
            messages: [message("u", "user", huge)],
            currentMessageID: "u",
            contextSummary: "",
            availableInputTokens: 4_096
        ))
    }

    func testProjectionDropsOversizedAdjacentSentenceInsteadOfUsingOlderTail() throws {
        let oversizedLatest = String(repeating: "很长", count: 400) + "。"
        let messages = [
            message("u1", "user", "更老但很短。"),
            message("a1", "assistant", oversizedLatest),
            message("u2", "user", "这个呢？")
        ]
        let projection = try XCTUnwrap(ConversationIntentContextProjection.build(
            messages: messages,
            currentMessageID: "u2",
            contextSummary: "",
            availableInputTokens: 4_096
        ))
        XCTAssertTrue(projection.recentMessages.isEmpty,
                      "紧邻消息放不下就停止，不能跳过去拼更老内容制造错误指代")
    }

    // MARK: - Decision semantics

    func testModelResolutionProducesSelfContainedRetrievalQuery() {
        let rule = ConversationIntentResolution(
            intent: .followUp,
            needs: .crossConversationRAG,
            confidence: .ambiguous,
            mentionsReference: true
        )
        let decision = ConversationRetrievalDecision.modelResolved(
            rule: rule,
            model: .init(shouldRetrieve: true, retrievalQuery: "接雨水双指针解法的时间复杂度"),
            originalQuery: "这个复杂度呢"
        )
        XCTAssertTrue(decision.resolution.wantsRetrieval)
        XCTAssertEqual(decision.resolution.confidence, .confident)
        XCTAssertEqual(decision.retrievalQuery, "接雨水双指针解法的时间复杂度")
        XCTAssertTrue(decision.usedModelFallback)
    }

    func testModelCannotReverseExplicitHistoryRecall() {
        let rule = ConversationIntentResolution(
            intent: .recall,
            needs: .crossConversationRAG,
            confidence: .ambiguous,
            mentionsReference: true
        )
        let decision = ConversationRetrievalDecision.modelResolved(
            rule: rule,
            model: .init(shouldRetrieve: false, retrievalQuery: ""),
            originalQuery: "上次那个"
        )
        XCTAssertTrue(decision.resolution.wantsRetrieval)
        XCTAssertEqual(decision.retrievalQuery, "上次那个")
    }

    func testModelCanOverrideInheritedRetrievalNeed() {
        let rule = ConversationIntentResolution(
            intent: .followUp,
            needs: .crossConversationRAG,
            confidence: .ambiguous,
            mentionsReference: true
        )
        let decision = ConversationRetrievalDecision.modelResolved(
            rule: rule,
            model: .init(shouldRetrieve: false, retrievalQuery: "不该使用"),
            originalQuery: "再详细点"
        )
        XCTAssertFalse(decision.resolution.wantsRetrieval)
        XCTAssertEqual(decision.retrievalQuery, "再详细点")
    }

    func testEmptyModelRewriteFallsBackToOriginalInsteadOfDroppingRecall() {
        let rule = ConversationIntentResolution(
            intent: .followUp,
            needs: .crossConversationRAG,
            confidence: .ambiguous,
            mentionsReference: true
        )
        let decision = ConversationRetrievalDecision.modelResolved(
            rule: rule,
            model: .init(shouldRetrieve: true, retrievalQuery: "   "),
            originalQuery: "力扣 42 那道题"
        )
        XCTAssertEqual(decision.retrievalQuery, "力扣 42 那道题")
    }

    // MARK: - Wire response validation

    func testResponseRepairsCommonBooleanShapes() throws {
        for raw in ["true", "yes", "retrieve", "1"] {
            let data = Data(#"{"shouldRetrieve":"\#(raw)","retrievalQuery":"接雨水复杂度"}"#.utf8)
            XCTAssertTrue(try JSONDecoder().decode(ConversationIntentModelResponse.self, from: data).decision().shouldRetrieve)
        }
        let numeric = try JSONDecoder().decode(
            ConversationIntentModelResponse.self,
            from: Data(#"{"shouldRetrieve":0,"retrievalQuery":"ignored"}"#.utf8)
        )
        XCTAssertFalse(try numeric.decision().shouldRetrieve)
        XCTAssertEqual(try numeric.decision().retrievalQuery, "")
    }

    func testResponseRejectsMissingDecisionAndEmptyRequiredRewrite() throws {
        XCTAssertThrowsError(try JSONDecoder().decode(
            ConversationIntentModelResponse.self,
            from: Data(#"{"retrievalQuery":"接雨水"}"#.utf8)
        ))
        let empty = try JSONDecoder().decode(
            ConversationIntentModelResponse.self,
            from: Data(#"{"shouldRetrieve":true,"retrievalQuery":""}"#.utf8)
        )
        XCTAssertThrowsError(try empty.decision())
    }

    func testProjectionNeverCutsAFencedCodeBlock() throws {
        let code = """
        先看这一句。
        ```java
        class Solution {
            int answer() { return 42; }
        }
        ```
        """
        let messages = [
            message("u1", "user", "看代码"),
            message("a1", "assistant", code),
            message("u2", "user", "这个呢？")
        ]
        let projection = try XCTUnwrap(ConversationIntentContextProjection.build(
            messages: messages,
            currentMessageID: "u2",
            contextSummary: "",
            availableInputTokens: 8_000
        ))
        if let assistant = projection.recentMessages.last?.content,
           assistant.contains("```java") {
            XCTAssertEqual(assistant.components(separatedBy: "```").count - 1, 2,
                           "代码块进入投影时必须同时有开、闭两道 fence")
            XCTAssertTrue(assistant.contains("return 42"))
        }
    }

    func testChatServiceUsesMemoryQueryRouteAndKeepsDecisionOutOfTranscript() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "intent-model-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let settings: [String: Any] = [
            "activeProvider": "main",
            "providers": [
                "main": [
                    "name": "Main", "apiBase": "https://api.example.com/v1",
                    "apiKey": "secret", "apiMode": "chat", "model": "expensive"
                ],
                "cheap": [
                    "name": "Cheap", "apiBase": "https://api.example.com/v1",
                    "apiKey": "secret", "apiMode": "chat", "model": "cheap-model"
                ]
            ],
            "taskModels": ["memoryQuery": ["providerId": "cheap"]]
        ]
        let settingsData = try JSONSerialization.data(withJSONObject: settings)
        try settingsData.write(to: directory.appending(path: "settings.json"))
        let transcriptURL = directory.appending(path: "conversations.json")
        let transcript = Data(#"{"c":{"messages":[{"id":"u","role":"user","content":"这个呢"}]}}"#.utf8)
        try transcript.write(to: transcriptURL)

        let output = #"{"shouldRetrieve":true,"retrievalQuery":"接雨水双指针复杂度"}"#
        let escaped = try XCTUnwrap(String(
            data: JSONSerialization.data(withJSONObject: [
                "choices": [["delta": ["content": output]]]
            ]),
            encoding: .utf8
        ))
        StubProtocol.reset(body: "data: \(escaped)\n\ndata: [DONE]\n\n")
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubProtocol.self]
        let service = ChatService(dataDirectory: directory, session: URLSession(configuration: config))
        let projection = try XCTUnwrap(ConversationIntentContextProjection.build(
            messages: [message("u1", "user", "接雨水"), message("u2", "user", "这个呢")],
            currentMessageID: "u2",
            contextSummary: "",
            availableInputTokens: 32_000
        ))

        let decision = try await service.resolveConversationRetrievalIntent(
            context: projection,
            providerID: "main",
            conversationID: "c"
        )
        XCTAssertEqual(decision, .init(shouldRetrieve: true, retrievalQuery: "接雨水双指针复杂度"))

        let request = try XCTUnwrap(StubProtocol.captured.first)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer secret")
        let body = try XCTUnwrap(Self.bodyData(of: request))
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(root["model"] as? String, "expensive",
                       "必须跟随主对话供应商，不能采纳跨信任边界的 memoryQuery 路由")
        let wire = try XCTUnwrap(root["messages"] as? [[String: Any]])
        XCTAssertEqual(wire.count, 2, "小调用只包含 system + 投影 JSON")
        XCTAssertTrue((wire[0]["content"] as? String)?.contains("指代消解") == true)
        XCTAssertTrue((wire[1]["content"] as? String)?.contains("currentQuery") == true)
        XCTAssertEqual(try Data(contentsOf: transcriptURL), transcript,
                       "模型判定与改写只供检索器使用，绝不能写进 transcript")
    }

    // MARK: - Per-message LRU

    func testCacheKeysByConversationAndMessageAndEvictsLeastRecent() async {
        let cache = ConversationIntentDecisionCache(capacity: 2)
        let value = ConversationRetrievalDecision.ruleOnly(
            resolution: .init(intent: .knowledge, needs: .crossConversationRAG,
                              confidence: .confident, mentionsReference: false),
            originalQuery: "q"
        )
        let a = ConversationIntentCacheKey(conversationID: "c1", messageID: "m1")
        let b = ConversationIntentCacheKey(conversationID: "c1", messageID: "m2")
        let c = ConversationIntentCacheKey(conversationID: "c2", messageID: "m1")
        await cache.insert(value, for: a)
        await cache.insert(value, for: b)
        _ = await cache.value(for: a) // a 变成最近使用
        await cache.insert(value, for: c)

        let cachedA = await cache.value(for: a)
        let cachedB = await cache.value(for: b)
        let cachedC = await cache.value(for: c)
        let count = await cache.count
        XCTAssertNotNil(cachedA)
        XCTAssertNil(cachedB)
        XCTAssertNotNil(cachedC)
        XCTAssertEqual(count, 2)
    }
}
