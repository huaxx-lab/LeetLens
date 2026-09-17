import Foundation
import XCTest
@testable import LeetCodeAssistant

final class QwenConversationEmbeddingProviderTests: XCTestCase {
    private final class StubProtocol: URLProtocol, @unchecked Sendable {
        struct Stub: Sendable { let status: Int; let body: Data }
        private static let lock = NSLock()
        nonisolated(unsafe) private static var stubs: [Stub] = []
        nonisolated(unsafe) private static var requests: [URLRequest] = []
        static func reset(_ values: [Stub]) { lock.withLock { stubs = values; requests = [] } }
        static var captured: [URLRequest] { lock.withLock { requests } }
        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func startLoading() {
            let stub: Stub? = Self.lock.withLock {
                Self.requests.append(request)
                return Self.stubs.isEmpty ? nil : Self.stubs.removeFirst()
            }
            guard let stub, let url = request.url,
                  let response = HTTPURLResponse(url: url, statusCode: stub.status, httpVersion: nil, headerFields: nil)
            else { client?.urlProtocol(self, didFailWithError: URLError(.resourceUnavailable)); return }
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: stub.body)
            client?.urlProtocolDidFinishLoading(self)
        }
        override func stopLoading() {}
    }

    func testNativeEndpointAndIdentityIncludeModelAndDimension() throws {
        let provider = try makeProvider(dimension: 256)
        XCTAssertEqual(
            QwenConversationEmbeddingProvider.endpoint(apiBase: "https://space.cn-beijing.maas.aliyuncs.com/compatible-mode/v1")?.absoluteString,
            "https://space.cn-beijing.maas.aliyuncs.com/api/v1/services/embeddings/text-embedding/text-embedding"
        )
        XCTAssertTrue(provider.identity.contains("text-embedding-v4"))
        XCTAssertTrue(provider.identity.hasSuffix("/d256"))
        XCTAssertNil(QwenConversationEmbeddingProvider.endpoint(apiBase: "https://api.example.com/v1"))
    }

    func testDocumentRequestUsesNativeTextTypeAndRestoresResponseOrder() async throws {
        StubProtocol.reset([.init(status: 200, body: response([
            ["text_index": 1, "embedding": vector(3)],
            ["text_index": 0, "embedding": vector(1)]
        ]))])
        let provider = try makeProvider(dimension: 256)
        let vectors = try await provider.embed(["first", "second"], textType: .document)
        XCTAssertEqual(vectors.map { $0[0] }, [1, 3])
        XCTAssertEqual(vectors.map(\.count), [256, 256])

        let request = try XCTUnwrap(StubProtocol.captured.first)
        XCTAssertEqual(request.url?.path, "/api/v1/services/embeddings/text-embedding/text-embedding")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer secret")
        let body = try XCTUnwrap(bodyData(of: request))
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        let input = try XCTUnwrap(root["input"] as? [String: Any])
        let parameters = try XCTUnwrap(root["parameters"] as? [String: Any])
        XCTAssertEqual(input["texts"] as? [String], ["first", "second"])
        XCTAssertEqual(parameters["text_type"] as? String, "document")
        XCTAssertEqual(parameters["output_type"] as? String, "dense")
        XCTAssertEqual((parameters["dimension"] as? NSNumber)?.intValue, 256)
    }

    func testQueryRequestUsesQueryTextType() async throws {
        StubProtocol.reset([.init(status: 200, body: response([["text_index": 0, "embedding": vector(1)]]))])
        let provider = try makeProvider(dimension: 256)
        _ = try await provider.embed(["怎么修复边界"], textType: .query)
        let body = try XCTUnwrap(bodyData(of: try XCTUnwrap(StubProtocol.captured.first)))
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        let parameters = try XCTUnwrap(root["parameters"] as? [String: Any])
        XCTAssertEqual(parameters["text_type"] as? String, "query")
    }

    func testMissingIndexDuplicateIndexAndWrongDimensionAreRejected() async throws {
        for rows in [
            [["text_index": 0, "embedding": vector(1)]],
            [["text_index": 0, "embedding": vector(1)], ["text_index": 0, "embedding": [3.0, 4.0]]],
            [["text_index": 0, "embedding": Array(repeating: 1.0, count: 255)], ["text_index": 1, "embedding": vector(3)]]
        ] {
            StubProtocol.reset([.init(status: 200, body: response(rows))])
            let provider = try makeProvider(dimension: 256)
            do {
                _ = try await provider.embed(["a", "b"], textType: .document)
                XCTFail("expected invalid response")
            } catch { }
        }
    }

    func testMaximumBatchSizeIsEnforcedBeforeNetwork() async throws {
        StubProtocol.reset([])
        let provider = try makeProvider(dimension: 256)
        do {
            _ = try await provider.embed(Array(repeating: "x", count: 21), textType: .document)
            XCTFail("expected too many inputs")
        } catch let error as ConversationEmbeddingError {
            XCTAssertEqual(error, .tooManyInputs(21))
        }
        XCTAssertTrue(StubProtocol.captured.isEmpty)
    }

    func testServer500RetriesExactlyThreeTimes() async throws {
        let failure = try JSONSerialization.data(withJSONObject: ["message": "temporary"])
        StubProtocol.reset(Array(repeating: .init(status: 500, body: failure), count: 3))
        let provider = try makeProvider(dimension: 256)
        do {
            _ = try await provider.embed(["x"], textType: .query)
            XCTFail("expected failure")
        } catch let error as ConversationEmbeddingError {
            XCTAssertEqual(error, .server(status: 500, message: "temporary"))
        }
        XCTAssertEqual(StubProtocol.captured.count, 3)
    }

    private func makeProvider(dimension: Int) throws -> QwenConversationEmbeddingProvider {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubProtocol.self]
        return try QwenConversationEmbeddingProvider(
            apiBase: "https://space.cn-beijing.maas.aliyuncs.com/compatible-mode/v1",
            apiKey: "secret", dimension: dimension,
            session: URLSession(configuration: configuration),
            retryPolicy: .init(maximumAttempts: 3, baseSeconds: 0, factor: 2, capSeconds: 0, jitter: 0),
            sleep: { _ in }
        )
    }

    private func vector(_ seed: Double) -> [Double] {
        [seed] + Array(repeating: 0, count: 255)
    }

    private func response(_ rows: [[String: Any]]) -> Data {
        try! JSONSerialization.data(withJSONObject: ["output": ["embeddings": rows]])
    }

    private func bodyData(of request: URLRequest) -> Data? {
        if let data = request.httpBody { return data }
        guard let stream = request.httpBodyStream else { return nil }
        stream.open(); defer { stream.close() }
        var data = Data(), buffer = [UInt8](repeating: 0, count: 4_096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { break }
            data.append(buffer, count: count)
        }
        return data
    }
}
