import Foundation
import XCTest
@testable import LeetCodeAssistant

final class LegacyDataStoreTests: XCTestCase {
    func testBilibiliVideoURLPolicyOnlyAcceptsVideoPages() throws {
        XCTAssertEqual(
            BilibiliVideoURLPolicy.bvid(from: try XCTUnwrap(URL(string: "https://www.bilibili.com/video/BV1GW4y127Qo/?p=2"))),
            "BV1GW4y127Qo"
        )
        XCTAssertNil(BilibiliVideoURLPolicy.bvid(from: try XCTUnwrap(URL(string: "https://www.bilibili.com/"))))
        XCTAssertNil(BilibiliVideoURLPolicy.bvid(from: try XCTUnwrap(URL(string: "https://example.com/video/BV1GW4y127Qo"))))
    }

    @MainActor
    func testBilibiliVisitsPersistWithoutCountingDelegateDuplicates() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "BilibiliHistoryTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = try XCTUnwrap(URL(string: "https://www.bilibili.com/video/BV1GW4y127Qo/"))
        let firstDate = Date(timeIntervalSince1970: 1_800_000_000)
        let store = LegacyDataStore(dataDirectory: directory)

        try store.recordVideoVisit(url: url, title: "三数之和", at: firstDate)
        try store.recordVideoVisit(url: url, title: "三数之和（已加载）", at: firstDate.addingTimeInterval(5))
        try store.recordVideoVisit(url: url, title: "三数之和", at: firstDate.addingTimeInterval(45))

        XCTAssertEqual(store.videoHistory.first?.openCount, 2)
        let reopened = LegacyDataStore(dataDirectory: directory)
        await reopened.hydrate()
        XCTAssertEqual(reopened.videoHistory.first?.bvid, "BV1GW4y127Qo")
        XCTAssertEqual(reopened.videoHistory.first?.openCount, 2)
    }

    @MainActor
    func testProviderMutationsRejectMissingIDsAndDeletionRemovesRoutes() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "ProviderMutationTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let settings: [String: Any] = [
            "providerOrder": ["p1", "p2"],
            "activeProvider": "p1",
            "providers": [
                "p1": ["name": "一号", "apiBase": "https://one.example.com/v1", "apiKey": "configured", "model": "m1"],
                "p2": ["name": "二号", "apiBase": "https://two.example.com/v1", "apiKey": "configured", "model": "m2"]
            ],
            "taskModels": [
                AITaskRoute.studyContent.rawValue: ["providerId": "p1"],
                AITaskRoute.codingHint.rawValue: ["providerId": "p2"]
            ]
        ]
        try JSONSerialization.data(withJSONObject: settings)
            .write(to: directory.appending(path: "settings.json"), options: .atomic)

        let store = LegacyDataStore(dataDirectory: directory)
        await store.hydrate()

        XCTAssertThrowsError(try store.activateProvider("missing"))
        XCTAssertThrowsError(try store.saveTaskRoute(AITaskRoute.studyPlan.rawValue, providerID: "missing"))
        XCTAssertEqual(store.settings.activeProviderID, "p1")
        XCTAssertNil(store.settings.taskRoutes[AITaskRoute.studyPlan.rawValue])

        try store.deleteProvider("p1")

        XCTAssertEqual(store.settings.activeProviderID, "p2")
        XCTAssertNil(store.settings.taskRoutes[AITaskRoute.studyContent.rawValue])
        XCTAssertEqual(store.settings.taskRoutes[AITaskRoute.codingHint.rawValue], "p2")
    }

    @MainActor
    func testProviderSettingsModelDoesNotSilentlyOperateOnFirstProvider() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "ProviderSelectionTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let settings: [String: Any] = [
            "providerOrder": ["p1"],
            "activeProvider": "deleted-provider",
            "providers": [
                "p1": ["name": "现有供应商", "apiBase": "https://one.example.com/v1", "apiKey": "", "model": "m1"]
            ]
        ]
        try JSONSerialization.data(withJSONObject: settings)
            .write(to: directory.appending(path: "settings.json"), options: .atomic)

        let store = LegacyDataStore(dataDirectory: directory)
        await store.hydrate()
        let model = ProviderSettingsModel(dataStore: store)

        XCTAssertEqual(model.selectedProvider?.id, "p1")
        model.select("missing")
        XCTAssertEqual(model.selectedProvider?.id, "p1")

        try store.deleteProvider("p1")
        model.storeDidChange()
        XCTAssertNil(model.selectedProvider)
        XCTAssertNil(model.selectedProviderID)
        XCTAssertEqual(model.apiBaseDraft, "")
        XCTAssertEqual(model.modelDraft, "")
    }

    @MainActor
    func testAssistantMessagePersistsRuntimeProviderAndModelSnapshot() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "ConversationModelSnapshotTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = LegacyDataStore(dataDirectory: directory)
        let conversationID = try store.createConversation(
            title: "模型切换",
            firstMessage: ConversationTranscriptMessage(
                id: "user-message",
                role: "user",
                content: "你是什么模型",
                createdAt: .now
            )
        )
        try store.appendMessage(
            ConversationTranscriptMessage(
                id: "assistant-message",
                role: "assistant",
                content: "本轮回答",
                createdAt: .now,
                providerID: "opencode-go",
                model: "deepseek-v4-flash"
            ),
            to: conversationID
        )

        let reloaded = LegacyDataStore(dataDirectory: directory)
        await reloaded.hydrate()
        let message = try XCTUnwrap(reloaded.conversations.first { $0.id == conversationID }?.messages.last)
        XCTAssertEqual(message.providerID, "opencode-go")
        XCTAssertEqual(message.model, "deepseek-v4-flash")
    }

    @MainActor
    func testLeetCodeWebLoginPersistsProfileStudyPlanAndResolvedSubmission() throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "LeetCodeWebLoginTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = LegacyDataStore(dataDirectory: directory)

        try store.applyLeetCodeWebSync(
            account: ["isSignedIn": true, "username": "coder", "realName": "Coder"],
            submissions: [[
                "id": "42", "title": "Two Sum", "statusDisplay": "Accepted",
                "lang": "java", "timestamp": 1_800_000_000
            ]],
            studyPlan: [
                "slug": "top-100-liked", "name": "LeetCode 热题 100",
                "planSubGroups": [[
                    "name": "哈希", "questions": [[
                        "titleSlug": "two-sum", "title": "Two Sum", "translatedTitle": "两数之和",
                        "questionFrontendId": "1", "difficulty": "EASY", "status": "TO_DO",
                        "paidOnly": false, "topicTags": [["name": "Array", "nameTranslated": "数组", "slug": "array"]]
                    ]]
                ]]
            ]
        )

        XCTAssertTrue(store.leetCodeSignedIn)
        XCTAssertEqual(store.leetCodeProfile.displayName, "Coder")
        XCTAssertEqual(store.activeLeetCodePlanID, "top-100-liked")
        XCTAssertEqual(store.leetCodeQuestions.map(\.titleSlug), ["two-sum"])
        XCTAssertEqual(store.leetCodeQuestions.first?.topicTags, ["数组"])
        XCTAssertEqual(store.leetCodeSubmissions.first?.titleSlug, "two-sum")
        XCTAssertTrue(store.leetCodeSubmissions.first?.accepted == true)
    }

    func testConcurrentLearningBridgeMutationsDoNotLoseUpdates() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "LearningBridgeConcurrencyTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let restoredID = "l_00000000000000d4"
        let purgedID = "l_00000000000000e5"
        let fixture: [String: Any] = [
            "schemaVersion": 3,
            "items": [:],
            "deletedItems": [
                restoredID: ["snapshot": ["id": restoredID, "kind": "knowledge", "title": "restore"]],
                purgedID: ["snapshot": ["id": purgedID, "kind": "knowledge", "title": "purge"]]
            ]
        ]
        try JSONSerialization.data(withJSONObject: fixture)
            .write(to: directory.appending(path: "learning.json"), options: .atomic)

        let firstBridge = LearningEngineBridge(dataDirectory: directory)
        let secondBridge = LearningEngineBridge(dataDirectory: directory)
        async let restore: Void = firstBridge.restore(itemID: restoredID)
        async let purge: Void = secondBridge.purge(itemID: purgedID)
        _ = try await (restore, purge)

        let data = try Data(contentsOf: directory.appending(path: "learning.json"))
        let root = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let items = root["items"] as? [String: Any] ?? [:]
        let deleted = root["deletedItems"] as? [String: Any] ?? [:]
        XCTAssertNotNil(items[restoredID])
        XCTAssertNil(deleted[restoredID])
        XCTAssertNil(deleted[purgedID])
    }

    @MainActor
    func testLearningSettingsUseBridgeAndReloadRealSnapshot() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "LearningSettingsBridgeTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = LegacyDataStore(dataDirectory: directory)

        try await store.saveLearningSettings(
            dailyNewTarget: 5,
            weekdayReviewTarget: 8,
            weeklyReviewTarget: 20,
            preferredLanguage: "Swift"
        )

        XCTAssertEqual(store.learningSettings.dailyNewTarget, 5)
        XCTAssertEqual(store.learningSettings.weekdayReviewTarget, 8)
        XCTAssertEqual(store.learningSettings.weeklyReviewTarget, 20)
        XCTAssertEqual(store.learningSettings.preferredLanguage, "swift")
        let data = try Data(contentsOf: directory.appending(path: "learning.json"))
        let root = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let settings = try XCTUnwrap(root["settings"] as? [String: Any])
        XCTAssertEqual((settings["dailyNewTarget"] as? NSNumber)?.intValue, 5)
        XCTAssertEqual(settings["preferredLanguage"] as? String, "swift")
    }

    @MainActor
    func testReviewUsesOriginalLearningEngineAndPersistsFSRSState() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "LegacyLearningBridgeTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let itemID = "l_0123456789abcdef"
        let now = Int(Date.now.timeIntervalSince1970 * 1_000)
        let fixture: [String: Any] = [
            "schemaVersion": 3,
            "items": [itemID: [
                "id": itemID,
                "kind": "knowledge",
                "title": "Java 队列",
                "question": "Queue 的 offer 和 add 有什么区别？",
                "labels": ["Queue"],
                "knowledgePath": ["常用 API", "集合框架"],
                "mastery": ["score": 42, "confidence": 0.3, "evidenceCount": 1],
                "review": [
                    "card": ["due": now, "stability": 0, "difficulty": 0, "elapsed_days": 0, "scheduled_days": 0, "reps": 0, "lapses": 0, "learning_steps": 0, "state": 0, "last_review": NSNull()],
                    "lastRating": 0,
                    "lastReviewedAt": 0,
                    "reviewCount": 0
                ],
                "evidence": [],
                "sourceRefs": [],
                "study": ["packages": [], "activePackageId": "", "attempts": []],
                "createdAt": now - 86_400_000,
                "updatedAt": now - 86_400_000
            ]],
            "templates": [:],
            "deletedItems": [:],
            "suppressedItems": [:],
            "analysis": [:],
            "reviewLog": [],
            "changeLog": []
        ]
        let data = try JSONSerialization.data(withJSONObject: fixture)
        try data.write(to: directory.appending(path: "learning.json"), options: .atomic)
        let store = LegacyDataStore(dataDirectory: directory)

        try await store.reviewLearningRecord(itemID, rating: 3)

        XCTAssertEqual(store.learningRecords.first?.reviewCount, 1)
        XCTAssertGreaterThan(store.learningRecords.first?.masteryScore ?? 0, 42)
        let root = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: directory.appending(path: "learning.json"))) as? [String: Any])
        XCTAssertEqual((root["reviewLog"] as? [Any])?.count, 1)
    }

    @MainActor
    func testConversationMutationsKeepMemoryIndexInSync() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "LegacyDataStoreMemoryTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = LegacyDataStore(dataDirectory: directory)
        let oldID = try store.createConversation(
            title: "最长无重复子串",
            firstMessage: ConversationTranscriptMessage(
                id: "old-message",
                role: "user",
                content: "最长无重复子串用滑动窗口和左指针处理",
                createdAt: .now
            )
        )
        let currentID = try store.createConversation(title: "新会话")

        await store.waitForMemoryIndex()
        let indexedIDs = await store.conversationMemoryIndex.indexedConversationIDs
        XCTAssertTrue(indexedIDs.contains(oldID))
        let hit = await store.searchMemory(
            query: "最长无重复子串的滑动窗口左指针怎么移动",
            currentConversationID: currentID
        )
        XCTAssertEqual(hit.first?.conversationID, oldID)

        try store.deleteConversation(oldID)

        await store.waitForMemoryIndex()
        let remainingIDs = await store.conversationMemoryIndex.indexedConversationIDs
        XCTAssertFalse(remainingIDs.contains(oldID))
        let afterDelete = await store.searchMemory(
            query: "最长无重复子串的滑动窗口左指针怎么移动",
            currentConversationID: currentID
        )
        XCTAssertTrue(afterDelete.isEmpty)
    }

    @MainActor
    func testBatchStudyPlanPersistsOnlyAfterEveryDraftIsValid() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "StudyPlanBatchTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = LegacyDataStore(dataDirectory: directory)
        let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: .now)!

        try store.createStudyTasks([
            StudyPlanDraft(title: "复习滑动窗口", notes: "FSRS 到期", scheduledAt: tomorrow, durationMinutes: 30, priority: .important),
            StudyPlanDraft(title: "检测 Java 队列", scheduledAt: tomorrow.addingTimeInterval(3_600), durationMinutes: 15)
        ])

        XCTAssertEqual(store.studyPlanTasks.count, 2)
        let reopened = LegacyDataStore(dataDirectory: directory)
        await reopened.hydrate()
        XCTAssertEqual(reopened.studyPlanTasks.count, 2)

        XCTAssertThrowsError(try store.createStudyTasks([
            StudyPlanDraft(title: "有效任务", scheduledAt: tomorrow),
            StudyPlanDraft(title: "   ", scheduledAt: tomorrow)
        ]))
        XCTAssertEqual(store.studyPlanTasks.count, 2)
        let reopenedAfterFailure = LegacyDataStore(dataDirectory: directory)
        await reopenedAfterFailure.hydrate()
        XCTAssertEqual(reopenedAfterFailure.studyPlanTasks.count, 2)
    }

    @MainActor
    func testLoadsLeetCodeProfileSubmissionsActivityAndPlans() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "LegacyDataStoreTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let calendar = Calendar.current
        let today = calendar.startOfDay(for: .now)
        let yesterday = calendar.date(byAdding: .day, value: -1, to: today)!
        let fixture: [String: Any] = [
            "account": [
                "signedIn": true,
                "username": "swift-user",
                "realName": "Swift User",
                "avatarData": "data:image/png;base64,AQID",
                "isPremium": true
            ],
            "submissions": [
                submission(id: "1", slug: "two-sum", accepted: true, date: yesterday),
                submission(id: "2", slug: "two-sum", accepted: false, date: today),
                submission(id: "3", slug: "valid-parentheses", accepted: true, date: today)
            ],
            "plans": [
                "hot-100": [
                    "name": "LeetCode 热题 100",
                    "questions": [
                        ["titleSlug": "two-sum", "frontendId": "1", "translatedTitle": "两数之和", "difficulty": "EASY", "status": "SOLVED"],
                        ["titleSlug": "valid-parentheses", "frontendId": "20", "translatedTitle": "有效的括号", "difficulty": "EASY", "status": "TO_DO"]
                    ]
                ]
            ],
            "activePlanSlug": "hot-100",
            "analysis": [
                "queue": [
                    "two-sum": [
                        "submissionIds": ["2"],
                        "queuedAt": Int(today.timeIntervalSince1970 * 1_000),
                        "attempts": 2,
                        "nextAttemptAt": Int(today.timeIntervalSince1970 * 1_000),
                        "lastError": "模型暂时不可用"
                    ]
                ],
                "records": [
                    "two-sum": [
                        "summary": "先漏掉边界，修正后通过。",
                        "weaknesses": ["边界条件"],
                        "improvements": ["提交前覆盖空数组"],
                        "analyzedSubmissionIds": ["1"],
                        "attemptInsights": [["submissionId": "1", "issue": "边界遗漏", "change": "补充分支", "outcome": "通过"]],
                        "submissionAnalyses": ["1": ["summary": "边界诊断", "rootCause": "没有处理空数组", "suggestions": ["补充分支"]]],
                        "updatedAt": Int(today.timeIntervalSince1970 * 1_000)
                    ]
                ]
            ]
        ]
        let data = try JSONSerialization.data(withJSONObject: fixture)
        try data.write(to: directory.appending(path: "leetcode-cn.json"), options: .atomic)
        let contentFixture: [String: Any] = [
            "workspaces": [
                "two-sum": ["value": [
                    "question": ["questionId": "1", "content": "<p>题面</p>", "enableRunCode": true, "enableSubmit": true, "exampleTestcases": ["[2,7,11,15]\n9"]],
                    "snippets": [["lang": "Swift", "langSlug": "swift", "code": "class Solution {}"]]
                ]]
            ],
            "submissionDetails": [
                "1": ["detail": ["code": "return []", "lang": "swift", "runtime": "1 ms", "memory": "10 MB", "totalCorrect": 10, "totalTestcases": 10]]
            ]
        ]
        let contentData = try JSONSerialization.data(withJSONObject: contentFixture)
        try contentData.write(to: directory.appending(path: "leetcode-content.json"), options: .atomic)

        let store = LegacyDataStore(dataDirectory: directory)
        await store.hydrate()

        XCTAssertTrue(store.leetCodeSignedIn)
        XCTAssertEqual(store.leetCodeProfile.username, "swift-user")
        XCTAssertEqual(store.leetCodeProfile.displayName, "Swift User")
        XCTAssertEqual(store.leetCodeProfile.avatarData, Data([1, 2, 3]))
        XCTAssertTrue(store.leetCodeProfile.isPremium)
        XCTAssertEqual(store.leetCodeSubmissions.count, 3)
        XCTAssertEqual(store.acceptedSubmissionCount, 2)
        XCTAssertEqual(store.solvedProblemCount, 2)
        XCTAssertEqual(store.leetCodeActivity.count, 2)
        XCTAssertEqual(store.currentLeetCodeStreak, 2)
        // 题单进度以真实通过提交为准：夹具中两道题都已有 accepted 记录。
        XCTAssertEqual(store.leetCodePlans.first?.solvedCount, 2)
        XCTAssertEqual(store.leetCodeQuestions.count, 2)
        XCTAssertEqual(store.leetCodeWorkspaces["two-sum"]?.questionID, "1")
        XCTAssertEqual(store.leetCodeWorkspaces["two-sum"]?.snippets.first?.languageSlug, "swift")
        XCTAssertEqual(store.leetCodeSubmissionDetails["1"]?.runtime, "1 ms")
        XCTAssertEqual(store.leetCodeAnalysisTasks["two-sum"]?.attempts, 2)
        XCTAssertEqual(store.leetCodeAnalysisTasks["two-sum"]?.lastError, "模型暂时不可用")
        XCTAssertEqual(store.leetCodeAnalyses["two-sum"]?.weaknesses, ["边界条件"])
        XCTAssertEqual(store.leetCodeAnalyses["two-sum"]?.attemptInsights.first?.submissionID, "1")
        XCTAssertEqual(store.leetCodeAnalyses["two-sum"]?.submissionAnalyses["1"]?.rootCause, "没有处理空数组")
    }

    private func submission(id: String, slug: String, accepted: Bool, date: Date) -> [String: Any] {
        [
            "id": id,
            "titleSlug": slug,
            "translatedTitle": slug,
            "frontendId": id,
            "lang": "swift",
            "accepted": accepted,
            "submittedAt": Int(date.timeIntervalSince1970 * 1_000),
            "activityType": "review"
        ]
    }
}
