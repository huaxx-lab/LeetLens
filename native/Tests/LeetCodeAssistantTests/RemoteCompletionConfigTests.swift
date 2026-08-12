import Foundation
import XCTest
@testable import LeetCodeAssistant

/// Configuration for the remote completion tunnel.
///
/// The service read its SSH settings from environment variables only. A GUI app
/// launched from Finder or the Dock inherits none of a shell's exports, so `host` was
/// always empty and completion reported itself unconfigured regardless of the server
/// being healthy. A config file makes it reachable the way the app is actually started.
final class RemoteCompletionConfigTests: XCTestCase {
    private func writeConfig(_ payload: [String: Any]) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "LSPConfig-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: payload)
            .write(to: directory.appending(path: "lsp.json"), options: .atomic)
        return directory
    }

    func testEmptyEnvironmentWithoutFileStaysUnconfigured() {
        let configuration = RemoteCompletionConfiguration(
            environment: [:],
            dataDirectory: FileManager.default.temporaryDirectory
                .appending(path: "missing-\(UUID().uuidString)", directoryHint: .isDirectory)
        )
        XCTAssertFalse(configuration.isConfigured)
    }

    /// The regression: a GUI launch has no environment, so the file must configure it.
    func testFileConfiguresServiceWhenEnvironmentIsEmpty() throws {
        let directory = try writeConfig([
            "host": "203.0.113.10",
            "user": "root",
            "sshPort": 22,
            "targetPort": 9092,
            "identityFile": "/Users/someone/.ssh/id_ed25519"
        ])
        defer { try? FileManager.default.removeItem(at: directory) }

        let configuration = RemoteCompletionConfiguration(environment: [:], dataDirectory: directory)
        XCTAssertTrue(configuration.isConfigured, "File did not configure the service")
        XCTAssertEqual(configuration.host, "203.0.113.10")
        XCTAssertEqual(configuration.user, "root")
        XCTAssertEqual(configuration.sshPort, 22)
        XCTAssertEqual(configuration.targetPort, 9092)
        XCTAssertEqual(configuration.identityFile, "/Users/someone/.ssh/id_ed25519")
    }

    /// `~/.ssh/id_ed25519` is how people write it; dropping it would silently fall back
    /// to agent-only auth and fail on a machine without an agent.
    func testTildeIdentityPathIsExpanded() throws {
        let directory = try writeConfig(["host": "example.com", "identityFile": "~/.ssh/id_ed25519"])
        defer { try? FileManager.default.removeItem(at: directory) }

        let configuration = RemoteCompletionConfiguration(environment: [:], dataDirectory: directory)
        let identity = try XCTUnwrap(configuration.identityFile)
        XCTAssertTrue(identity.hasPrefix("/"), "Tilde path was not expanded: \(identity)")
        XCTAssertTrue(identity.hasSuffix("/.ssh/id_ed25519"))
    }

    func testEnvironmentOverridesFile() throws {
        let directory = try writeConfig(["host": "from-file.example", "user": "root"])
        defer { try? FileManager.default.removeItem(at: directory) }

        let configuration = RemoteCompletionConfiguration(
            environment: ["LEETCODE_LSP_SSH_HOST": "from-env.example"],
            dataDirectory: directory
        )
        XCTAssertEqual(configuration.host, "from-env.example", "Environment must win over the file")
    }

    func testDisabledFlagKeepsServiceOff() throws {
        let directory = try writeConfig(["enabled": false, "host": "203.0.113.10"])
        defer { try? FileManager.default.removeItem(at: directory) }

        let configuration = RemoteCompletionConfiguration(environment: [:], dataDirectory: directory)
        XCTAssertFalse(configuration.isConfigured)
    }

    func testMalformedHostIsRejected() throws {
        let directory = try writeConfig(["host": "not a host; rm -rf /"])
        defer { try? FileManager.default.removeItem(at: directory) }

        let configuration = RemoteCompletionConfiguration(environment: [:], dataDirectory: directory)
        XCTAssertFalse(configuration.isConfigured, "Malformed host must not configure a tunnel")
    }

    func testInvalidPortsFallBackToDefaults() throws {
        let directory = try writeConfig(["host": "example.com", "sshPort": 0, "targetPort": 999_999])
        defer { try? FileManager.default.removeItem(at: directory) }

        let configuration = RemoteCompletionConfiguration(environment: [:], dataDirectory: directory)
        XCTAssertEqual(configuration.sshPort, 22)
        XCTAssertEqual(configuration.targetPort, 9092)
    }

    // MARK: - Live server (opt-in)

    /// Drives the real service end to end: SSH tunnel, POST /complete, decode.
    /// Skipped unless a real `lsp.json` exists in the app's data directory.
    func testLiveCompletionThroughTunnel() async throws {
        let configuration = RemoteCompletionConfiguration()
        guard configuration.isConfigured else {
            throw XCTSkip("No lsp.json configured; skipping live completion check")
        }
        let service = RemoteCodeCompletionService(configuration: configuration)
        let response = try await service.complete(
            code: "class Solution {\n  void f() {\n    java.util.Ma\n  }\n}",
            line: 2,
            character: 16,
            language: "java"
        )
        XCTAssertFalse(response.engine.isEmpty)
        XCTAssertFalse(response.items.isEmpty, "Live LSP returned no completions")
        XCTAssertTrue(
            response.items.contains { $0.insertText.contains("Map") },
            "Expected java.util.Map among: \(response.items.map(\.label))"
        )
    }
}
