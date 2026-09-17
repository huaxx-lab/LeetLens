import Foundation

/// 工具调用的三态。
///
/// 以前只有"有结果"和"没结果"两态，外部调用一律 `try?` 吞成空数组 —— 模型收到的是
/// 「暂时读不到题解」，它会当成"这题没人写题解"，然后放弃或者自己编一篇。
/// **把失败伪装成空结果，比返回空更危险**：前者可以下结论，后者不能。
enum AgentToolStatus: String, Sendable {
    /// 拿到了数据。
    case ok
    /// 确定的空结果：查过了，就是没有。可以据此作答。
    case empty
    /// 没拿到数据。不能下任何结论。
    case failed
}

struct AgentToolFailure: Error, Sendable, Equatable {
    enum Kind: Equatable, Sendable {
        case network
        case timeout
        case serverError(Int)
        case rateLimited
        case notFound
        case unauthorized
        case invalidArguments
        /// 上下文预算不够，本轮不再返回长文。
        case budgetExceeded
        case internalError
    }

    let kind: Kind
    var detail = ""
    var attempts = 1

    /// 回给模型的一句话。重点不是"出了什么错"，而是**能不能下结论、下一步干什么**。
    func narration(tool: String, query: String) -> String {
        let subject = query.isEmpty ? "这次查询" : "「\(query)」"
        let retried = attempts > 1 ? "，已重试 \(attempts) 次" : ""
        switch kind {
        case .network:
            return "网络连不上\(retried)，\(subject)拿不到数据。这不等于没有结果，只是取不到；"
                + "可以基于已有信息作答，或告诉用户稍后再试，不要编造内容。"
        case .timeout:
            return "\(subject)请求超时\(retried)。不要重复调用同一个工具，先用已有信息作答。"
        case .serverError(let status):
            return "服务端返回 \(status)\(retried)。**这不等于没有数据**，是拿不到；"
                + "请基于已有信息作答或换个工具，不要重复调用它，也不要编造内容。"
        case .rateLimited:
            return "调用过于频繁（429）。本轮不要再调用 \(tool)。"
        case .notFound:
            return "没有找到\(subject)。可以让用户确认题号或名称，或换一个更宽的关键词再查一次。"
        case .unauthorized:
            return "没有访问权限（可能未登录）。请告诉用户需要先登录，不要假装查到了数据。"
        case .invalidArguments:
            return "参数不对：\(detail.isEmpty ? "缺少必填字段" : detail)。可以修正后重试一次。"
        case .budgetExceeded:
            return "上下文预算不足，本轮不再返回长文。请基于已有摘要作答。"
        case .internalError:
            return "\(tool) 内部出错\(detail.isEmpty ? "" : "：\(detail)")。换个工具或直接作答。"
        }
    }

    static func from(_ error: Error, attempts: Int = 1) -> AgentToolFailure {
        if let urlError = error as? URLError {
            switch urlError.code {
            case .timedOut: return AgentToolFailure(kind: .timeout, attempts: attempts)
            case .userAuthenticationRequired: return AgentToolFailure(kind: .unauthorized, attempts: attempts)
            default: return AgentToolFailure(kind: .network, detail: urlError.localizedDescription, attempts: attempts)
            }
        }
        if let status = (error as? LeetCodeAPIError)?.statusCode {
            switch status {
            case 401, 403: return AgentToolFailure(kind: .unauthorized, attempts: attempts)
            case 404: return AgentToolFailure(kind: .notFound, attempts: attempts)
            case 429: return AgentToolFailure(kind: .rateLimited, attempts: attempts)
            case 500...599: return AgentToolFailure(kind: .serverError(status), attempts: attempts)
            default: break
            }
        }
        return AgentToolFailure(
            kind: .internalError,
            detail: String(error.localizedDescription.prefix(160)),
            attempts: attempts
        )
    }
}

/// 三道计数闸，防止模型对一个坏掉的工具死磕。
///
/// `maximumAgentRounds` 只限制轮数；一轮里并行调同一个失败工具它管不着。
struct AgentToolBudget: Sendable {
    /// 同一个工具整个 run 最多失败几次，超了直接拒绝执行。
    static let failuresPerTool = 3
    /// 整个 run 的失败预算，超了下一轮停发 tools。
    static let failuresPerRun = 5

    private(set) var failuresByTool: [String: Int] = [:]
    private(set) var totalFailures = 0

    mutating func recordFailure(_ tool: String) {
        failuresByTool[tool, default: 0] += 1
        totalFailures += 1
    }

    func isExhausted(_ tool: String) -> Bool {
        (failuresByTool[tool] ?? 0) >= Self.failuresPerTool
    }

    var shouldStopOfferingTools: Bool { totalFailures >= Self.failuresPerRun }
}

/// 工具返回的长度预算由**模型窗口**推出来，不是写死的 6000 字。
///
/// 实测：`maximumAgentRounds = 4` × 并行 2 条 × 单条 3000 token ≈ 24k token 的工具返回
/// 会一直累积在 `wireMessages` 里。128k 窗口下侥幸没事，换成 32k 的模型必然 400。
struct AgentToolBudgetLimits: Equatable, Sendable {
    let totalTokens: Int
    let perCallTokens: Int

    static func resolve(
        availableInputTokens: Int,
        rounds: Int = 4,
        parallelFactor: Int = 2
    ) -> AgentToolBudgetLimits {
        let total = min(max(Int(Double(availableInputTokens) * 0.20), 1_200), 24_000)
        let slots = max(1, rounds * parallelFactor)
        let perCall = min(max(total / slots, 400), 3_000)
        return AgentToolBudgetLimits(totalTokens: total, perCallTokens: perCall)
    }

    /// token 预算换成字符上限。中英混排按 2 字/token 估，和 `ConversationContextEstimator` 同口径。
    var perCallCharacters: Int { perCallTokens * 2 }
}
