import Foundation
import XCTest
@testable import LeetCodeAssistant

final class ForgettingCurveTests: XCTestCase {
    func testCurveMatchesTheSchedulerItSharesTheDataWith() {
        // t = S 时正好落在 request_retention，这是 FSRS 的定义，
        // 也是引擎里 ts-fsrs 的默认参数。两边对不上就会出现
        // 「今日复习说该练了、掌握度说还很熟」。
        let atStability = ForgettingCurve.retention(stability: 10, elapsedDays: 10)
        XCTAssertEqual(try XCTUnwrap(atStability), 0.9, accuracy: 0.001)

        XCTAssertEqual(try XCTUnwrap(ForgettingCurve.retention(stability: 10, elapsedDays: 0)), 1, accuracy: 0.0001)
        let fresh = try? XCTUnwrap(ForgettingCurve.retention(stability: 10, elapsedDays: 1))
        let stale = try? XCTUnwrap(ForgettingCurve.retention(stability: 10, elapsedDays: 120))
        XCTAssertGreaterThan(fresh ?? 0, stale ?? 1)
        XCTAssertLessThan(stale ?? 1, 0.7)
        XCTAssertGreaterThan(stale ?? 0, 0)
    }

    func testNoStabilityMeansNoCurveRatherThanAGuess() {
        XCTAssertNil(ForgettingCurve.retention(stability: 0, elapsedDays: 5))
        XCTAssertNil(ForgettingCurve.retention(stability: -3, elapsedDays: 5))
        XCTAssertNil(ForgettingCurve.retention(stability: .nan, elapsedDays: 5))
        // 没有曲线时掌握度原样保留，不能凭空打折。
        XCTAssertEqual(ForgettingCurve.effectiveScore(80, retention: nil), 80)
    }

    func testMasteryDecaysOnlyBelowTheTargetRetention() {
        XCTAssertEqual(ForgettingCurve.effectiveScore(80, retention: 0.95), 80, "还记得牢就不打折")
        XCTAssertEqual(ForgettingCurve.effectiveScore(80, retention: 0.9), 80)
        XCTAssertEqual(ForgettingCurve.effectiveScore(80, retention: 0.4), 80 - 12, accuracy: 0.0001)
        XCTAssertEqual(ForgettingCurve.effectiveScore(5, retention: 0.1), 0, "折到负数要夹回 0")
    }

    func testDaysUntilTargetGoesNegativeOnceItIsAlreadyForgotten() throws {
        let ahead = try XCTUnwrap(
            ForgettingCurve.daysUntil(retention: 0.9, stability: 10, elapsedDays: 2)
        )
        XCTAssertEqual(ahead, 8, accuracy: 0.001)

        let behind = try XCTUnwrap(
            ForgettingCurve.daysUntil(retention: 0.9, stability: 10, elapsedDays: 30)
        )
        XCTAssertLessThan(behind, 0)
    }

    func testRecordWithoutReviewHistoryReportsRawMastery() {
        let record = Self.record(masteryScore: 72, stability: 0, lastReviewedAt: nil)
        XCTAssertNil(record.retention())
        XCTAssertEqual(record.effectiveMastery(), 72)
    }

    func testForgottenRecordOutranksAFreshOneWithTheSameScore() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let due = now.addingTimeInterval(-2 * 86_400)
        let fresh = Self.record(
            id: "fresh",
            masteryScore: 80,
            stability: 40,
            lastReviewedAt: now.addingTimeInterval(-3 * 86_400),
            dueAt: due
        )
        let forgotten = Self.record(
            id: "forgotten",
            masteryScore: 80,
            stability: 3,
            lastReviewedAt: now.addingTimeInterval(-60 * 86_400),
            dueAt: due
        )

        XCTAssertGreaterThan(forgotten.effectiveMastery(at: now), 0)
        XCTAssertLessThan(forgotten.effectiveMastery(at: now), fresh.effectiveMastery(at: now))
        XCTAssertGreaterThan(
            LearningReviewSchedule.priority(for: forgotten, reference: now),
            LearningReviewSchedule.priority(for: fresh, reference: now),
            "同样逾期两天、同样 80 分，忘得多的那条要排前面"
        )

        let plan = LearningReviewSchedule.plan(
            records: [fresh, forgotten],
            settings: Self.settings(reviewTarget: 1),
            reference: now
        )
        XCTAssertEqual(plan.reviews.map(\.id), ["forgotten"])
        XCTAssertTrue(LearningReviewSchedule.reason(for: forgotten, reference: now).contains("记忆"))
    }

    private static func settings(reviewTarget: Int) -> LearningSettingsSnapshot {
        var settings = LearningSettingsSnapshot()
        settings.weekdayReviewTarget = reviewTarget
        settings.weeklyReviewTarget = reviewTarget
        settings.dailyNewTarget = 0
        return settings
    }

    private static func record(
        id: String = "r",
        masteryScore: Double,
        stability: Double,
        lastReviewedAt: Date?,
        dueAt: Date = .now
    ) -> LearningRecord {
        LearningRecord(
            id: id,
            kind: "knowledge",
            canonicalKey: "leetcode:\(id)",
            title: id,
            question: "",
            diagnosis: "",
            labels: [],
            prerequisiteLabels: [],
            knowledgePath: ["算法"],
            masteryScore: masteryScore,
            confidence: 0.6,
            evidenceCount: 2,
            evidence: [],
            sourceRefs: [],
            language: "java",
            dueAt: dueAt,
            reviewCount: 2,
            stability: stability,
            lastReviewedAt: lastReviewedAt,
            activeStudyPackage: nil,
            latestAttempt: nil,
            activePackageAttemptCount: 0,
            updatedAt: .now
        )
    }
}
