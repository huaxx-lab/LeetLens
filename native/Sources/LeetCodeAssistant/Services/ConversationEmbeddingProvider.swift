import Foundation
import NaturalLanguage

enum ConversationEmbeddingTextType: String, Sendable {
    case query
    case document
}

/// 向量模型边界。索引只认 identity + dimension，绝不混用不同模型空间。
protocol ConversationEmbeddingProvider: Sendable {
    var identity: String { get }
    var dimension: Int { get }
    var maximumBatchSize: Int { get }

    /// 返回顺序必须与 texts 完全一致；一项失败应让整批抛错，不能错位填向量。
    func embed(_ texts: [String], textType: ConversationEmbeddingTextType) async throws -> [[Double]]
}

/// 仅供离线退化与单元测试。生产 `LegacyDataStore` 显式传千问 provider，
/// 不再让 Apple 的 640 维中文小模型参与 hybrid 排序。
struct AppleConversationEmbeddingProvider: ConversationEmbeddingProvider, @unchecked Sendable {
    let identity: String
    let dimension: Int
    let maximumBatchSize = 64
    private let embedding: NLEmbedding?

    init?() {
        guard let embedding = NLEmbedding.sentenceEmbedding(for: .simplifiedChinese) else { return nil }
        let revision = NLEmbedding.currentSentenceEmbeddingRevision(for: .simplifiedChinese)
        self.embedding = embedding
        self.dimension = embedding.dimension
        self.identity = "apple/nlembedding/zh-hans/revision-\(revision)/d\(embedding.dimension)"
    }

    func embed(_ texts: [String], textType: ConversationEmbeddingTextType) async throws -> [[Double]] {
        guard let embedding else { throw ConversationEmbeddingError.unavailable("本机没有中文句向量模型") }
        var result: [[Double]] = []
        result.reserveCapacity(texts.count)
        for text in texts {
            try Task.checkCancellation()
            guard let vector = embedding.vector(for: text) else {
                throw ConversationEmbeddingError.invalidResponse
            }
            result.append(vector)
        }
        return result
    }
}

enum ConversationEmbeddingError: LocalizedError, Equatable {
    case invalidEndpoint
    case emptyInput
    case tooManyInputs(Int)
    case invalidResponse
    case dimensionMismatch(expected: Int, actual: Int)
    case unavailable(String)
    case server(status: Int, message: String)

    var errorDescription: String? {
        switch self {
        case .invalidEndpoint: "向量服务地址无效或不是受支持的阿里云地址"
        case .emptyInput: "向量化输入为空"
        case .tooManyInputs(let count): "一次最多向量化 20 段，当前为 \(count) 段"
        case .invalidResponse: "向量模型返回了无法识别的结果"
        case .dimensionMismatch(let expected, let actual): "向量维度不匹配：需要 \(expected)，实际 \(actual)"
        case .unavailable(let message): message
        case .server(let status, let message):
            message.isEmpty ? "向量服务请求失败（\(status)）" : "向量服务请求失败（\(status)）：\(message)"
        }
    }
}

/// 阿里云原生 DashScope `qwen3.7-text-embedding`。
/// 原生接口支持 `text_type=query/document`；OpenAI 兼容接口不公开这个检索语义开关。
final class QwenConversationEmbeddingProvider: ConversationEmbeddingProvider, @unchecked Sendable {
    let model: String
    let dimension: Int
    /// 服务端硬上限是 10：超了整批回 400 `batch size is invalid`，
    /// 而 `synchronize` 的 catch 会把整个索引退回纯 BM25——写大了等于悄悄关掉 dense 那一路。
    let maximumBatchSize = 10
    let identity: String

    private let endpoint: URL
    private let apiKey: String
    private let session: URLSession
    private let retryPolicy: RetryPolicy
    private let sleep: @Sendable (Duration) async throws -> Void

    init(
        apiBase: String,
        apiKey: String,
        model: String = "text-embedding-v4",
        dimension: Int = 1_024,
        session: URLSession = .shared,
        retryPolicy: RetryPolicy = .standard,
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) throws {
        guard let endpoint = Self.endpoint(apiBase: apiBase) else { throw ConversationEmbeddingError.invalidEndpoint }
        guard [256, 512, 768, 1_024, 1_536, 2_048, 2_560].contains(dimension) else {
            throw ConversationEmbeddingError.dimensionMismatch(expected: 1_024, actual: dimension)
        }
        self.endpoint = endpoint
        self.apiKey = apiKey
        self.model = model
        self.dimension = dimension
        self.identity = "aliyun/\(model)/native-v1/d\(dimension)"
        self.session = session
        self.retryPolicy = retryPolicy
        self.sleep = sleep
    }

    func embed(_ texts: [String], textType: ConversationEmbeddingTextType) async throws -> [[Double]] {
        guard !texts.isEmpty else { throw ConversationEmbeddingError.emptyInput }
        guard texts.count <= maximumBatchSize else { throw ConversationEmbeddingError.tooManyInputs(texts.count) }
        let body: [String: Any] = [
            "model": model,
            "input": ["texts": texts],
            "parameters": [
                "text_type": textType.rawValue,
                "dimension": dimension,
                "output_type": "dense"
            ]
        ]
        let payload = try JSONSerialization.data(withJSONObject: body)
        var attempt = 1
        while true {
            try Task.checkCancellation()
            do {
                var request = URLRequest(url: endpoint)
                request.httpMethod = "POST"
                request.timeoutInterval = 25
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
                request.httpBody = payload
                let (data, response) = try await session.data(for: request)
                guard let http = response as? HTTPURLResponse else {
                    throw ConversationEmbeddingError.invalidResponse
                }
                guard (200..<300).contains(http.statusCode) else {
                    let message = Self.serverMessage(data)
                    guard RetryPolicy.isRetryable(statusCode: http.statusCode), retryPolicy.shouldRetry(attempt: attempt) else {
                        throw ConversationEmbeddingError.server(status: http.statusCode, message: message)
                    }
                    let duration: Duration
                    if let seconds = RetryPolicy.retryAfterSeconds(http) {
                        duration = .milliseconds(Int((min(seconds, 8) * 1_000).rounded()))
                    } else {
                        duration = retryPolicy.delay(afterAttempt: attempt)
                    }
                    attempt += 1
                    try await sleep(duration)
                    continue
                }
                return try Self.decode(data, expectedCount: texts.count, dimension: dimension)
            } catch {
                if error is ConversationEmbeddingError { throw error }
                guard RetryPolicy.isRetryable(error), retryPolicy.shouldRetry(attempt: attempt) else { throw error }
                let duration = retryPolicy.delay(afterAttempt: attempt)
                attempt += 1
                try await sleep(duration)
            }
        }
    }

    static func endpoint(apiBase: String) -> URL? {
        guard let normalized = try? ProviderURLPolicy.normalize(apiBase),
              var components = URLComponents(string: normalized.apiBase),
              let host = components.host?.lowercased(),
              host == "dashscope.aliyuncs.com" || host.hasSuffix(".cn-beijing.maas.aliyuncs.com")
        else { return nil }
        components.path = "/api/v1/services/embeddings/text-embedding/text-embedding"
        components.query = nil
        components.fragment = nil
        return components.url
    }

    private static func decode(_ data: Data, expectedCount: Int, dimension: Int) throws -> [[Double]] {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let output = root["output"] as? [String: Any],
              let rows = output["embeddings"] as? [[String: Any]]
        else { throw ConversationEmbeddingError.invalidResponse }

        var vectors = [[Double]?](repeating: nil, count: expectedCount)
        for row in rows {
            guard let index = (row["text_index"] as? NSNumber)?.intValue,
                  vectors.indices.contains(index), vectors[index] == nil,
                  let numbers = row["embedding"] as? [NSNumber]
            else { throw ConversationEmbeddingError.invalidResponse }
            let vector = numbers.map(\.doubleValue)
            guard vector.count == dimension else {
                throw ConversationEmbeddingError.dimensionMismatch(expected: dimension, actual: vector.count)
            }
            vectors[index] = vector
        }
        guard vectors.allSatisfy({ $0 != nil }) else { throw ConversationEmbeddingError.invalidResponse }
        return vectors.compactMap { $0 }
    }

    private static func serverMessage(_ data: Data) -> String {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return "" }
        if let error = root["error"] as? [String: Any] {
            return String((error["message"] as? String ?? error["code"] as? String ?? "").prefix(300))
        }
        return String((root["message"] as? String ?? root["code"] as? String ?? "").prefix(300))
    }
}

/// 应用启动构造保持 O(1)：直到后台索引真正需要向量时才解析 Keychain 凭据。
actor DeferredQwenConversationEmbeddingProvider: ConversationEmbeddingProvider {
    nonisolated let identity: String
    nonisolated let dimension = 1_024
    /// 必须和 `QwenConversationEmbeddingProvider` 一致：服务端上限 10。
    nonisolated let maximumBatchSize = 10

    private let dataDirectory: URL
    private let providerID: String
    private let model: String

    init(dataDirectory: URL, providerID: String = "alibaba", model: String = "text-embedding-v4") {
        self.dataDirectory = dataDirectory
        self.providerID = providerID
        self.model = model
        self.identity = "aliyun/\(model)/native-v1/d1024"
    }

    func embed(_ texts: [String], textType: ConversationEmbeddingTextType) async throws -> [[Double]] {
        guard Self.isEnabled(dataDirectory: dataDirectory) else {
            throw ConversationEmbeddingError.unavailable("云端对话向量未开启，本轮使用本地 BM25")
        }
        let provider = try await ChatService(dataDirectory: dataDirectory)
            .makeConversationEmbeddingProvider(providerID: providerID, model: model)
        return try await provider.embed(texts, textType: textType)
    }

    static func isEnabled(dataDirectory: URL) -> Bool {
        let url = dataDirectory.appending(path: "settings.json")
        guard let data = try? Data(contentsOf: url),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let policy = root["contextPolicy"] as? [String: Any]
        else { return false }
        return policy["cloudMemoryEmbeddingEnabled"] as? Bool == true
    }
}
