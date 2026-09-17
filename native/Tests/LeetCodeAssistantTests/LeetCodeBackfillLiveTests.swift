import Foundation
import XCTest
@testable import LeetCodeAssistant

/// 一次性数据修复的自检：学习引擎桥曾因为找不到运行环境而整段失败，
/// 那期间的力扣提交已被记为"已知"，增量同步不会再碰它们。
final class LeetCodeBackfillLiveTests: XCTestCase {
    func testBackfillMergesPreviouslyDroppedSubmissions() async throws {
        guard ProcessInfo.processInfo.environment["LEETLENS_RUN_BACKFILL"] == "1" else {
            throw XCTSkip("设置 LEETLENS_RUN_BACKFILL=1 才对真实数据补账")
        }
        let directory = URL(filePath: NSString(string: "~/Library/Application Support/leetcode-ai-helper/data").expandingTildeInPath)
        guard ChatService.locateElectronExecutable(dataDirectory: directory) != nil else {
            throw XCTSkip("本机没有学习引擎运行环境")
        }

        let before = try Self.unmergedCount(directory: directory)
        let store = await MainActor.run { LegacyDataStore(dataDirectory: directory) }
        await store.hydrate()
        await store.syncLeetCodeAccountActivity()
        let after = try Self.unmergedCount(directory: directory)

        print("BACKFILL before=\(before) after=\(after)")
        XCTAssertLessThanOrEqual(after, before, "补账只能减少欠账")
    }

    /// 计划内题目的提交里，有多少还没进学习引擎。
    private static func unmergedCount(directory: URL) throws -> Int {
        let learning = try JSONSerialization.jsonObject(
            with: Data(contentsOf: directory.appending(path: "learning.json"))
        ) as? [String: Any] ?? [:]
        let leetCode = try JSONSerialization.jsonObject(
            with: Data(contentsOf: directory.appending(path: "leetcode-cn.json"))
        ) as? [String: Any] ?? [:]

        var attemptIDs = Set<String>()
        for item in (learning["items"] as? [String: Any] ?? [:]).values {
            guard let evidence = (item as? [String: Any])?["evidence"] as? [[String: Any]] else { continue }
            for entry in evidence where entry["type"] as? String == "leetcode_submission" {
                if let id = entry["attemptId"] as? String { attemptIDs.insert(id) }
            }
        }
        var planSlugs = Set<String>()
        for plan in (leetCode["plans"] as? [String: Any] ?? [:]).values {
            guard let questions = (plan as? [String: Any])?["questions"] as? [[String: Any]] else { continue }
            for question in questions {
                let slug = (question["titleSlug"] as? String ?? "").lowercased()
                if !slug.isEmpty { planSlugs.insert(slug) }
            }
        }
        let submissions = leetCode["submissions"] as? [[String: Any]] ?? []
        return submissions.count { submission in
            let slug = (submission["titleSlug"] as? String ?? "").lowercased()
            guard planSlugs.contains(slug) else { return false }
            return !attemptIDs.contains("lc_\(submission["id"] as? String ?? "")")
        }
    }
}
