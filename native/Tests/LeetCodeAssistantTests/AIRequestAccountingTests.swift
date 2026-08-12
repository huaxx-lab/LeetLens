import Foundation
import XCTest
@testable import LeetCodeAssistant

final class AIRequestAccountingTests: XCTestCase {
    private final class StubURLProtocol: URLProtocol, @unchecked Sendable {
        struct Response: Sendable {
            let statusCode: Int
            let headers: [String: String]
            let body: Data
            let delayNanoseconds: UInt64

            init(
                statusCode: Int = 200,
                headers: [String: String] = [:],
                body: Data = Data(),
                delayNanoseconds: UInt64 = 0
            ) {
                self.statusCode = statusCode
                self.headers = headers
                self.body = body
                self.delayNanoseconds = delayNanoseconds
            }
        }

        private static let lock = NSLock()
        nonisolated(unsafe) private static var responses: [Response] = []
        nonisolated(unsafe) private static var requests: [URLRequest] = []
        nonisolated(unsafe) private static var pendingProtocols: [StubURLProtocol] = []

        static func reset(_ newResponses: [Response]) {
            lock.lock()
            responses = newResponses
            requests = []
            pendingProtocols = []
            lock.unlock()
        }

        static var capturedRequests: [URLRequest] {
            lock.lock()
            defer { lock.unlock() }
            return requests
        }

        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

        override func startLoading() {
            let response: Response?
            Self.lock.lock()
            Self.requests.append(request)
            response = Self.responses.isEmpty ? nil : Self.responses.removeFirst()
            Self.lock.unlock()

            guard let response else {
                client?.urlProtocol(self, didFailWithError: URLError(.resourceUnavailable))
                return
            }
            guard response.delayNanoseconds == 0 else {
                Self.lock.lock()
                Self.pendingProtocols.append(self)
                Self.lock.unlock()
                return
            }
            guard let url = request.url,
                  let http = HTTPURLResponse(
                    url: url,
                    statusCode: response.statusCode,
                    httpVersion: "HTTP/1.1",
                    headerFields: response.headers
                  )
            else { return }
            client?.urlProtocol(self, didReceive: http, cacheStoragePolicy: .notAllowed)
            if !response.body.isEmpty { client?.urlProtocol(self, didLoad: response.body) }
            client?.urlProtocolDidFinishLoading(self)
        }

        override func stopLoading() {
            Self.lock.lock()
            Self.pendingProtocols.removeAll { $0 === self }
            Self.lock.unlock()
        }
    }

    private func makeDirectory(providerID: String = "p1", apiBase: String = "https://api.example.com/v1") throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "AIRequestAccounting-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let settings: [String: Any] = [
            "providerOrder": [providerID],
            "activeProvider": providerID,
            "providers": [providerID: [
                "name": "测试供应商",
                "apiBase": apiBase,
                "apiKey": "test-key",
                "model": "test-model",
                "apiMode": "chat",
                "resolvedMode": "chat"
            ]]
        ]
        try JSONSerialization.data(withJSONObject: settings)
            .write(to: directory.appending(path: "settings.json"), options: .atomic)
        return directory
    }

    private func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    private func streamBody(_ text: String, promptTokens: Int = 12, completionTokens: Int = 6) -> Data {
        let encoded = try! JSONSerialization.data(withJSONObject: [
            "choices": [["delta": ["content": text]]],
            "model": "test-model"
        ])
        let usage = try! JSONSerialization.data(withJSONObject: [
            "choices": [],
            "model": "test-model",
            "usage": [
                "prompt_tokens": promptTokens,
                "completion_tokens": completionTokens,
                "total_tokens": promptTokens + completionTokens
            ]
        ])
        return Data("data: \(String(decoding: encoded, as: UTF8.self))\n\ndata: \(String(decoding: usage, as: UTF8.self))\n\ndata: [DONE]\n\n".utf8)
    }

    private func analysisSubmission(id: String = "1") -> LeetCodeTrajectoryPromptSubmission {
        LeetCodeTrajectoryPromptSubmission(
            id: id,
            code: "return []",
            language: "swift",
            status: "Wrong Answer",
            runtime: "1 ms",
            memory: "10 MB",
            runtimeError: "",
            compileError: "",
            lastTestCase: "[]",
            actualOutput: "[]",
            expectedOutput: "[1]",
            correctCaseCount: 0,
            totalCaseCount: 1
        )
    }

    func testTrajectoryMalformedJSONRecordsExactlyOneFailedRequest() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        StubURLProtocol.reset([.init(headers: ["Content-Type": "text/event-stream"], body: streamBody("not-json"))])
        let service = LeetCodeAnalysisService(dataDirectory: directory, session: makeSession())

        do {
            _ = try await service.analyzeTrajectory(
                titleSlug: "two-sum",
                title: "两数之和",
                topicTags: ["数组"],
                previous: nil,
                submissions: [analysisSubmission()],
                providerID: "p1"
            )
            XCTFail("Malformed structured output must fail")
        } catch {}

        let snapshot = await AIUsageLedger.shared.snapshot(dataDirectory: directory)
        XCTAssertEqual(snapshot.totals.requestCount, 1)
        XCTAssertEqual(snapshot.totals.failedRequests, 1)
        XCTAssertEqual(snapshot.totals.succeededRequests, 0)
        XCTAssertEqual(snapshot.byTask[AITaskRoute.leetCodeAnalysis.rawValue]?.requestCount, 1)
        XCTAssertEqual(StubURLProtocol.capturedRequests.count, 1)
    }

    func testTrajectorySemanticFailureRecordsExactlyOneFailedRequest() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let invalid = #"{"summary":"泛泛总结","attemptInsights":[{"submissionId":"unknown","issue":"问题","change":"修改","outcome":"结果"}],"weaknesses":[],"improvements":[]}"#
        StubURLProtocol.reset([.init(headers: ["Content-Type": "text/event-stream"], body: streamBody(invalid))])
        let service = LeetCodeAnalysisService(dataDirectory: directory, session: makeSession())

        do {
            _ = try await service.analyzeTrajectory(
                titleSlug: "two-sum",
                title: "两数之和",
                topicTags: [],
                previous: nil,
                submissions: [analysisSubmission()],
                providerID: "p1"
            )
            XCTFail("Semantically invalid output must fail")
        } catch {}

        let snapshot = await AIUsageLedger.shared.snapshot(dataDirectory: directory)
        XCTAssertEqual(snapshot.totals.requestCount, 1)
        XCTAssertEqual(snapshot.totals.failedRequests, 1)
        XCTAssertEqual(snapshot.totals.succeededRequests, 0)
    }

    func testTrajectoryValidResponseRecordsExactlyOneSucceededRequest() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let valid = #"{"summary":"补齐边界后通过","attemptInsights":[{"submissionId":"1","issue":"边界遗漏","change":"补充分支","outcome":"通过"}],"weaknesses":["边界"],"improvements":["补测试"]}"#
        StubURLProtocol.reset([.init(headers: ["Content-Type": "text/event-stream"], body: streamBody(valid))])
        let service = LeetCodeAnalysisService(dataDirectory: directory, session: makeSession())

        let draft = try await service.analyzeTrajectory(
            titleSlug: "two-sum",
            title: "两数之和",
            topicTags: [],
            previous: nil,
            submissions: [analysisSubmission()],
            providerID: "p1"
        )

        XCTAssertEqual(draft.attemptInsights.first?.submissionId, "1")
        let snapshot = await AIUsageLedger.shared.snapshot(dataDirectory: directory)
        XCTAssertEqual(snapshot.totals.requestCount, 1)
        XCTAssertEqual(snapshot.totals.succeededRequests, 1)
        XCTAssertEqual(snapshot.totals.failedRequests, 0)
        XCTAssertEqual(snapshot.totals.totalTokens, 18)
        XCTAssertEqual(snapshot.byProvider["p1"]?.requestCount, 1)
    }

    func testTrajectoryCancellationRecordsExactlyOneCancelledRequest() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        StubURLProtocol.reset([.init(
            headers: ["Content-Type": "text/event-stream"],
            body: streamBody("{}"),
            delayNanoseconds: 5_000_000_000
        )])
        let service = LeetCodeAnalysisService(dataDirectory: directory, session: makeSession())
        let submission = analysisSubmission()
        let task = Task {
            try Task.checkCancellation()
            return try await service.analyzeTrajectory(
                titleSlug: "two-sum",
                title: "两数之和",
                topicTags: [],
                previous: nil,
                submissions: [submission],
                providerID: "p1"
            )
        }
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("Cancelled request must throw")
        } catch is CancellationError {}

        // If cancellation wins before provider resolution there is intentionally no model
        // request to account. If it wins after preflight, the single ledger entry is cancelled.
        let snapshot = await AIUsageLedger.shared.snapshot(dataDirectory: directory)
        XCTAssertLessThanOrEqual(snapshot.totals.requestCount, 1)
        XCTAssertEqual(snapshot.totals.succeededRequests, 0)
        XCTAssertEqual(snapshot.totals.failedRequests, 0)
        if snapshot.totals.requestCount == 1 {
            XCTAssertEqual(snapshot.totals.cancelledRequests, 1)
        }
    }

    func testInvalidExplicitProviderFailsWithoutNetworkRequest() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        StubURLProtocol.reset([])
        let service = ChatService(dataDirectory: directory, session: makeSession())

        do {
            for try await _ in service.stream(
                messages: [ChatRequestMessage(role: "user", content: "hello")],
                reasoningLevel: .off,
                providerID: "missing",
                taskRoute: .conversation
            ) {}
            XCTFail("Missing explicit provider must fail")
        } catch {}

        XCTAssertTrue(StubURLProtocol.capturedRequests.isEmpty)
        let snapshot = await AIUsageLedger.shared.snapshot(dataDirectory: directory)
        XCTAssertEqual(snapshot.totals.requestCount, 1)
        XCTAssertEqual(snapshot.totals.failedRequests, 1)
        XCTAssertEqual(snapshot.totals.totalTokens, 0)
    }

    func testListModelsRetriesOnlyForMissingMetadataRoute() async throws {
        let directory = try makeDirectory(apiBase: "https://api.example.com")
        defer { try? FileManager.default.removeItem(at: directory) }
        let service = ChatService(dataDirectory: directory, session: makeSession())

        StubURLProtocol.reset([
            .init(statusCode: 404, body: Data("missing".utf8)),
            .init(body: Data(#"{"data":[{"id":"model-a"}]}"#.utf8))
        ])
        let models = try await service.listModels(providerID: "p1")
        XCTAssertEqual(models, ["model-a"])
        XCTAssertEqual(StubURLProtocol.capturedRequests.map { $0.url?.path }, ["/models", "/v1/models"])

        StubURLProtocol.reset([
            .init(statusCode: 401, body: Data("unauthorized".utf8)),
            .init(body: Data(#"{"data":[{"id":"must-not-run"}]}"#.utf8))
        ])
        do {
            _ = try await service.listModels(providerID: "p1")
            XCTFail("Authentication failure must not retry another credentialed route")
        } catch {}
        XCTAssertEqual(StubURLProtocol.capturedRequests.count, 1)
        XCTAssertEqual(StubURLProtocol.capturedRequests.first?.url?.path, "/models")
    }
}
