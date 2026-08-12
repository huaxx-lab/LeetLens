import Foundation
import XCTest
@testable import LeetCodeAssistant

/// Content fingerprints for the analysis cache.
///
/// Deduplication used to be a plain ID set, so a corrected detail or a changed solution
/// could not invalidate anything and a re-queued batch re-sent work already paid for.
final class AnalysisCacheTests: XCTestCase {
    private func detail(
        id: String = "1",
        code: String = "class Solution {}",
        status: String = "Accepted",
        language: String = "swift",
        runtimeError: String = "",
        totalCorrect: Int = 10
    ) -> LeetCodeSubmissionDetail {
        LeetCodeSubmissionDetail(
            id: id,
            titleSlug: "two-sum",
            code: code,
            language: language,
            status: status,
            runtime: "1 ms",
            memory: "10 MB",
            runtimePercentile: nil,
            memoryPercentile: nil,
            runtimeError: runtimeError,
            compileError: "",
            lastTestCase: "",
            actualOutput: "",
            expectedOutput: "",
            correctCaseCount: totalCorrect,
            totalCaseCount: 10
        )
    }

    // MARK: - Item fingerprints

    func testIdenticalContentProducesIdenticalFingerprint() {
        XCTAssertEqual(
            LeetCodeAnalysisFingerprint.itemFingerprint(detail()),
            LeetCodeAnalysisFingerprint.itemFingerprint(detail())
        )
    }

    /// The gap the audit called out: same ID, different code must not be treated as
    /// already analysed.
    func testChangedCodeChangesFingerprintDespiteSameID() {
        XCTAssertNotEqual(
            LeetCodeAnalysisFingerprint.itemFingerprint(detail(code: "class A {}")),
            LeetCodeAnalysisFingerprint.itemFingerprint(detail(code: "class B {}"))
        )
    }

    /// A corrected detail body must invalidate the previous analysis.
    func testCorrectedDetailChangesFingerprint() {
        XCTAssertNotEqual(
            LeetCodeAnalysisFingerprint.detailHash(detail(runtimeError: "")),
            LeetCodeAnalysisFingerprint.detailHash(detail(runtimeError: "index out of range"))
        )
        XCTAssertNotEqual(
            LeetCodeAnalysisFingerprint.itemFingerprint(detail(totalCorrect: 10)),
            LeetCodeAnalysisFingerprint.itemFingerprint(detail(totalCorrect: 3))
        )
    }

    func testStatusAndLanguageParticipateInIdentity() {
        XCTAssertNotEqual(
            LeetCodeAnalysisFingerprint.itemFingerprint(detail(status: "Accepted")),
            LeetCodeAnalysisFingerprint.itemFingerprint(detail(status: "Wrong Answer"))
        )
        XCTAssertNotEqual(
            LeetCodeAnalysisFingerprint.itemFingerprint(detail(language: "swift")),
            LeetCodeAnalysisFingerprint.itemFingerprint(detail(language: "java"))
        )
    }

    // MARK: - Analysis fingerprints

    func testAnalysisFingerprintIsOrderIndependent() {
        let a = detail(id: "1", code: "A")
        let b = detail(id: "2", code: "B")
        XCTAssertEqual(
            LeetCodeAnalysisFingerprint.analysisFingerprint(details: [a, b], modelProfile: "p|m"),
            LeetCodeAnalysisFingerprint.analysisFingerprint(details: [b, a], modelProfile: "p|m"),
            "Batch ordering must not fragment the cache"
        )
    }

    /// Switching model or provider must re-analyse rather than reuse another model's answer.
    func testModelProfileParticipatesInIdentity() {
        let batch = [detail()]
        XCTAssertNotEqual(
            LeetCodeAnalysisFingerprint.analysisFingerprint(details: batch, modelProfile: "openai|gpt-x"),
            LeetCodeAnalysisFingerprint.analysisFingerprint(details: batch, modelProfile: "deepseek|ds-x")
        )
    }

    func testAddingASubmissionChangesTheAnalysisFingerprint() {
        let first = [detail(id: "1")]
        let second = [detail(id: "1"), detail(id: "2", code: "other")]
        XCTAssertNotEqual(
            LeetCodeAnalysisFingerprint.analysisFingerprint(details: first, modelProfile: "p|m"),
            LeetCodeAnalysisFingerprint.analysisFingerprint(details: second, modelProfile: "p|m")
        )
    }

    // MARK: - Keys

    func testKeysCarryAVersionPrefixSoUpgradesInvalidateWholesale() {
        let version = LeetCodeAnalysisFingerprint.keyVersion
        XCTAssertTrue(
            LeetCodeAnalysisFingerprint.analysisKey(slug: "two-sum", fingerprint: "abc")
                .contains(":v\(version):")
        )
        XCTAssertTrue(
            LeetCodeAnalysisFingerprint.analyzedKey(slug: "two-sum", itemFingerprint: "abc")
                .contains(":v\(version):")
        )
        XCTAssertTrue(
            LeetCodeAnalysisFingerprint.detailKey(submissionID: "1").contains(":v\(version):")
        )
        XCTAssertTrue(
            LeetCodeAnalysisFingerprint.detailLockKey(submissionID: "1").contains(":v\(version):")
        )
    }

    func testDistinctSlugsAndSubmissionsDoNotCollide() {
        XCTAssertNotEqual(
            LeetCodeAnalysisFingerprint.analysisKey(slug: "two-sum", fingerprint: "abc"),
            LeetCodeAnalysisFingerprint.analysisKey(slug: "three-sum", fingerprint: "abc")
        )
        XCTAssertNotEqual(
            LeetCodeAnalysisFingerprint.detailKey(submissionID: "1"),
            LeetCodeAnalysisFingerprint.detailKey(submissionID: "2")
        )
    }

    // MARK: - Live Redis (opt-in)

    /// Exercises the real cache round trip, including the in-flight lock.
    func testLiveRedisCacheRoundTripAndLock() async throws {
        guard let configuration = RedisConfiguration.resolve() else {
            throw XCTSkip("Set LEETCODE_REDIS_HOST/PASSWORD to exercise the cache")
        }
        let client = RedisClient(configuration: configuration)
        let key = "selftest:v1:\(UUID().uuidString)"

        await client.setValue(Data("payload".utf8), for: key, ttl: 60)
        let loaded = await client.get(key)
        XCTAssertEqual(loaded.map { String(decoding: $0, as: UTF8.self) }, "payload")
        let existed = await client.exists(key)
        XCTAssertTrue(existed)

        // SET NX must hand the lock to exactly one caller.
        let lockKey = "selftest:lock:\(UUID().uuidString)"
        let first = await client.acquireLock(lockKey, ttl: 30)
        let second = await client.acquireLock(lockKey, ttl: 30)
        XCTAssertTrue(first, "First caller must win the lock")
        XCTAssertFalse(second, "Second caller must not also win the lock")
        await client.releaseLock(lockKey)
        let reacquired = await client.acquireLock(lockKey, ttl: 5)
        XCTAssertTrue(reacquired, "Lock must be reusable once released")
        await client.releaseLock(lockKey)

        // Counters accumulate rather than rewrite.
        let counterKey = "selftest:usage:\(UUID().uuidString)"
        await client.incrementCounters([
            (key: counterKey, field: "total_tokens", by: 100),
            (key: counterKey, field: "requests", by: 1)
        ], ttl: 120)
        await client.incrementCounters([
            (key: counterKey, field: "total_tokens", by: 50),
            (key: counterKey, field: "requests", by: 1)
        ], ttl: 120)
        let counters = await client.counters(counterKey)
        XCTAssertEqual(counters["total_tokens"], 150)
        XCTAssertEqual(counters["requests"], 2)

        await client.releaseLock(key)
        await client.releaseLock(counterKey)
    }

    /// An unreachable Redis must fail fast and stay invisible.
    func testUnreachableRedisDegradesSilently() async {
        let client = RedisClient(configuration: RedisConfiguration(
            host: "127.0.0.1",
            port: 6, // reserved; nothing listens here
            password: nil,
            keyPrefix: "lca-test:",
            timeout: 1
        ))
        let startedAt = Date.now
        let value = await client.get("anything")

        XCTAssertNil(value)
        XCTAssertLessThan(
            Date.now.timeIntervalSince(startedAt),
            5,
            "An unreachable cache must not stall the caller"
        )
        // Breaker is now open, so the next call must return immediately.
        let breakerStart = Date.now
        _ = await client.get("anything")
        XCTAssertLessThan(Date.now.timeIntervalSince(breakerStart), 0.5, "Circuit breaker did not open")
    }
}
