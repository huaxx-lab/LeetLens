import Foundation
import XCTest
@testable import LeetCodeAssistant

/// Provider URL rules must match `src/integrations/provider-settings.js`, because both
/// clients read and write the same `settings.json`.
final class ProviderURLPolicyTests: XCTestCase {
    // MARK: - Rejections

    func testRemoteHTTPIsRejected() {
        XCTAssertThrowsError(try ProviderURLPolicy.normalize("http://api.example.com/v1")) { error in
            XCTAssertEqual(error as? ProviderURLPolicy.Failure, .insecureRemote)
        }
    }

    func testLoopbackHTTPIsAllowed() throws {
        for base in ["http://localhost:1234/v1", "http://127.0.0.1:8080/v1", "http://[::1]:9000/v1"] {
            let normalized = try ProviderURLPolicy.normalize(base)
            XCTAssertFalse(normalized.apiBase.isEmpty, "Loopback base rejected: \(base)")
        }
    }

    func testEmbeddedCredentialsAreRejected() {
        XCTAssertThrowsError(try ProviderURLPolicy.normalize("https://user:pass@api.example.com/v1")) { error in
            XCTAssertEqual(error as? ProviderURLPolicy.Failure, .embeddedCredentials)
        }
    }

    func testQueryOrFragmentIsRejected() {
        XCTAssertThrowsError(try ProviderURLPolicy.normalize("https://api.example.com/v1?key=leak")) { error in
            XCTAssertEqual(error as? ProviderURLPolicy.Failure, .queryOrFragment)
        }
        XCTAssertThrowsError(try ProviderURLPolicy.normalize("https://api.example.com/v1#frag")) { error in
            XCTAssertEqual(error as? ProviderURLPolicy.Failure, .queryOrFragment)
        }
    }

    func testNonHTTPSchemesAreRejected() {
        XCTAssertThrowsError(try ProviderURLPolicy.normalize("ftp://api.example.com/v1")) { error in
            XCTAssertEqual(error as? ProviderURLPolicy.Failure, .unsupportedScheme)
        }
        XCTAssertThrowsError(try ProviderURLPolicy.normalize("file:///etc/passwd"))
        XCTAssertThrowsError(try ProviderURLPolicy.normalize(""))
        XCTAssertThrowsError(try ProviderURLPolicy.normalize("not a url"))
    }

    // MARK: - Normalisation

    func testPastedGenerationEndpointsCollapseToTheAPIRoot() throws {
        let chat = try ProviderURLPolicy.normalize("https://api.example.com/v1/chat/completions")
        XCTAssertEqual(chat.apiBase, "https://api.example.com/v1")
        XCTAssertEqual(chat.endpointHint, "chat")

        let responses = try ProviderURLPolicy.normalize("https://api.example.com/v1/responses")
        XCTAssertEqual(responses.apiBase, "https://api.example.com/v1")
        XCTAssertEqual(responses.endpointHint, "responses")

        let messages = try ProviderURLPolicy.normalize("https://api.anthropic.com/v1/messages")
        XCTAssertEqual(messages.apiBase, "https://api.anthropic.com/v1")
        XCTAssertEqual(messages.endpointHint, "messages")
    }

    func testTrailingAndDuplicateSlashesAreCollapsed() throws {
        let normalized = try ProviderURLPolicy.normalize("  https://api.example.com//v1///  ")
        XCTAssertEqual(normalized.apiBase, "https://api.example.com/v1")
        XCTAssertEqual(normalized.endpointHint, "")
    }

    /// Provider-specific roots must survive; nobody may be forced onto `/v1`.
    func testProviderSpecificPathsArePreserved() throws {
        let normalized = try ProviderURLPolicy.normalize(
            "https://dashscope.aliyuncs.com/compatible-mode/v1"
        )
        XCTAssertEqual(normalized.apiBase, "https://dashscope.aliyuncs.com/compatible-mode/v1")
    }

    // MARK: - Endpoint containment

    func testEndpointsStayInsideTheBase() throws {
        let chat = try ProviderURLPolicy.endpoint(base: "https://api.example.com/v1", mode: "chat")
        XCTAssertEqual(chat.absoluteString, "https://api.example.com/v1/chat/completions")

        let messages = try ProviderURLPolicy.endpoint(base: "https://api.anthropic.com/v1", mode: "messages")
        XCTAssertEqual(messages.absoluteString, "https://api.anthropic.com/v1/messages")
    }

    /// Request time is the second half of the double check: a hand-edited settings.json
    /// must not be able to put an API key on a plaintext connection.
    func testRequestTimeRejectsRemoteHTTPEvenIfPersisted() {
        XCTAssertThrowsError(try ProviderURLPolicy.endpoint(base: "http://evil.example.com/v1", mode: "chat"))
        XCTAssertThrowsError(
            try ProviderURLPolicy.endpoint(base: "https://user:pass@api.example.com/v1", mode: "chat")
        )
        XCTAssertThrowsError(try ProviderURLPolicy.modelEndpoints(base: "http://evil.example.com/v1"))
        XCTAssertThrowsError(try ProviderURLPolicy.modelEndpoints(base: "https://u:p@api.example.com/v1"))
        XCTAssertThrowsError(try ProviderURLPolicy.modelEndpoints(base: "https://api.example.com/v1?key=leak"))
    }

    func testModelEndpointsPreserveValidatedProviderRoots() throws {
        XCTAssertEqual(
            try ProviderURLPolicy.modelEndpoints(base: "https://api.example.com/v1").map(\.absoluteString),
            ["https://api.example.com/v1/models"]
        )
        XCTAssertEqual(
            try ProviderURLPolicy.modelEndpoints(
                base: "https://dashscope.aliyuncs.com/compatible-mode/v1/chat/completions"
            ).map(\.absoluteString),
            ["https://dashscope.aliyuncs.com/compatible-mode/v1/models"]
        )
        XCTAssertEqual(
            try ProviderURLPolicy.modelEndpoints(base: "https://api.example.com").map(\.absoluteString),
            ["https://api.example.com/models", "https://api.example.com/v1/models"]
        )
    }

    // MARK: - Credential markers

    func testCredentialMarkersAreNeverTreatedAsKeys() {
        XCTAssertTrue(ChatService.isCredentialMarker("keychain:v1:openai"))
        XCTAssertTrue(ChatService.isCredentialMarker("safe-storage:v1:AAAA"))
        XCTAssertFalse(ChatService.isCredentialMarker("sk-realkey123"))
        XCTAssertFalse(ChatService.isCredentialMarker(""))
    }

    // MARK: - Save path

    @MainActor
    func testSaveProviderNormalizesAndRejectsUnsafeBases() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "ProviderSave-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let settings: [String: Any] = [
            "providerOrder": ["p1"],
            "activeProvider": "p1",
            "providers": ["p1": ["name": "测试", "apiBase": "https://api.example.com/v1", "apiKey": "", "model": "m"]]
        ]
        try JSONSerialization.data(withJSONObject: settings)
            .write(to: directory.appending(path: "settings.json"), options: .atomic)

        let store = LegacyDataStore(dataDirectory: directory)
        await store.hydrate()

        // A pasted endpoint is normalised back to its root and reveals the mode.
        try store.saveProvider(
            id: "p1",
            apiBase: "https://api.example.com/v1/chat/completions",
            apiKey: "",
            model: "gpt-x",
            mode: "auto"
        )
        let saved = try XCTUnwrap(store.providers.first { $0.id == "p1" })
        XCTAssertEqual(saved.apiBase, "https://api.example.com/v1")

        // Unsafe bases must not reach disk at all.
        XCTAssertThrowsError(try store.saveProvider(
            id: "p1", apiBase: "http://remote.example.com/v1", apiKey: "", model: "m", mode: "auto"
        ))
        XCTAssertThrowsError(try store.saveProvider(
            id: "p1", apiBase: "https://u:p@api.example.com/v1", apiKey: "", model: "m", mode: "auto"
        ))
        let unchanged = try XCTUnwrap(store.providers.first { $0.id == "p1" })
        XCTAssertEqual(unchanged.apiBase, "https://api.example.com/v1")
    }
}
