import XCTest
@testable import LeetCodeAssistant

final class ChatServiceTests: XCTestCase {
    func testResponsesCompletedEventTerminatesStreamWithoutWaitingForDoneSentinel() {
        XCTAssertTrue(ChatService.isTerminalStreamEvent(
            eventName: "response.completed",
            object: ["type": "response.completed", "response": ["status": "completed"]]
        ))
        XCTAssertTrue(ChatService.isTerminalStreamEvent(
            eventName: "",
            object: ["type": "message_stop"]
        ))
        XCTAssertTrue(ChatService.isTerminalStreamEvent(
            eventName: "message_end",
            object: [:]
        ))
        // Chat Completions 的 finish_reason 后面还会有 usage 包，不能在这里提前停。
        XCTAssertFalse(ChatService.isTerminalStreamEvent(
            eventName: "",
            object: ["choices": [["finish_reason": "stop"]]]
        ))
        XCTAssertFalse(ChatService.isTerminalStreamEvent(
            eventName: "response.output_text.delta",
            object: ["type": "response.output_text.delta", "delta": "完成"]
        ))
    }

    func testChatFinishReasonDoesNotDropTrailingExactUsage() {
        var accumulator = AIProviderUsageAccumulator()
        let finishPacket: [String: Any] = ["choices": [["finish_reason": "stop"]]]
        XCTAssertFalse(ChatService.isTerminalStreamEvent(eventName: "", object: finishPacket))

        let usagePacket: [String: Any] = [
            "choices": [],
            "model": "gpt-test",
            "usage": ["prompt_tokens": 12, "completion_tokens": 4, "total_tokens": 16]
        ]
        accumulator.merge(ChatService.usage(from: usagePacket)!)
        let usage = accumulator.resolved(
            model: "gpt-test",
            estimatedPromptTokens: 999,
            outputText: "完成",
            reasoningText: "",
            observedTools: [:]
        )
        XCTAssertEqual(usage.totalTokens, 16)
        XCTAssertEqual(usage.exactRequests, 1)
        XCTAssertEqual(usage.estimatedRequests, 0)
    }

    func testExplicitModelSnapshotOverridesProviderModelLoadedLater() {
        XCTAssertEqual(
            ChatService.resolvedModel(configuredModel: "qwen-plus", modelOverride: "deepseek-v4-flash"),
            "deepseek-v4-flash"
        )
        XCTAssertEqual(
            ChatService.resolvedModel(configuredModel: "qwen-plus", modelOverride: nil),
            "qwen-plus"
        )
    }

    func testUsageParserNormalizesOpenAICacheAndReasoningDetails() {
        let usage = ChatService.usage(from: [
            "model": "gpt-test",
            "usage": [
                "prompt_tokens": 120,
                "completion_tokens": 30,
                "total_tokens": 150,
                "prompt_tokens_details": ["cached_tokens": 80],
                "completion_tokens_details": ["reasoning_tokens": 12]
            ]
        ])

        XCTAssertEqual(usage?.promptTokens, 120)
        XCTAssertEqual(usage?.completionTokens, 30)
        XCTAssertEqual(usage?.cachedTokens, 80)
        XCTAssertEqual(usage?.reasoningTokens, 12)
        XCTAssertEqual(usage?.model, "gpt-test")
        XCTAssertEqual(usage?.cacheSupported, true)
    }

    func testEmptyOrMetadataOnlyUsageDoesNotSuppressEstimation() {
        var accumulator = AIProviderUsageAccumulator()
        accumulator.merge(ChatService.usage(from: ["usage": [:]])!)
        accumulator.merge(ChatService.usage(from: ["usage": ["cached_tokens": 4]])!)

        let result = accumulator.resolved(
            model: "gpt-test",
            estimatedPromptTokens: 20,
            outputText: "估算正文",
            reasoningText: "",
            observedTools: [:]
        )
        XCTAssertEqual(result.exactRequests, 0)
        XCTAssertEqual(result.estimatedRequests, 1)
        XCTAssertEqual(result.promptTokens, 20)
        XCTAssertGreaterThan(result.completionTokens, 0)
    }

    func testRecognizedNumericZeroUsageStillCountsAsExact() {
        var accumulator = AIProviderUsageAccumulator()
        accumulator.merge(ChatService.usage(from: [
            "usage": ["prompt_tokens": 0, "completion_tokens": 0, "total_tokens": 0]
        ])!)

        let result = accumulator.resolved(
            model: "gpt-test",
            estimatedPromptTokens: 20,
            outputText: "不应估算",
            reasoningText: "",
            observedTools: [:]
        )
        XCTAssertEqual(result.exactRequests, 1)
        XCTAssertEqual(result.estimatedRequests, 0)
        XCTAssertEqual(result.totalTokens, 0)
    }

    func testPromptOnlyUsagePacketRemainsEstimatedUntilCompletionArrives() {
        var accumulator = AIProviderUsageAccumulator()
        accumulator.merge(ChatService.usage(from: [
            "usage": ["prompt_tokens": 12]
        ])!)

        let result = accumulator.resolved(
            model: "gpt-test",
            estimatedPromptTokens: 20,
            outputText: "需要估算完成 token",
            reasoningText: "",
            observedTools: [:]
        )
        XCTAssertEqual(result.exactRequests, 0)
        XCTAssertEqual(result.estimatedRequests, 1)
    }

    func testBooleanAndNegativeUsageFieldsRemainEstimated() {
        var accumulator = AIProviderUsageAccumulator()
        accumulator.merge(ChatService.usage(from: [
            "usage": ["prompt_tokens": true, "completion_tokens": -1, "total_tokens": -1]
        ])!)

        let result = accumulator.resolved(
            model: "gpt-test",
            estimatedPromptTokens: 20,
            outputText: "估算",
            reasoningText: "",
            observedTools: [:]
        )
        XCTAssertEqual(result.exactRequests, 0)
        XCTAssertEqual(result.estimatedRequests, 1)
    }

    func testAnthropicSplitUsagePacketsMergeIntoOneExactRequest() {
        var accumulator = AIProviderUsageAccumulator()
        accumulator.merge(ChatService.usage(from: [
            "message": ["model": "claude-test", "usage": ["input_tokens": 90, "cache_read_input_tokens": 40]]
        ])!)
        accumulator.merge(ChatService.usage(from: [
            "usage": ["output_tokens": 25]
        ])!)

        let result = accumulator.resolved(
            model: "claude-test",
            estimatedPromptTokens: 999,
            outputText: "ignored",
            reasoningText: "",
            observedTools: [:]
        )
        XCTAssertEqual(result.promptTokens, 90)
        XCTAssertEqual(result.completionTokens, 25)
        XCTAssertEqual(result.totalTokens, 115)
        XCTAssertEqual(result.cachedTokens, 40)
        XCTAssertEqual(result.exactRequests, 1)
        XCTAssertEqual(result.estimatedRequests, 0)
    }

    func testV1UsageDocumentMigratesWithEmptyProviderAndModelBuckets() throws {
        let fixture = """
        {
          "version": 1,
          "totals": {"promptTokens": 10, "completionTokens": 5, "totalTokens": 15, "cachedTokens": 0, "cacheCreationTokens": 0, "reasoningTokens": 0, "textTokens": 0, "toolCalls": 0, "toolUsage": {}, "exactRequests": 1, "estimatedRequests": 0, "cacheTrackedPromptTokens": 0, "cacheSupported": false, "succeededRequests": 1, "failedRequests": 0, "cancelledRequests": 0, "durationMilliseconds": 12, "model": "legacy-model"},
          "byTask": {"studyContent": {"promptTokens": 10, "completionTokens": 5, "totalTokens": 15, "cachedTokens": 0, "cacheCreationTokens": 0, "reasoningTokens": 0, "textTokens": 0, "toolCalls": 0, "toolUsage": {}, "exactRequests": 1, "estimatedRequests": 0, "cacheTrackedPromptTokens": 0, "cacheSupported": false, "succeededRequests": 1, "failedRequests": 0, "cancelledRequests": 0, "durationMilliseconds": 12, "model": "legacy-model"}},
          "updatedAt": -978307200
        }
        """

        let snapshot = try AIUsageLedger.decodeSnapshot(Data(fixture.utf8))

        XCTAssertEqual(snapshot.totals.totalTokens, 15)
        XCTAssertEqual(snapshot.totals.succeededRequests, 1)
        XCTAssertEqual(snapshot.byTask[AITaskRoute.studyContent.rawValue]?.totalTokens, 15)
        XCTAssertTrue(snapshot.byProvider.isEmpty)
        XCTAssertTrue(snapshot.byModel.isEmpty)
    }

    func testDeferredAccountingCommitsOneFinalOutcome() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "ai-usage-deferred-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let accounting = DeferredAIUsageAccounting()
        let entry = AIUsageEntry(
            taskRoute: .studyContent,
            conversationID: nil,
            providerID: "provider-a",
            usage: ConversationUsage(totalTokens: 8, exactRequests: 1, model: "model-a"),
            outcome: .succeeded,
            durationMilliseconds: 9
        )

        await accounting.stage(entry)
        await accounting.commit(outcome: .failed, dataDirectory: directory)
        await accounting.commit(outcome: .succeeded, dataDirectory: directory)
        let snapshot = await AIUsageLedger.shared.snapshot(dataDirectory: directory)

        XCTAssertEqual(snapshot.totals.requestCount, 1)
        XCTAssertEqual(snapshot.totals.failedRequests, 1)
        XCTAssertEqual(snapshot.totals.succeededRequests, 0)
        XCTAssertEqual(snapshot.byProvider["provider-a"]?.requestCount, 1)
    }

    func testCentralLedgerCountsNonConversationModelRoutes() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "ai-usage-ledger-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let usage = ConversationUsage(
            promptTokens: 10,
            completionTokens: 5,
            totalTokens: 15,
            exactRequests: 1,
            model: "planner"
        )

        await AIUsageLedger.shared.record(
            AIUsageEntry(
                taskRoute: .studyPlan,
                conversationID: nil,
                providerID: "planner-provider",
                usage: usage,
                outcome: .succeeded,
                durationMilliseconds: 42
            ),
            dataDirectory: directory
        )
        let snapshot = await AIUsageLedger.shared.snapshot(dataDirectory: directory)

        XCTAssertEqual(snapshot.totals.requestCount, 1)
        XCTAssertEqual(snapshot.totals.totalTokens, 15)
        XCTAssertEqual(snapshot.byTask[AITaskRoute.studyPlan.rawValue]?.requestCount, 1)
        XCTAssertEqual(snapshot.byProvider["planner-provider"]?.totalTokens, 15)
        XCTAssertEqual(
            snapshot.byModel[AIUsageLedger.modelBucketKey(providerID: "planner-provider", model: "planner")]?.requestCount,
            1
        )
        XCTAssertTrue(snapshot.byConversation.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appending(path: "ai-usage.json").path))
    }

    func testTaskRouteCatalogContainsEveryRealModelInvocationExactlyOnce() {
        XCTAssertEqual(
            AITaskRoute.allCases.map(\.rawValue),
            [
                "conversation", "title", "video", "learning",
                "studyPlan", "studyContent", "studyAssessment", "leetCodeAnalysis",
                // 跨对话记忆的离线整合是一次真实的模型调用，必须可路由、可计量。
                "memory",
                // 写代码时的分级提示同样是真实调用。
                "hint"
            ]
        )
        XCTAssertEqual(Set(AITaskRoute.allCases.map(\.rawValue)).count, AITaskRoute.allCases.count)
    }

    func testSpecializedLearningRoutesMigrateFromLegacyLearningRoute() {
        let root: [String: Any] = [
            "taskModels": [
                "learning": ["providerId": "learning-provider"]
            ]
        ]

        XCTAssertEqual(AITaskRoute.studyPlan.providerID(in: root), "learning-provider")
        XCTAssertEqual(AITaskRoute.studyContent.providerID(in: root), "learning-provider")
        XCTAssertEqual(AITaskRoute.studyAssessment.providerID(in: root), "learning-provider")
        XCTAssertEqual(AITaskRoute.leetCodeAnalysis.providerID(in: root), "learning-provider")
        XCTAssertEqual(AITaskRoute.codingHint.providerID(in: root), "learning-provider")
        XCTAssertNil(AITaskRoute.conversation.providerID(in: root))
    }

    func testSpecializedRouteOverridesLegacyLearningRoute() {
        let root: [String: Any] = [
            "taskModels": [
                "learning": ["providerId": "learning-provider"],
                "studyPlan": ["providerId": "planner-provider"]
            ]
        ]

        XCTAssertEqual(AITaskRoute.studyPlan.providerID(in: root), "planner-provider")
    }

    func testBlankSnapshotRouteFallsBackToLegacyRoute() {
        var settings = LegacySettingsSnapshot()
        settings.taskRoutes = [
            AITaskRoute.studyContent.rawValue: "  ",
            AITaskRoute.learningAnalysis.rawValue: "learning-provider"
        ]
        XCTAssertEqual(AITaskRoute.studyContent.providerID(in: settings), "learning-provider")
        XCTAssertEqual(AITaskRoute.codingHint.providerID(in: settings), "learning-provider")
    }

    func testBlankOrStaleSavedTaskRouteFallsBackToActiveProvider() {
        let providers: [String: Any] = [
            "deepseek": ["name": "DeepSeek"],
            "backup": ["name": "Backup"]
        ]
        let root: [String: Any] = [
            "activeProvider": "deepseek",
            "providerOrder": ["deepseek", "backup"]
        ]

        XCTAssertEqual(
            ChatService.resolveProviderID(requestedID: "", root: root, providers: providers),
            "deepseek"
        )
        XCTAssertEqual(
            ChatService.resolveProviderID(requestedID: "deleted-provider", root: root, providers: providers),
            "deepseek"
        )
    }

    func testMissingActiveProviderFallsBackToFirstConfiguredProvider() {
        let providers: [String: Any] = ["backup": ["name": "Backup"]]
        let root: [String: Any] = [
            "activeProvider": "deleted-provider",
            "providerOrder": ["deleted-provider", "backup"]
        ]

        XCTAssertEqual(
            ChatService.resolveProviderID(requestedID: nil, root: root, providers: providers),
            "backup"
        )
    }
}
