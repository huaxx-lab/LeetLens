import Foundation

/// 发给模型的消息数组分三段，顺序由**缓存**决定，不是由可读性决定。
///
/// 供应商侧（DeepSeek / OpenAI / Anthropic）都是**前缀**缓存：逐字匹配，
/// 块内改一个字，本块及其后全部失效。所以规则只有一条：
/// **每轮都会变的东西必须排在最后；每 N 轮才变一次的，排在前面不吃亏。**
///
/// 旧顺序是 `[system][identity][memory][continuity][history]`，检索片段
/// （最多 4 段 × 1400 字）每轮都不同却排在第 3 位——它后面的整段历史每轮重新计费。
enum PromptAssembly {
    /// 本轮易变块的角色。
    ///
    /// 不能直接用 `system`：Anthropic 的 `messages` 协议会把所有 system 消息
    /// 合并提到**队首**，易变块会被重新顶回最前面，改了等于没改。
    static let volatileRole = "context"

    struct Sections {
        /// 逐字不变的前缀：人设、运行时身份、长期事实、会话目录。
        var stable: [ChatRequestMessage] = []
        /// 只在压缩事件变的历史。
        var history: [ChatRequestMessage] = []
        /// 每轮都不同：检索片段、宿主上下文、衔接说明。
        var volatileContext: [String] = []

        var messages: [ChatRequestMessage] {
            stable + history + volatileContext.map {
                ChatRequestMessage(role: PromptAssembly.volatileRole, content: $0)
            }
        }
    }

    /// 缓存不变量：把易变块摘掉之后，前一轮的数组必须是后一轮的**逐字前缀**
    /// （不发生压缩时）。测试用它守着，挡住以后往前缀里塞时间戳、随机 id 的改动。
    static func stablePrefix(of messages: [ChatRequestMessage]) -> [ChatRequestMessage] {
        messages.filter { $0.role != volatileRole }
    }

    static func isStablePrefix(
        _ earlier: [ChatRequestMessage],
        of later: [ChatRequestMessage]
    ) -> Bool {
        let lhs = stablePrefix(of: earlier)
        let rhs = stablePrefix(of: later)
        guard lhs.count <= rhs.count else { return false }
        return zip(lhs, rhs).allSatisfy { $0.role == $1.role && $0.content == $1.content }
    }
}
