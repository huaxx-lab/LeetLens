import Foundation
import XCTest
@testable import LeetCodeAssistant

final class LeetCodeCorrectnessTests: XCTestCase {
    func testAnalysisRetryBudgetConsumesFailuresAndStopsAutomaticWork() {
        var failures: [String: Int] = [:]
        for _ in 0..<LeetCodeAnalysisRetryBudget.submissionAttempts {
            failures = LeetCodeAnalysisRetryBudget.recordFailures(["submission-1"], current: failures)
        }
        XCTAssertEqual(failures["submission-1"], LeetCodeAnalysisRetryBudget.submissionAttempts)
        XCTAssertEqual(
            LeetCodeAnalysisRetryBudget.eligible(["submission-1", "submission-2"], failures: failures),
            ["submission-2"]
        )

        let task = LeetCodeAnalysisTask(
            titleSlug: "two-sum",
            submissionIDs: ["submission-1"],
            queuedAt: .distantPast,
            attempts: LeetCodeAnalysisRetryBudget.taskAttempts,
            nextAttemptAt: .distantPast,
            lastAttemptAt: .now,
            lastError: "failed",
            failedSubmissionAttempts: failures
        )
        XCTAssertFalse(task.isReady)
        XCTAssertTrue(task.eligibleSubmissionIDs.isEmpty)
    }

    func testAPIErrorExposesStructuredHTTPStatusCode() {
        let error = LeetCodeAPIError.invalidResponse("not found", statusCode: 404)

        XCTAssertEqual(error.statusCode, 404)
        XCTAssertEqual(error.errorDescription, "not found")
    }

    func testAcceptedStatusUsesExactJudgeStatesInsteadOfSubstringMatches() {
        XCTAssertTrue(LeetCodeStatus.isAccepted(statusCode: 10, display: "Wrong Answer"))
        XCTAssertTrue(LeetCodeStatus.isAccepted(statusCode: 0, display: "Accepted"))
        XCTAssertTrue(LeetCodeStatus.isAccepted(statusCode: 0, display: "通过"))
        XCTAssertFalse(LeetCodeStatus.isAccepted(statusCode: 0, display: "Not Accepted"))
        XCTAssertFalse(LeetCodeStatus.isAccepted(statusCode: 0, display: "通过部分测试"))
    }

    func testV2PollingFallsBackOnlyForStructured404() {
        XCTAssertTrue(LeetCodeJudgePolling.shouldFallbackFromV2(
            LeetCodeAPIError.invalidResponse("missing", statusCode: 404)
        ))
        XCTAssertFalse(LeetCodeJudgePolling.shouldFallbackFromV2(
            LeetCodeAPIError.invalidResponse("upstream mentions 404", statusCode: 500)
        ))
        XCTAssertFalse(LeetCodeJudgePolling.shouldFallbackFromV2(
            URLError(.timedOut)
        ))
    }

    func testFirstHistoryFingerprintEstablishesBaselineWithoutQueueingAI() {
        let history = [remoteSubmission(id: "1"), remoteSubmission(id: "2")]
        let fingerprint = LeetCodeSubmissionFingerprint.make(history)

        XCTAssertTrue(LeetCodeSubmissionFingerprint.analysisCandidateIDs(
            incoming: history,
            knownIDs: [],
            analyzedIDs: [],
            previousFingerprint: nil,
            expectedSubmissionID: nil,
            onDemand: true
        ).isEmpty)

        let updated = history + [remoteSubmission(id: "3")]
        XCTAssertEqual(LeetCodeSubmissionFingerprint.analysisCandidateIDs(
            incoming: updated,
            knownIDs: ["1", "2"],
            analyzedIDs: [],
            previousFingerprint: fingerprint,
            expectedSubmissionID: nil,
            onDemand: true
        ), ["3"])
    }

    func testCodeEditorNormalizesSupportedLeetCodeLanguages() {
        XCTAssertEqual(LeetCodeEditorLanguage.normalized("java"), "java")
        XCTAssertEqual(LeetCodeEditorLanguage.normalized("C++"), "cpp")
        XCTAssertEqual(LeetCodeEditorLanguage.normalized("python3"), "python3")
        XCTAssertEqual(LeetCodeEditorLanguage.normalized("js"), "javascript")
        XCTAssertEqual(LeetCodeEditorLanguage.normalized("unsupported"), "java")
    }

    func testCodeEditorDiagnosticsExposeConciseStatusAndOneBasedLines() {
        XCTAssertEqual(LeetCodeEditorDiagnostics().statusText, "基础语法检查通过")
        let diagnostics = LeetCodeEditorDiagnostics(issues: [
            LeetCodeEditorIssue(line: 3, message: "括号未闭合")
        ])
        XCTAssertEqual(diagnostics.statusText, "发现 1 处基础语法问题")
        XCTAssertEqual(diagnostics.issues.first?.line, 3)
    }

    func testOfficialExamplesRemainIndividuallyEditableAndSelectable() {
        let official = ["[2,7,11,15]\n9", "[3,2,4]\n6", "[3,3]\n6"]
        XCTAssertEqual(LeetCodeTestCaseWorkspace.editableCases(from: official), official)
        XCTAssertEqual(LeetCodeTestCaseWorkspace.editableCases(from: []), [""])
        XCTAssertEqual(LeetCodeTestCaseWorkspace.clampedIndex(9, caseCount: official.count), 2)
        XCTAssertEqual(LeetCodeTestCaseWorkspace.clampedIndex(-2, caseCount: official.count), 0)
    }

    func testBottomPanelHeightPreservesEditorAndClampsDragRange() {
        XCTAssertEqual(
            LeetCodeBottomPanelLayout.clampedHeight(20, availableHeight: 800),
            LeetCodeBottomPanelLayout.minimumHeight
        )
        XCTAssertEqual(
            LeetCodeBottomPanelLayout.clampedHeight(900, availableHeight: 800),
            LeetCodeBottomPanelLayout.maximumHeight
        )
        XCTAssertEqual(
            LeetCodeBottomPanelLayout.clampedHeight(900, availableHeight: 480),
            208
        )
    }

    func testRemoteCompletionConfigurationValidatesSSHBoundary() {
        let configured = RemoteCompletionConfiguration(environment: [
            "LEETCODE_LSP_SSH_HOST": "lsp.example.com",
            "LEETCODE_LSP_SSH_USER": "leetcode-lsp",
            "LEETCODE_LSP_SSH_PORT": "2222",
            "LEETCODE_LSP_TARGET_PORT": "9092",
            "LEETCODE_LSP_SSH_IDENTITY_FILE": "/tmp/id_lsp"
        ])
        XCTAssertTrue(configured.isConfigured)
        XCTAssertEqual(configured.sshPort, 2_222)
        XCTAssertEqual(configured.targetPort, 9_092)
        XCTAssertEqual(configured.identityFile, "/tmp/id_lsp")

        let rejected = RemoteCompletionConfiguration(environment: [
            "LEETCODE_LSP_SSH_HOST": "bad host; command",
            "LEETCODE_LSP_SSH_PORT": "99999",
            "LEETCODE_LSP_SSH_IDENTITY_FILE": "relative-key"
        ])
        XCTAssertFalse(rejected.isConfigured)
        XCTAssertEqual(rejected.sshPort, 22)
        XCTAssertNil(rejected.identityFile)
    }

    func testSiteSessionRecognitionRequiresCompleteCookiePair() {
        XCTAssertTrue(WebsiteSessionSite.leetcode.isAuthenticated(cookieNames: ["LEETCODE_SESSION", "csrftoken"]))
        XCTAssertFalse(WebsiteSessionSite.leetcode.isAuthenticated(cookieNames: ["LEETCODE_SESSION"]))
        XCTAssertTrue(WebsiteSessionSite.bilibili.isAuthenticated(cookieNames: ["SESSDATA", "DedeUserID"]))
        XCTAssertFalse(WebsiteSessionSite.bilibili.isAuthenticated(cookieNames: ["SESSDATA"]))
    }

    @MainActor
    func testBrowserShutdownScriptPausesAndClearsMediaSources() {
        XCTAssertTrue(BrowserMediaLifecycle.shutdownScript.contains("media.pause()"))
        XCTAssertTrue(BrowserMediaLifecycle.shutdownScript.contains("removeAttribute('src')"))
        XCTAssertTrue(BrowserMediaLifecycle.shutdownScript.contains("media.load()"))
    }

    private func remoteSubmission(id: String) -> LeetCodeRemoteSubmission {
        LeetCodeRemoteSubmission(
            id: id,
            status: "Accepted",
            language: "swift",
            timestamp: TimeInterval(Int(id) ?? 0),
            title: "Two Sum",
            runtime: "1 ms",
            memory: "10 MB",
            url: "/submissions/detail/\(id)/"
        )
    }
}
