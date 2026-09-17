import Foundation

/// 一轮对话的固定编排：**指代消解 → 意图识别 → 路线分流 → 按路线执行**。
///
/// 三条不变量：
/// 1. 消解在前。意图识别永远面对一句自包含的话，不会被"那这个呢"这种半句话干扰。
/// 2. 意图只负责分类，不携带资源标志位。要拉什么资源由**路线**决定——
///    否则 7 个意图最后又会退化成一个布尔。
/// 3. 路线只决定**易变段**（宿主上下文、检索结果）。长期事实与会话目录对所有路线
///    恒定：它们在 prompt 的稳定前缀里，按路线增删会让前缀每轮都变，缓存全废。
enum ConversationRoute: String, Equatable, Sendable, CaseIterable {
    /// 闲聊、问模型自身。不检索、不带宿主上下文。
    case direct
    /// 针对当前代码/报错。只带题面、当前代码、最近评测。
    case hostContext
    /// 通用知识。不翻旧会话——答案不依赖"这个人以前干过什么"。
    case knowledge
    /// 指向历史。要把旧会话捞出来。
    case recall
    /// 个性化（"我哪块弱"）。同样要捞历史，但落点是这个人的画像。
    case profile

    static func route(for intent: ConversationIntent) -> ConversationRoute {
        switch intent {
        case .smalltalk, .meta: .direct
        case .codeDebug: .hostContext
        case .knowledge: .knowledge
        case .recall: .recall
        case .profile: .profile
        // followUp 不该活到这一步：指代消解之后它必然落进上面某一类。
        // 真漏过来就按 recall 走——指代句十有八九指向此前说过的东西。
        case .followUp: .recall
        }
    }
}

/// 路线里的一步。顺序即执行顺序，执行层照着走，不再自己做判断。
enum ConversationStep: String, Equatable, Sendable {
    case attachHostContext
    case retrieveMemory
    case rerankMemory
    case admitMemory
}

struct ConversationRoutePlan: Equatable, Sendable {
    let route: ConversationRoute
    /// 本轮易变段要走的步骤。空数组表示这条路线不需要任何易变上下文。
    let steps: [ConversationStep]

    var retrievesMemory: Bool { steps.contains(.retrieveMemory) }
    var usesHostContext: Bool { steps.contains(.attachHostContext) }

    init(route: ConversationRoute, rerankAvailable: Bool) {
        self.route = route
        switch route {
        case .direct:
            steps = []
        case .knowledge:
            steps = []
        case .hostContext:
            steps = [.attachHostContext]
        case .recall, .profile:
            // 精排关掉时不排这一步，准入改用本地四维置信度——
            // 路线形状如实反映当前可用能力，而不是排一个必然失败的步骤。
            steps = rerankAvailable
                ? [.retrieveMemory, .rerankMemory, .admitMemory]
                : [.retrieveMemory, .admitMemory]
        }
    }
}

/// 消解与分类的合并结果。
struct ConversationTurnPlan: Equatable, Sendable {
    /// 消解后可独立检索、可独立理解的问题。没有指代时就是原话。
    let resolvedQuery: String
    let intent: ConversationIntent
    let plan: ConversationRoutePlan
    /// 这一轮有没有真的花掉一次模型调用。
    let usedModel: Bool

    var route: ConversationRoute { plan.route }
}

/// 规则层的分类结果。**不再携带 needs**：要什么资源由路线决定。
struct ConversationIntentClassification: Equatable, Sendable {
    enum Certainty: Equatable, Sendable {
        /// 规则足够确定，不必花模型调用。
        case settled
        /// 规则给不出结论，或句子里有指代——必须问模型。
        case needsModel
    }

    let intent: ConversationIntent
    let certainty: Certainty
    /// 句子里有代词或省略，需要结合上文改写。
    let mentionsReference: Bool
}
