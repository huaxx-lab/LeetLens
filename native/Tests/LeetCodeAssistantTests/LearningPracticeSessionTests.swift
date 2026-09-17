import Foundation
import XCTest
@testable import LeetCodeAssistant

/// 复习页的作答以前是视图 `@State`，而页面是 `switch` 出来的：切到刷题页再回来，
/// 视图被销毁重建，写了一半的代码就没了。草稿必须落盘。
@MainActor
final class LearningPracticeSessionTests: XCTestCase {
    private var directory: URL!

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory
            .appending(path: "practice-\(UUID().uuidString)", directoryHint: .isDirectory)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func testDraftSurvivesAFreshSessionAfterFlush() {
        let session = LearningPracticeSession()
        session.attach(directory: directory)
        session.record(answer: "count += map.getOrDefault(sum - k, 0);", for: "item:pkg", starter: "// TODO")
        session.flush()

        let reopened = LearningPracticeSession()
        reopened.attach(directory: directory)
        XCTAssertEqual(reopened.draft(for: "item:pkg"), "count += map.getOrDefault(sum - k, 0);")
    }

    /// 起始代码原样不动不是草稿：存了它，下次「重新生成」给出新模板时会被旧的盖住。
    func testUntouchedStarterCodeIsNotStoredAndClearsAnExistingDraft() {
        let session = LearningPracticeSession()
        session.attach(directory: directory)
        session.record(answer: "写了一半", for: "k", starter: "// TODO")
        XCTAssertNotNil(session.draft(for: "k"))

        session.record(answer: "  // TODO\n", for: "k", starter: "// TODO")
        XCTAssertNil(session.draft(for: "k"), "回到起始状态就不该再留草稿")
    }

    func testDraftsAreKeyedPerExerciseAndDoNotLeakAcrossItems() {
        let session = LearningPracticeSession()
        session.attach(directory: directory)
        session.record(answer: "第一题的作答", for: "a:1", starter: "")
        session.record(answer: "第二题的作答", for: "b:1", starter: "")

        XCTAssertEqual(session.draft(for: "a:1"), "第一题的作答")
        XCTAssertEqual(session.draft(for: "b:1"), "第二题的作答")
        XCTAssertNil(session.draft(for: "c:1"))
    }

    /// 同一道题重新生成检测题后 key 变了，旧作答不能跟到新题上。
    func testRegeneratingAPackageStartsFromTheNewStarter() {
        let session = LearningPracticeSession()
        session.attach(directory: directory)
        session.record(answer: "针对旧题的作答", for: "item:pkg-1", starter: "// old")
        XCTAssertNil(session.draft(for: "item:pkg-2"))
    }

    func testArchiveIsBoundedByMostRecentEdit() {
        let session = LearningPracticeSession()
        session.attach(directory: directory)
        let base = Date(timeIntervalSince1970: 1_000)
        for index in 0..<(LearningPracticeSession.maximumDrafts + 5) {
            session.record(
                answer: "答案 \(index)",
                for: "k\(index)",
                starter: "",
                now: base.addingTimeInterval(Double(index))
            )
        }
        XCTAssertEqual(session.archive.drafts.count, LearningPracticeSession.maximumDrafts)
        XCTAssertNil(session.draft(for: "k0"), "最久没动的先淘汰")
        XCTAssertNotNil(session.draft(for: "k\(LearningPracticeSession.maximumDrafts + 4)"))
    }

    func testEmptyKeyIsIgnored() {
        let session = LearningPracticeSession()
        session.attach(directory: directory)
        session.record(answer: "无主草稿", for: "", starter: "")
        XCTAssertTrue(session.archive.drafts.isEmpty)
        XCTAssertNil(session.draft(for: ""))
    }
}
