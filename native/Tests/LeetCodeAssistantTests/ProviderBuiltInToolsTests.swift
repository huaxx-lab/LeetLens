import Foundation
import Testing
@testable import LeetCodeAssistant

@Suite("供应商内置工具")
struct ProviderBuiltInToolsTests {
    private func toolTypes(_ apiBase: String, _ model: String) -> [String] {
        ProviderBuiltInTools.tools(apiBase: apiBase, model: model).compactMap { $0["type"] as? String }
    }

    @Test("deepseek-v4-flash 不限供应商都带联网搜索")
    func deepSeekFlashGetsWebSearchAnywhere() {
        // 官方站和 OpenCode Go 这类中转都支持后端搜索，按 host 卡死会让中转用户白少一个能力。
        #expect(toolTypes("https://api.deepseek.com/v1", "deepseek-v4-flash") == ["web_search"])
        #expect(toolTypes("https://opencode.example.com/v1", "deepseek-v4-flash") == ["web_search"])
        #expect(toolTypes("https://api.deepseek.com/v1", "deepseek-v4-pro").isEmpty)
    }

    @Test("阿里云按模型给出不同工具组合")
    func alibabaToolsVaryByModel() {
        let full = toolTypes("https://dashscope.aliyuncs.com/compatible-mode/v1", "qwen3.8-max-preview")
        #expect(full == ["web_search", "web_extractor", "code_interpreter", "web_search_image"])

        let noImage = toolTypes("https://dashscope.aliyuncs.com/compatible-mode/v1", "qwen3.7-max")
        #expect(noImage == ["web_search", "web_extractor", "code_interpreter"])

        #expect(toolTypes("https://dashscope.aliyuncs.com/compatible-mode/v1", "qwen3.6-flash").isEmpty)
    }

    @Test("code_interpreter 带 container 参数")
    func codeInterpreterCarriesContainer() {
        let tools = ProviderBuiltInTools.tools(
            apiBase: "https://dashscope.aliyuncs.com/compatible-mode/v1",
            model: "qwen3.7-max"
        )
        let interpreter = tools.first { $0["type"] as? String == "code_interpreter" }
        let container = interpreter?["container"] as? [String: String]
        #expect(container?["type"] == "auto")
    }

    @Test("未知供应商不声明任何工具")
    func unknownProviderGetsNothing() {
        #expect(toolTypes("https://api.openai.com/v1", "gpt-4o").isEmpty)
        #expect(toolTypes("", "").isEmpty)
    }

    @Test("有内置工具的模型必须走 Responses 协议")
    func modelsWithToolsRequireResponses() {
        #expect(ProviderBuiltInTools.supportsResponsesAPI(apiBase: "https://opencode.example.com/v1", model: "deepseek-v4-flash"))
        #expect(ProviderBuiltInTools.supportsResponsesAPI(apiBase: "https://dashscope.aliyuncs.com/compatible-mode/v1", model: "qwen3.7-max"))
    }

    @Test("阿里云的 qwen 系列按前缀判定 Responses 支持")
    func alibabaResponsesPatterns() {
        let base = "https://dashscope.aliyuncs.com/compatible-mode/v1"
        #expect(ProviderBuiltInTools.supportsResponsesAPI(apiBase: base, model: "qwen3-max"))
        #expect(ProviderBuiltInTools.supportsResponsesAPI(apiBase: base, model: "qwen-plus"))
        #expect(ProviderBuiltInTools.supportsResponsesAPI(apiBase: base, model: "qwen3.6-flash"))
        #expect(!ProviderBuiltInTools.supportsResponsesAPI(apiBase: base, model: "llama-3"))
    }

    @Test("认得出直接形式的工具事件")
    func recognizesDirectToolEvents() {
        #expect(ProviderBuiltInTools.toolName(fromResponsesEvent: ["type": "response.web_search_call.in_progress"]) == "web_search")
        #expect(ProviderBuiltInTools.toolName(fromResponsesEvent: ["type": "response.code_interpreter_call.completed"]) == "code_interpreter")
        #expect(ProviderBuiltInTools.toolName(fromResponsesEvent: ["type": "response.web_search_image_call.searching"]) == "web_search_image")
    }

    @Test("认得出 output_item 里的工具调用")
    func recognizesOutputItemToolEvents() {
        let added: [String: Any] = [
            "type": "response.output_item.added",
            "item": ["type": "web_extractor_call", "status": "in_progress"]
        ]
        #expect(ProviderBuiltInTools.toolName(fromResponsesEvent: added) == "web_extractor")

        let done: [String: Any] = [
            "type": "response.output_item.done",
            "item": ["type": "image_search_call", "status": "completed"]
        ]
        #expect(ProviderBuiltInTools.toolName(fromResponsesEvent: done) == "image_search")
    }

    @Test("普通文本事件不会被误判成工具")
    func plainEventsAreNotTools() {
        #expect(ProviderBuiltInTools.toolName(fromResponsesEvent: ["type": "response.output_text.delta", "delta": "hi"]) == nil)
        #expect(ProviderBuiltInTools.toolName(fromResponsesEvent: ["type": "response.completed"]) == nil)
        let message: [String: Any] = [
            "type": "response.output_item.done",
            "item": ["type": "message", "status": "completed"]
        ]
        #expect(ProviderBuiltInTools.toolName(fromResponsesEvent: message) == nil)
    }

    @Test("工具事件在流解析里变成 toolCall 分片")
    func streamParserEmitsToolCall() {
        let chunks = ChatService.chunks(
            from: ["type": "response.web_search_call.in_progress"],
            eventName: "response.web_search_call.in_progress"
        )
        #expect(chunks.count == 1)
        if case .toolCall(let name) = chunks[0] {
            #expect(name == "web_search")
        } else {
            Issue.record("期望是 toolCall 分片")
        }
    }

    @Test("Responses 请求体带上工具定义")
    func requestBodyCarriesTools() {
        let body = ChatService.requestBody(
            mode: "responses",
            model: "deepseek-v4-flash",
            apiBase: "https://api.deepseek.com/v1",
            messages: [ChatRequestMessage(role: "user", content: "今天的新闻")],
            reasoningLevel: .high
        )
        let tools = body["tools"] as? [[String: Any]]
        #expect(tools?.compactMap { $0["type"] as? String } == ["web_search"])
    }

    @Test("没有内置工具时不塞空 tools 字段")
    func requestBodyOmitsEmptyTools() {
        let body = ChatService.requestBody(
            mode: "responses",
            model: "gpt-4o",
            apiBase: "https://api.openai.com/v1",
            messages: [ChatRequestMessage(role: "user", content: "hi")],
            reasoningLevel: .high
        )
        #expect(body["tools"] == nil)
    }

    @Test("Chat 协议不带工具，免得被当成自定义函数调用")
    func chatModeNeverCarriesTools() {
        let body = ChatService.requestBody(
            mode: "chat",
            model: "deepseek-v4-flash",
            apiBase: "https://api.deepseek.com/v1",
            messages: [ChatRequestMessage(role: "user", content: "hi")],
            reasoningLevel: .high
        )
        #expect(body["tools"] == nil)
    }

    @Test("auto 模式会为带工具的模型自动切到 Responses")
    func autoModeUpgradesToResponses() {
        // 原来 auto 一律落到 chat，内置工具永远用不上。
        #expect(ChatService.resolvedMode(declared: "auto", apiBase: "https://opencode.example.com/v1", model: "deepseek-v4-flash") == "responses")
        #expect(ChatService.resolvedMode(declared: "auto", apiBase: "https://api.openai.com/v1", model: "gpt-4o") == "chat")
    }

    @Test("用户显式选定的协议不被推翻")
    func explicitModeWins() {
        #expect(ChatService.resolvedMode(declared: "chat", apiBase: "https://api.deepseek.com/v1", model: "deepseek-v4-flash") == "chat")
        #expect(ChatService.resolvedMode(declared: "messages", apiBase: "https://api.anthropic.com", model: "claude") == "messages")
        #expect(ChatService.resolvedMode(declared: "responses", apiBase: "https://api.openai.com/v1", model: "gpt-4o") == "responses")
    }
}
