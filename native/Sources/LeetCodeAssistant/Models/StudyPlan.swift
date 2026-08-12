import Foundation

enum StudyTaskPriority: String, CaseIterable, Codable, Sendable, Hashable, Identifiable {
    case normal
    case important
    case urgent

    var id: String { rawValue }

    var title: String {
        switch self {
        case .normal: "普通"
        case .important: "重要"
        case .urgent: "紧急"
        }
    }
}

struct StudyPlanTask: Identifiable, Codable, Sendable, Hashable {
    let id: String
    var title: String
    var notes: String
    var scheduledAt: Date
    var durationMinutes: Int
    var priority: StudyTaskPriority
    var isCompleted: Bool
    var learningRecordID: String?
    let createdAt: Date
    var completedAt: Date?
}

struct StudyPlanDraft: Identifiable, Sendable, Hashable {
    let id = UUID()
    var title = ""
    var notes = ""
    var scheduledAt = Date.now
    var durationMinutes = 30
    var priority = StudyTaskPriority.normal
    var learningRecordID: String?
}

struct AIStudyPlanSuggestion: Identifiable, Sendable, Hashable {
    let id = UUID()
    let summary: String
    /// 已经排好时间的条目。时间由 `StudyPlanScheduler` 决定，不是模型给的。
    let placements: [StudyPlanScheduler.Placement]
    /// 本周容量放不下、这次没排进来的标题。
    let deferred: [String]
    /// 未来已经有安排、这次跳过的标题。
    let alreadyScheduled: [String]

    var tasks: [StudyPlanDraft] { placements.map(\.draft) }
    /// 其中有多少条是把逾期任务挪到新时间（而不是新增）。
    var rescheduledCount: Int { placements.count { $0.reschedulingTaskID != nil } }

    init(
        summary: String,
        placements: [StudyPlanScheduler.Placement],
        deferred: [String] = [],
        alreadyScheduled: [String] = []
    ) {
        self.summary = summary
        self.placements = placements
        self.deferred = deferred
        self.alreadyScheduled = alreadyScheduled
    }
}
