import Foundation
import XCTest
@testable import LeetCodeAssistant

/// Cancelling the analysis worker must be a no-op, not a failure.
///
/// The worker used to live on the LeetCode page's `.task`, so navigating away cancelled
/// it. The generic `catch` then counted that cancellation against the task's retry
/// budget and against every submission in the batch; once a submission exhausted its
/// budget it was filtered out, and an emptied queue entry was deleted entirely.
final class AnalysisCancellationTests: XCTestCase {
    private func makeFixture(in directory: URL, slug: String = "two-sum") throws {
        let now = Date.now.timeIntervalSince1970 * 1_000
        let fixture: [String: Any] = [
            "account": ["signedIn": true, "username": "coder"],
            "submissions": [
                [
                    "id": "1", "title": "Two Sum", "titleSlug": slug,
                    "statusDisplay": "Wrong Answer", "lang": "swift",
                    "submittedAt": now - 60_000
                ],
                [
                    "id": "2", "title": "Two Sum", "titleSlug": slug,
                    "statusDisplay": "Accepted", "lang": "swift",
                    "submittedAt": now - 30_000
                ]
            ],
            "analysis": [
                "queue": [
                    slug: [
                        "submissionIds": ["1", "2"],
                        "queuedAt": now - 120_000,
                        "attempts": 0,
                        "nextAttemptAt": now - 120_000,
                        "failedSubmissionAttempts": [:]
                    ]
                ],
                "records": [:]
            ]
        ]
        try JSONSerialization.data(withJSONObject: fixture)
            .write(to: directory.appending(path: "leetcode-cn.json"), options: .atomic)
    }

    /// The invariant the audit asks for: attempts, the failed map, the eligible IDs and
    /// the queue must all be untouched after a cancelled pass.
    @MainActor
    func testCancelledAnalysisLeavesQueueByteForByteUnchanged() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "AnalysisCancel-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try makeFixture(in: directory)

        let fileURL = directory.appending(path: "leetcode-cn.json")
        let before = try Data(contentsOf: fileURL)

        let store = LegacyDataStore(dataDirectory: directory)
        await store.hydrate()
        XCTAssertEqual(store.leetCodeAnalysisTasks.count, 1, "Fixture did not load a queued task")

        // Run the worker inside an already-cancelled task, exactly as navigating away does.
        let worker = Task { @MainActor in
            await store.processNextLeetCodeAnalysis()
        }
        worker.cancel()
        let processed = await worker.value

        XCTAssertFalse(processed, "A cancelled pass must not report progress")
        let after = try Data(contentsOf: fileURL)
        XCTAssertEqual(after, before, "Cancellation mutated the analysis queue on disk")

        // And the in-memory view of the queue must be intact too.
        let reopened = LegacyDataStore(dataDirectory: directory)
        await reopened.hydrate()
        let task = try XCTUnwrap(reopened.leetCodeAnalysisTasks["two-sum"])
        XCTAssertEqual(task.attempts, 0, "Cancellation burned a retry attempt")
        XCTAssertEqual(task.submissionIDs.sorted(), ["1", "2"], "Cancellation dropped submission IDs")
        XCTAssertTrue(task.isReady, "Cancellation pushed the task out of its retry window")
    }

    /// Repeated cancellation must never exhaust the budget and delete the task.
    @MainActor
    func testRepeatedCancellationNeverDeletesTheQueuedTask() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "AnalysisCancelLoop-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try makeFixture(in: directory)

        let store = LegacyDataStore(dataDirectory: directory)
        await store.hydrate()

        // More rounds than the retry budget allows, so a regression deletes the task.
        for _ in 0..<(LeetCodeAnalysisRetryBudget.taskAttempts + 3) {
            let worker = Task { @MainActor in await store.processNextLeetCodeAnalysis() }
            worker.cancel()
            _ = await worker.value
        }

        let reopened = LegacyDataStore(dataDirectory: directory)
        await reopened.hydrate()
        let task = try XCTUnwrap(
            reopened.leetCodeAnalysisTasks["two-sum"],
            "Repeated cancellation deleted the queued analysis task"
        )
        XCTAssertEqual(task.attempts, 0)
        XCTAssertEqual(task.submissionIDs.sorted(), ["1", "2"])
    }

    // MARK: - Classification

    func testCancellationIsRecognisedInBothSpellings() {
        XCTAssertTrue(LegacyDataStore.isCancellation(CancellationError()))
        // URLSession reports task cancellation as URLError, not CancellationError.
        XCTAssertTrue(LegacyDataStore.isCancellation(URLError(.cancelled)))
    }

    func testRealFailuresAreStillTreatedAsFailures() {
        XCTAssertFalse(LegacyDataStore.isCancellation(URLError(.timedOut)))
        XCTAssertFalse(LegacyDataStore.isCancellation(URLError(.notConnectedToInternet)))
        XCTAssertFalse(LegacyDataStore.isCancellation(LeetCodeAPIError.invalidResponse("boom")))
    }
}
