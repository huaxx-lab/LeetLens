import Foundation

enum LearningEngineBridgeError: LocalizedError {
    case unavailable
    case rejected(String)

    var errorDescription: String? {
        switch self {
        case .unavailable:
            "没有找到原项目学习引擎运行环境"
        case .rejected(let message):
            message
        }
    }
}

actor LearningEngineBridge {
    private static let marker = "__LEARNING_ENGINE__"
    private let learningFile: URL

    init(dataDirectory: URL) {
        learningFile = dataDirectory.appending(path: "learning.json")
    }

    func mergeAnalysis(
        conversationID: String,
        result: LearningAnalysisResult,
        messages: [LearningAnalysisMessage]
    ) async throws {
        try await run([
            "operation": "mergeAnalysis",
            "conversationId": conversationID,
            "analysis": result.dictionary,
            "messages": messages.map(\.dictionary)
        ])
    }

    func review(itemID: String, rating: Int) async throws {
        try await run(["operation": "review", "itemId": itemID, "rating": rating])
    }

    func savePackage(itemID: String, package: LearningPackageDraft) async throws {
        try await run([
            "operation": "savePackage",
            "itemId": itemID,
            "package": package.dictionary
        ])
    }

    func recordAttempt(
        itemID: String,
        packageID: String,
        answer: String,
        judgment: LearningAttemptJudgment
    ) async throws {
        try await run([
            "operation": "recordAttempt",
            "itemId": itemID,
            "submission": ["packageId": packageID, "answer": answer],
            "judgment": judgment.dictionary
        ])
    }

    func mergeLeetCodeSubmissions(planQuestionsJSON: Data, submissionsJSON: Data) async throws {
        let questions = try JSONSerialization.jsonObject(with: planQuestionsJSON) as? [[String: Any]] ?? []
        let submissions = try JSONSerialization.jsonObject(with: submissionsJSON) as? [[String: Any]] ?? []
        try await run([
            "operation": "mergeLeetCodeSubmissions",
            "planQuestions": questions,
            "submissions": submissions
        ])
    }

    func mergeLeetCodeAnalysis(titleSlug: String, analysisJSON: Data) async throws {
        let analysis = try JSONSerialization.jsonObject(with: analysisJSON) as? [String: Any] ?? [:]
        try await run([
            "operation": "mergeLeetCodeAnalysis",
            "titleSlug": titleSlug,
            "analysis": analysis
        ])
    }

    /// Moves an *active* knowledge item to the trash.
    ///
    /// The bridge previously exposed only restore/purge/emptyTrash, so the native UI
    /// could act on items already in the trash but had no way to put one there. The
    /// canonical engine writes the deleted snapshot, the suppression tombstone and the
    /// change log together, which is what stops a deleted item being re-learned.
    func delete(itemID: String, reason: String = "manual") async throws {
        try await run(["operation": "delete", "itemId": itemID, "reason": reason])
    }

    func restore(itemID: String) async throws {
        try await run(["operation": "restore", "itemId": itemID])
    }

    func purge(itemID: String) async throws {
        try await run(["operation": "purge", "itemId": itemID])
    }

    func emptyTrash() async throws {
        try await run(["operation": "emptyTrash"])
    }

    func updateSettings(
        dailyNewTarget: Int,
        weekdayReviewTarget: Int,
        weeklyReviewTarget: Int,
        preferredLanguage: String
    ) async throws {
        try await run([
            "operation": "updateSettings",
            "settings": [
                "dailyNewTarget": dailyNewTarget,
                "weekdayReviewTarget": weekdayReviewTarget,
                "weeklyReviewTarget": weeklyReviewTarget,
                "preferredLanguage": preferredLanguage
            ]
        ])
    }

    private func run(_ input: [String: Any]) async throws {
        guard let electronURL = ChatService.locateElectronExecutable(),
              let helperURL = Bundle.module.url(
                forResource: "learning-engine-bridge",
                withExtension: "cjs",
                subdirectory: "LearningBridge"
              ) ?? Bundle.module.url(forResource: "learning-engine-bridge", withExtension: "cjs")
        else { throw LearningEngineBridgeError.unavailable }

        let inputData = try JSONSerialization.data(withJSONObject: input)
        var environment = ProcessInfo.processInfo.environment
        environment["ELECTRON_RUN_AS_NODE"] = "1"
        let result = try await SubprocessRunner.run(
            executableURL: electronURL,
            arguments: [helperURL.path, learningFile.path],
            environment: environment,
            standardInput: inputData,
            timeout: 15
        )
        let output = String(decoding: result.standardOutput, as: UTF8.self)
        let errorText = String(decoding: result.standardError, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let payload = output.split(separator: "\n")
            .first(where: { $0.hasPrefix(Self.marker) })
            .map { String($0.dropFirst(Self.marker.count)) }
        guard result.terminationStatus == 0,
              let payload,
              let data = payload.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["ok"] as? Bool == true
        else {
            throw LearningEngineBridgeError.rejected(
                errorText.isEmpty ? "原项目学习引擎没有完成写回" : errorText
            )
        }
    }
}
