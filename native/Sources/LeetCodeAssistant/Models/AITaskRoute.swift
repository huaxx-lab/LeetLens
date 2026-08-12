import Foundation

/// Every configurable route corresponds to a real model invocation. Local-only
/// features such as semantic memory retrieval intentionally do not appear here.
enum AITaskRoute: String, CaseIterable, Identifiable, Sendable {
    case conversation
    case conversationArchive = "title"
    case videoMatching = "video"
    case learningAnalysis = "learning"
    case studyPlan
    case studyContent
    case studyAssessment
    case leetCodeAnalysis
    /// 跨会话记忆的异步整合。放在这里就自动出现在设置的任务路由里，
    /// 用户可以给它挑一个便宜的模型——它是后台跑的，不需要主对话那档。
    case memoryConsolidation = "memory"
    /// 写代码时的分级提示。单独一条路由：它要读用户正在写的代码，
    /// 又必须守住"只给方向不给答案"，和出题、评分不是一回事。
    case codingHint = "hint"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .conversation: "主对话"
        case .conversationArchive: "对话标题与摘要"
        case .videoMatching: "B站视频匹配"
        case .learningAnalysis: "学习证据分析"
        case .studyPlan: "AI 学习计划"
        case .studyContent: "复习讲解与出题"
        case .studyAssessment: "作答检测与评分"
        case .leetCodeAnalysis: "LeetCode 提交分析"
        case .memoryConsolidation: "跨对话记忆整合"
        case .codingHint: "写代码时的提示"
        }
    }

    var subtitle: String {
        switch self {
        case .conversation: "普通对话与推理"
        case .conversationArchive: "生成标题、摘要与可延续上下文"
        case .videoMatching: "视频资格判定、搜索词与匹配"
        case .learningAnalysis: "提取学习项、掌握度与证据"
        case .studyPlan: "结合 FSRS、掌握度与时间预算排期"
        case .studyContent: "生成最小讲解、例子和针对性检测"
        case .studyAssessment: "评估作答、错因与下一步"
        case .leetCodeAnalysis: "单次代码审查与多次提交轨迹"
        case .memoryConsolidation: "后台去重、冲突消解，沉淀长期事实"
        case .codingHint: "读当前代码，给方向与卡点，不给答案"
        }
    }

    var systemImage: String {
        switch self {
        case .conversation: "bubble.left.and.bubble.right"
        case .conversationArchive: "textformat"
        case .videoMatching: "play.rectangle"
        case .learningAnalysis: "graduationcap"
        case .studyPlan: "calendar.badge.clock"
        case .studyContent: "book.pages"
        case .studyAssessment: "checkmark.seal"
        case .leetCodeAnalysis: "curlybraces.square"
        case .memoryConsolidation: "brain"
        case .codingHint: "lightbulb.max"
        }
    }

    private var legacyFallbacks: [AITaskRoute] {
        switch self {
        case .studyPlan, .studyContent, .studyAssessment, .leetCodeAnalysis: [.learningAnalysis]
        // 没单独配的话跟着摘要那条走：两者都是便宜的归档类任务。
        case .memoryConsolidation: [.conversationArchive]
        // 没单独配就跟着讲解那条：同样是"讲给人听"的任务。
        case .codingHint: [.studyContent, .learningAnalysis]
        default: []
        }
    }

    func providerID(in settings: LegacySettingsSnapshot) -> String? {
        ([self] + legacyFallbacks).lazy.compactMap { route in
            let providerID = settings.taskRoutes[route.rawValue]?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return providerID?.isEmpty == false ? providerID : nil
        }.first
    }

    func providerID(in root: [String: Any]) -> String? {
        let taskModels = root["taskModels"] as? [String: Any] ?? [:]
        return ([self] + legacyFallbacks).lazy.compactMap { route -> String? in
            let value = taskModels[route.rawValue] as? [String: Any]
            let providerID = (value?["providerId"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return providerID?.isEmpty == false ? providerID : nil
        }.first
    }
}
