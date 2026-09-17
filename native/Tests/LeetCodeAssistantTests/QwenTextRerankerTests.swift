import Foundation
import XCTest
@testable import LeetCodeAssistant

final class QwenTextRerankerTests: XCTestCase {
    private final class StubProtocol: URLProtocol, @unchecked Sendable {
        struct Stub: Sendable {
            let status: Int
            let headers: [String: String]
            let body: Data
        }
        private static let lock = NSLock()
        nonisolated(unsafe) private static var stubs: [Stub] = []
        nonisolated(unsafe) private static var requests: [URLRequest] = []

        static func reset(_ values: [Stub]) {
            lock.withLock { stubs = values; requests = [] }
        }
        static var captured: [URLRequest] { lock.withLock { requests } }

        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func startLoading() {
            let stub: Stub? = Self.lock.withLock {
                Self.requests.append(request)
                return Self.stubs.isEmpty ? nil : Self.stubs.removeFirst()
            }
            guard let stub, let url = request.url,
                  let response = HTTPURLResponse(url: url, statusCode: stub.status, httpVersion: nil, headerFields: stub.headers)
            else {
                client?.urlProtocol(self, didFailWithError: URLError(.resourceUnavailable)); return
            }
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: stub.body)
            client?.urlProtocolDidFinishLoading(self)
        }
        override func stopLoading() {}
    }

    func testEndpointPreservesWorkspaceHostAndReplacesPath() {
        XCTAssertEqual(
            QwenTextReranker.endpoint(apiBase: "https://space.cn-beijing.maas.aliyuncs.com/compatible-mode/v1")?.absoluteString,
            "https://space.cn-beijing.maas.aliyuncs.com/compatible-api/v1/reranks"
        )
        XCTAssertEqual(
            QwenTextReranker.endpoint(
                apiBase: "https://space.cn-beijing.maas.aliyuncs.com/compatible-mode/v1",
                model: "qwen3.7-text-rerank"
            )?.path,
            "/api/v1/services/rerank/text-rerank/text-rerank"
        )
        XCTAssertNil(QwenTextReranker.endpoint(apiBase: "https://api.example.com/v1"), "不能把 Key 发给未知 host")
        XCTAssertNil(QwenTextReranker.endpoint(apiBase: "http://space.cn-beijing.maas.aliyuncs.com"))
    }

    func testBudgetDropsWholeTailDocumentsAndNeverTruncates() {
        let documents = [
            TextRerankDocument(id: "a", text: "第一句完整。"),
            TextRerankDocument(id: "b", text: String(repeating: "很长的一整句", count: 40)),
            TextRerankDocument(id: "c", text: "最后一段。")
        ]
        let admitted = QwenTextReranker.admittedDocuments(
            query: "查询",
            documents: documents,
            limits: .init(maximumDocuments: 3, maximumDocumentTokens: 100, maximumRequestTokens: 20)
        )
        XCTAssertEqual(admitted.map(\.document.id), ["a", "c"], "超长块整块跳过，后面的完整短块仍可准入")
        XCTAssertEqual(admitted[0].document.text, documents[0].text, "准入只能整块保留，不能改文本")
        XCTAssertEqual(admitted[1].document.text, documents[2].text)
    }

    func testOversizedSingleDocumentIsSkippedWithoutBlockingNextWholeDocument() {
        let documents = [
            TextRerankDocument(id: "huge", text: String(repeating: "字", count: 100)),
            TextRerankDocument(id: "small", text: "完整小句。")
        ]
        let admitted = QwenTextReranker.admittedDocuments(
            query: "查询",
            documents: documents,
            limits: .init(maximumDocuments: 2, maximumDocumentTokens: 10, maximumRequestTokens: 30)
        )
        XCTAssertEqual(admitted.map(\.document.id), ["small"])
        XCTAssertEqual(admitted.map(\.originalIndex), [1])
    }

    func testSuccessfulResponseMapsRemoteIndexBackToPrivateLocalID() async throws {
        StubProtocol.reset([.init(status: 200, headers: [:], body: response([
            ["index": 1, "relevance_score": 0.92],
            ["index": 0, "relevance_score": 0.13]
        ]))])
        let reranker = try makeReranker()
        let hits = try await reranker.rerank(
            query: "接雨水",
            documents: [.init(id: "private-a", text: "A"), .init(id: "private-b", text: "B")],
            topN: 2
        )
        XCTAssertEqual(hits.map(\.id), ["private-b", "private-a"])
        XCTAssertEqual(hits.map(\.originalIndex), [1, 0])
        let request = try XCTUnwrap(StubProtocol.captured.first)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer secret")
        let body = try XCTUnwrap(Self.bodyData(of: request))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertNil(String(data: body, encoding: .utf8)?.range(of: "private-a"), "私有文档 id 不应发送")
        XCTAssertEqual(object["documents"] as? [String], ["A", "B"])
        XCTAssertEqual(object["query"] as? String, "接雨水")
        XCTAssertEqual((object["top_n"] as? NSNumber)?.intValue, 2)
    }

    func testServer500RetriesAtMostThreeAttemptsThenReturnsNaturalError() async throws {
        let failure = try JSONSerialization.data(withJSONObject: ["message": "temporary unavailable"])
        StubProtocol.reset(Array(repeating: .init(status: 500, headers: [:], body: failure), count: 3))
        let reranker = try makeReranker()
        do {
            _ = try await reranker.rerank(query: "q", documents: [.init(id: "a", text: "doc")], topN: 1)
            XCTFail("expected failure")
        } catch let error as TextRerankerError {
            XCTAssertEqual(error, .server(status: 500, message: "temporary unavailable"))
            XCTAssertTrue(error.localizedDescription.contains("重排序服务请求失败"))
        }
        XCTAssertEqual(StubProtocol.captured.count, 3)
    }

    func testBadRequestDoesNotRetry() async throws {
        let body = try JSONSerialization.data(withJSONObject: ["message": "bad input"])
        StubProtocol.reset([.init(status: 400, headers: [:], body: body)])
        let reranker = try makeReranker()
        await XCTAssertThrowsErrorAsync {
            _ = try await reranker.rerank(query: "q", documents: [.init(id: "a", text: "doc")], topN: 1)
        }
        XCTAssertEqual(StubProtocol.captured.count, 1)
    }

    func testRetryAfterHeaderOverridesExponentialDelay() async throws {
        let failure = try JSONSerialization.data(withJSONObject: ["message": "slow down"])
        StubProtocol.reset([
            .init(status: 429, headers: ["Retry-After": "2"], body: failure),
            .init(status: 200, headers: [:], body: response([["index": 0, "relevance_score": 0.8]]))
        ])
        let recorder = DelayRecorder()
        let reranker = try makeReranker(sleep: { duration in await recorder.append(duration) })
        let hits = try await reranker.rerank(query: "q", documents: [.init(id: "a", text: "doc")], topN: 1)
        XCTAssertEqual(hits.first?.id, "a")
        let delays = await recorder.values
        XCTAssertEqual(delays, [.seconds(2)])
    }

    private actor DelayRecorder {
        var values: [Duration] = []
        func append(_ value: Duration) { values.append(value) }
    }

    private func makeReranker(
        sleep: @escaping @Sendable (Duration) async throws -> Void = { _ in }
    ) throws -> QwenTextReranker {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubProtocol.self]
        return try QwenTextReranker(
            apiBase: "https://space.cn-beijing.maas.aliyuncs.com/compatible-mode/v1",
            apiKey: "secret",
            session: URLSession(configuration: configuration),
            retryPolicy: .init(maximumAttempts: 3, baseSeconds: 0, factor: 2, capSeconds: 0, jitter: 0),
            sleep: sleep
        )
    }

    private static func bodyData(of request: URLRequest) -> Data? {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4_096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { break }
            data.append(buffer, count: count)
        }
        return data
    }

    private func response(_ results: [[String: Any]]) -> Data {
        try! JSONSerialization.data(withJSONObject: ["results": results])
    }
}

private extension XCTestCase {
    func XCTAssertThrowsErrorAsync(
        _ expression: () async throws -> Void,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do { try await expression(); XCTFail("expected error", file: file, line: line) }
        catch { }
    }
}
