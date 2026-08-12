import Foundation

/// 供应商侧的**内置工具**（联网搜索、网页抓取、代码解释、图片搜索）。
///
/// 这类工具由模型在后端自己执行，客户端只负责在请求里声明 `tools`，
/// 再从 SSE 里认出「正在调用哪个工具」用于展示——我们不实现也不代跑任何工具。
///
/// 前提是走 **Responses API** 协议：Chat Completions 那条链路没有这套内置工具事件。
/// 原项目（`src/integrations/api-utils.js` 的 `nativeResponseTools` / `supportsResponsesApi`）
/// 就是这么做的，native 侧此前只送了 `input` + `reasoning`，`tools` 一直没带上，
/// 于是模型永远拿不到工具，界面上的工具徽章也就从来没亮过。
enum ProviderBuiltInTools {
    /// 后端会推事件的内置工具名。顺序无关，仅用于识别。
    static let recognizedNames = [
        "web_search",
        "web_extractor",
        "code_interpreter",
        "web_search_image",
        "image_search"
    ]

    static func isDeepSeekCompatible(apiBase: String) -> Bool {
        host(of: apiBase).hasSuffix("deepseek.com")
    }

    static func isAlibabaCompatible(apiBase: String) -> Bool {
        let host = host(of: apiBase)
        return host.hasSuffix("aliyuncs.com") || host.hasSuffix("aliyun.com")
    }

    /// 本次请求要声明的工具定义。
    ///
    /// `deepseek-v4-flash` 不限供应商：它在 DeepSeek 官方和 OpenCode Go 这类中转上
    /// 都支持后端搜索，按 host 卡死会让中转用户白白少一个能力。
    static func tools(apiBase: String, model: String) -> [[String: Any]] {
        let normalized = model.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if normalized == "deepseek-v4-flash" {
            return [["type": "web_search"]]
        }
        guard isAlibabaCompatible(apiBase: apiBase) else { return [] }
        switch normalized {
        case "qwen3.8-max-preview", "qwen3.7-plus":
            return [
                ["type": "web_search"],
                ["type": "web_extractor"],
                ["type": "code_interpreter", "container": ["type": "auto"]],
                ["type": "web_search_image"]
            ]
        case "qwen3.7-max":
            return [
                ["type": "web_search"],
                ["type": "web_extractor"],
                ["type": "code_interpreter", "container": ["type": "auto"]]
            ]
        default:
            return []
        }
    }

    /// 该供应商 + 模型是否应该走 Responses 协议。
    /// 有内置工具的一定要走——否则工具定义没地方送。
    static func supportsResponsesAPI(apiBase: String, model: String) -> Bool {
        let normalized = model.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if !tools(apiBase: apiBase, model: normalized).isEmpty { return true }
        if isDeepSeekCompatible(apiBase: apiBase) { return normalized == "deepseek-v4-flash" }
        guard isAlibabaCompatible(apiBase: apiBase) else { return false }
        if normalized == "qwen3.8-max-preview" { return true }
        let patterns = [
            "^qwen3-(?:max|coder(?:-|$))",
            "^qwen3\\.7-(?:max|plus)",
            "^qwen3\\.6-(?:flash|35b-a3b)",
            "^qwen3\\.5-(?:397b|122b|27b|35b|ocr)",
            "^qwen-(?:max|plus|flash|coder)"
        ]
        return patterns.contains { normalized.range(of: $0, options: .regularExpression) != nil }
    }

    /// 从 Responses 的 SSE 事件里认出内置工具调用。
    ///
    /// 两种形态：
    /// - `response.web_search_call.in_progress` 这类直接事件
    /// - `response.output_item.added/done`，工具名在 `item.type`（形如 `web_search_call`）
    static func toolName(fromResponsesEvent object: [String: Any]) -> String? {
        let type = (object["type"] as? String) ?? ""
        guard type.hasPrefix("response.") else { return nil }

        for name in recognizedNames where type.hasPrefix("response.\(name)_call.") {
            return name
        }

        guard type == "response.output_item.added" || type == "response.output_item.done",
              let item = object["item"] as? [String: Any],
              let itemType = item["type"] as? String
        else { return nil }
        return recognizedNames.first { itemType == "\($0)_call" }
    }

    private static func host(of apiBase: String) -> String {
        let trimmed = apiBase.trimmingCharacters(in: .whitespacesAndNewlines)
        let candidate = trimmed.contains("://") ? trimmed : "https://\(trimmed)"
        return (URL(string: candidate)?.host ?? "").lowercased()
    }
}
