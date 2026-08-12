import Foundation

/// 「AI 讲解」的唯一生成入口。
///
/// 讲解本身不是哪个界面私有的东西：它是学习包（lesson + exercise）的一部分，
/// 生成一次就存进学习记录，今日复习、学习题库、脑图读的都是同一份。
/// 谁先打开谁触发生成，后来的直接读现成的，不会为同一道题重复烧 token。
///
/// 依赖顺序是单向的，任何一层都不回头写上一层：
///
///     学习记录  →  学习包（讲解 / 检测）  →  脑图派生节点  →  脑图人工层（笔记 / 链接）
///
/// 所以删掉一个知识点时，后面三层会自己跟着塌掉：记录没了 → 派生节点没了 →
/// `KnowledgeGraphOverlay.reconciled` 把挂在死节点上的笔记和链接清掉。
/// 脑图那边只会请求「补一份讲解」，永远不往学习记录里写别的字段。
@MainActor
enum LearningPackageProvisioner {
    /// 正在生成的 recordID → 任务。同一道题的并发请求合流到同一个任务上，
    /// 不然从脑图和今日复习同时点一下就是两次 AI 调用。
    private static var inFlight: [String: Task<Void, Error>] = [:]

    /// 这道题正在生成学习包吗。UI 拿它显示「生成中」。
    static func isGenerating(_ recordID: String) -> Bool {
        inFlight[recordID] != nil
    }

    /// 确保这道题有学习包。已经有了就直接返回，一次 AI 都不调。
    ///
    /// - Parameter force: 重新生成（换练习题型时用），已有的会被覆盖。
    static func ensurePackage(
        for record: LearningRecord,
        dataStore: LegacyDataStore,
        requestedType: String = "auto",
        force: Bool = false
    ) async throws {
        if record.activeStudyPackage != nil, !force { return }
        if let running = inFlight[record.id] {
            // 别人已经在生成同一道题了，等它，而不是再发一次请求。
            try await running.value
            return
        }
        let recordID = record.id
        let task = Task { @MainActor in
            // 不在界面层提前解析供应商；统一入口按 `.studyContent` 读取最新设置，
            // 避免一个旧快照绕过中央任务路由。
            let draft = try await ChatService(dataDirectory: dataStore.dataDirectory).prepareLearningPackage(
                record: record,
                requestedType: requestedType,
                providerID: nil
            )
            try await dataStore.saveLearningPackage(draft, for: recordID)
        }
        inFlight[recordID] = task
        defer { inFlight[recordID] = nil }
        try await task.value
    }
}
