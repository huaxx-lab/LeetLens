import Foundation

struct LearningAnalysisMessage: Sendable, Hashable {
    let id: String
    let content: String
    let createdAt: Date

    var dictionary: [String: Any] {
        [
            "id": id,
            "role": "user",
            "content": content,
            "createdAt": Int(createdAt.timeIntervalSince1970 * 1_000)
        ]
    }
}

struct LearningAnalysisContext: Codable, Sendable, Hashable {
    let id: String
    let kind: String
    let title: String
    let question: String
    let knowledgePath: [String]
    let language: String
    let labels: [String]
    let diagnosis: String
    let masteryScore: Double
    let confidence: Double
    let evidenceCount: Int
}

struct LearningAnalysisItem: Codable, Sendable, Hashable {
    let kind: String
    let title: String
    let question: String
    let knowledgePath: [String]
    let language: String
    let labels: [String]
    let prerequisiteLabels: [String]
    let diagnosis: String
    let canonicalKey: String
    let sourceMessageIds: [String]
    let masterySignal: String
    let confidence: Double
    let videoEligible: Bool
}

struct LearningAnalysisResult: Codable, Sendable, Hashable {
    var items: [LearningAnalysisItem]
    var fingerprint: String
    var messageVersions: [String]

    private enum CodingKeys: String, CodingKey { case items, fingerprint, messageVersions }

    init(items: [LearningAnalysisItem], fingerprint: String = "", messageVersions: [String] = []) {
        self.items = items
        self.fingerprint = fingerprint
        self.messageVersions = messageVersions
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        items = try values.decodeIfPresent([LearningAnalysisItem].self, forKey: .items) ?? []
        fingerprint = try values.decodeIfPresent(String.self, forKey: .fingerprint) ?? ""
        messageVersions = try values.decodeIfPresent([String].self, forKey: .messageVersions) ?? []
    }

    var dictionary: [String: Any] {
        let data = try? JSONEncoder().encode(self)
        return data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
    }
}

/// 模型返回的 JSON 总有小偏差：少个字段、给了 null、把数组写成一句话、把数字当字符串。
/// 一个字段的偏差不该让整包内容作废——统一按"读得出就用，读不出当空"处理。
/// 真正不能少的字段由调用方在拿到结果后判空并给出人话错误。
extension KeyedDecodingContainerProtocol {
    func lenientString(_ key: Key) -> String {
        if let value = try? decode(String.self, forKey: key) { return value }
        if let value = try? decode(Int.self, forKey: key) { return String(value) }
        if let value = try? decode(Double.self, forKey: key) { return String(value) }
        if let value = try? decode(Bool.self, forKey: key) { return value ? "true" : "false" }
        return ""
    }

    func lenientStrings(_ key: Key) -> [String] {
        if let list = try? decode([String].self, forKey: key) { return list }
        // 常见走样：整段写成一句话，或者写成 [{"text": "..."}] 这种对象数组。
        if let single = try? decode(String.self, forKey: key) {
            return single.isEmpty ? [] : [single]
        }
        if let objects = try? decode([[String: String]].self, forKey: key) {
            return objects.compactMap { $0["text"] ?? $0["content"] ?? $0.values.first }
        }
        return []
    }

    func lenientDouble(_ key: Key) -> Double {
        if let value = try? decode(Double.self, forKey: key) { return value }
        if let value = try? decode(Int.self, forKey: key) { return Double(value) }
        if let text = try? decode(String.self, forKey: key) { return Double(text) ?? 0 }
        return 0
    }
}

struct LearningLesson: Codable, Sendable, Hashable {
    let overview: String
    let keyPoints: [String]
    let pitfalls: [String]
    let example: String

    init(overview: String, keyPoints: [String], pitfalls: [String], example: String) {
        self.overview = overview
        self.keyPoints = keyPoints
        self.pitfalls = pitfalls
        self.example = example
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        overview = values.lenientString(.overview)
        keyPoints = values.lenientStrings(.keyPoints)
        pitfalls = values.lenientStrings(.pitfalls)
        example = values.lenientString(.example)
    }

    var isEmpty: Bool {
        overview.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && keyPoints.isEmpty && pitfalls.isEmpty
    }
}

/// 写代码时的一条提示。级别越高越具体，但任何一级都不给完整解法。
struct CodingHint: Codable, Sendable, Hashable, Identifiable {
    /// 1 方向 / 2 卡点 / 3 下一步。由请求方回填，模型说了不算。
    var level = 1
    var title = ""
    var hint = ""
    var checkpoints: [String] = []
    var question = ""
    var model: String? = nil

    init(
        level: Int = 1,
        title: String = "",
        hint: String = "",
        checkpoints: [String] = [],
        question: String = "",
        model: String? = nil
    ) {
        self.level = level
        self.title = title
        self.hint = hint
        self.checkpoints = checkpoints
        self.question = question
        self.model = model
    }

    /// 模型少给一两个字段是常事（尤其 question、checkpoints）。
    /// 缺了就留空，而不是让整条提示解不出来——真正不能少的只有 hint，
    /// 那一层由调用方判空。
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        level = (try? values.decodeIfPresent(Int.self, forKey: .level)) ?? 1
        title = values.lenientString(.title)
        hint = values.lenientString(.hint)
        checkpoints = values.lenientStrings(.checkpoints)
        question = values.lenientString(.question)
        model = try? values.decodeIfPresent(String.self, forKey: .model)
    }

    var id: Int { level }

    var levelTitle: String {
        switch level {
        case 1: "方向"
        case 2: "卡点"
        default: "下一步"
        }
    }
}

struct LearningExercise: Codable, Sendable, Hashable {
    let type: String
    let title: String
    let prompt: String
    let instructions: String
    let language: String
    let starterCode: String
    let choices: [String]
    let examples: [String]
    let constraints: [String]
    let rubric: [String]
    let referenceAnswer: String

    init(
        type: String, title: String, prompt: String, instructions: String,
        language: String, starterCode: String, choices: [String], examples: [String],
        constraints: [String], rubric: [String], referenceAnswer: String
    ) {
        self.type = type
        self.title = title
        self.prompt = prompt
        self.instructions = instructions
        self.language = language
        self.starterCode = starterCode
        self.choices = choices
        self.examples = examples
        self.constraints = constraints
        self.rubric = rubric
        self.referenceAnswer = referenceAnswer
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        type = values.lenientString(.type).isEmpty ? "short_answer" : values.lenientString(.type)
        title = values.lenientString(.title)
        prompt = values.lenientString(.prompt)
        instructions = values.lenientString(.instructions)
        language = values.lenientString(.language)
        starterCode = values.lenientString(.starterCode)
        choices = values.lenientStrings(.choices)
        examples = values.lenientStrings(.examples)
        constraints = values.lenientStrings(.constraints)
        rubric = values.lenientStrings(.rubric)
        referenceAnswer = values.lenientString(.referenceAnswer)
    }
}

struct LearningPackageDraft: Codable, Sendable, Hashable {
    let lesson: LearningLesson
    let exercise: LearningExercise
    var model: String? = nil

    var dictionary: [String: Any] {
        let data = try? JSONEncoder().encode(self)
        return data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
    }
}

struct LearningStudyPackage: Identifiable, Sendable, Hashable {
    let id: String
    let lesson: LearningLesson
    let exercise: LearningExercise
    let generatedAt: Date
    let model: String
}

struct LearningAttemptJudgment: Codable, Sendable, Hashable {
    let score: Double
    let verdict: String
    let feedback: String
    let strengths: [String]
    let gaps: [String]
    let nextStep: String
    var model: String? = nil

    init(
        score: Double, verdict: String, feedback: String,
        strengths: [String], gaps: [String], nextStep: String, model: String? = nil
    ) {
        self.score = score
        self.verdict = verdict
        self.feedback = feedback
        self.strengths = strengths
        self.gaps = gaps
        self.nextStep = nextStep
        self.model = model
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        score = values.lenientDouble(.score)
        verdict = values.lenientString(.verdict)
        feedback = values.lenientString(.feedback)
        strengths = values.lenientStrings(.strengths)
        gaps = values.lenientStrings(.gaps)
        nextStep = values.lenientString(.nextStep)
        model = try? values.decodeIfPresent(String.self, forKey: .model)
    }

    var dictionary: [String: Any] {
        let data = try? JSONEncoder().encode(self)
        return data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
    }
}

struct LearningAttempt: Identifiable, Sendable, Hashable {
    let id: String
    let packageID: String
    let answer: String
    let score: Double
    let verdict: String
    let feedback: String
    let strengths: [String]
    let gaps: [String]
    let nextStep: String
    let submittedAt: Date
}
