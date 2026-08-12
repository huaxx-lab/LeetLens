import Foundation
import XCTest
@testable import LeetCodeAssistant

final class SubprocessRunnerTests: XCTestCase {
    func testSimultaneouslyDrainsLargeStandardOutputAndError() async throws {
        let script = """
        awk 'BEGIN { for (i = 0; i < 3000; i++) print "stdout-0123456789012345678901234567890123456789" }'
        awk 'BEGIN { for (i = 0; i < 3000; i++) print "stderr-0123456789012345678901234567890123456789" }' >&2
        """

        let result = try await SubprocessRunner.run(
            executableURL: URL(filePath: "/bin/sh"),
            arguments: ["-c", script],
            timeout: 5
        )

        XCTAssertEqual(result.terminationStatus, 0)
        XCTAssertGreaterThan(result.standardOutput.count, 100_000)
        XCTAssertGreaterThan(result.standardError.count, 100_000)
    }

    func testTimeoutWinsTerminationRace() async throws {
        let startedAt = Date.now
        do {
            _ = try await SubprocessRunner.run(
                executableURL: URL(filePath: "/bin/sh"),
                arguments: ["-c", "trap '' TERM; sleep 5"],
                timeout: 0.1
            )
            XCTFail("Expected the process to time out")
        } catch let error as SubprocessRunnerError {
            guard case .timedOut = error else {
                return XCTFail("Unexpected process error: \(error)")
            }
        }
        XCTAssertLessThan(Date.now.timeIntervalSince(startedAt), 2)
    }

    /// The audited hang: cancelling before the continuation is installed used to mark
    /// the execution finished with nobody to resume, so the caller waited forever.
    func testCancellationBeforeStartResumesInsteadOfHanging() async throws {
        let task = Task {
            try await SubprocessRunner.run(
                executableURL: URL(filePath: "/bin/sleep"),
                arguments: ["30"],
                timeout: 30
            )
        }
        task.cancel()

        let outcome = await withTimeout(seconds: 5) { await task.result }
        let result = try XCTUnwrap(outcome, "Cancelled run never resumed its continuation")
        switch result {
        case .success:
            XCTFail("Expected cancellation, not a completed process")
        case .failure(let error):
            XCTAssertTrue(error is CancellationError, "Unexpected error: \(error)")
        }
    }

    /// Cancelling immediately after start must also resume promptly.
    func testImmediateCancellationResumesPromptly() async throws {
        let startedAt = Date.now
        let task = Task {
            try await SubprocessRunner.run(
                executableURL: URL(filePath: "/bin/sleep"),
                arguments: ["30"],
                timeout: 30
            )
        }
        try await Task.sleep(for: .milliseconds(50))
        task.cancel()

        let outcome = await withTimeout(seconds: 5) { await task.result }
        XCTAssertNotNil(outcome, "Cancelled run never resumed its continuation")
        XCTAssertLessThan(Date.now.timeIntervalSince(startedAt), 5)
    }

    /// Cancellation must escalate to SIGKILL exactly like the timeout path, otherwise
    /// a child that ignores SIGTERM outlives the request that spawned it.
    func testCancellationKillsChildThatIgnoresTermination() async throws {
        let markerURL = FileManager.default.temporaryDirectory
            .appending(path: "term-ignore-\(UUID().uuidString).pid")
        defer { try? FileManager.default.removeItem(at: markerURL) }

        let script = "trap '' TERM; echo $$ > \(markerURL.path); sleep 30"
        let task = Task {
            try await SubprocessRunner.run(
                executableURL: URL(filePath: "/bin/sh"),
                arguments: ["-c", script],
                timeout: 30
            )
        }

        // Wait for the child to record its PID so we know it actually launched.
        var childPID: pid_t?
        for _ in 0..<100 {
            if let text = try? String(contentsOf: markerURL, encoding: .utf8),
               let pid = pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines)) {
                childPID = pid
                break
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        let pid = try XCTUnwrap(childPID, "Child never started")

        task.cancel()
        _ = await task.result

        // SIGTERM is trapped, so only the SIGKILL escalation can reap this child.
        var isAlive = true
        for _ in 0..<40 {
            if Darwin.kill(pid, 0) != 0 {
                isAlive = false
                break
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertFalse(isAlive, "Child ignoring SIGTERM survived cancellation (pid \(pid))")
    }

    /// Bounds an awaited value so a regression fails the test instead of hanging it.
    private func withTimeout<Value: Sendable>(
        seconds: TimeInterval,
        _ body: @escaping @Sendable () async -> Value
    ) async -> Value? {
        await withTaskGroup(of: Value?.self) { group in
            group.addTask { await body() }
            group.addTask {
                try? await Task.sleep(for: .seconds(seconds))
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }
}
