import Foundation

/// 外部请求的指数退避。纯值类型，延迟序列可测。
///
/// 只重试"再试一次可能就好了"的错误：限流、网关抖动、连接断掉。
/// 4xx（除 408/429）是请求本身有问题，重试多少次都一样，还白花钱。
struct RetryPolicy: Equatable, Sendable {
    /// 首次尝试也算在内：3 表示最多发 3 次请求。
    var maximumAttempts = 3
    var baseSeconds = 0.4
    var factor = 2.0
    var capSeconds = 4.0
    /// 抖动比例。多个请求同时失败时不要在同一毫秒一起重来。
    var jitter = 0.25

    static let standard = RetryPolicy()

    /// 第 `attempt` 次失败后要等多久（attempt 从 1 起算）。
    func delay(afterAttempt attempt: Int, randomness: Double = .random(in: 0...1)) -> Duration {
        let exponential = baseSeconds * pow(factor, Double(max(0, attempt - 1)))
        let bounded = min(exponential, capSeconds)
        let spread = bounded * jitter
        let seconds = max(0, bounded - spread + 2 * spread * min(max(randomness, 0), 1))
        return .milliseconds(Int((seconds * 1_000).rounded()))
    }

    func shouldRetry(attempt: Int) -> Bool { attempt < maximumAttempts }

    /// 服务端说了等多久就等多久——它比我们清楚。
    static func retryAfterSeconds(_ response: HTTPURLResponse) -> Double? {
        guard let value = response.value(forHTTPHeaderField: "Retry-After") else { return nil }
        if let seconds = Double(value.trimmingCharacters(in: .whitespaces)) { return max(0, seconds) }
        return nil
    }

    static func isRetryable(statusCode: Int) -> Bool {
        statusCode == 408 || statusCode == 429 || (500...599).contains(statusCode)
    }

    /// 取消永远不重试——用户已经不想要这个结果了。
    static func isRetryable(_ error: Error) -> Bool {
        if error is CancellationError { return false }
        guard let urlError = error as? URLError else { return false }
        switch urlError.code {
        case .timedOut, .networkConnectionLost, .cannotConnectToHost,
             .cannotFindHost, .dnsLookupFailed, .notConnectedToInternet,
             .resourceUnavailable, .badServerResponse:
            return true
        default:
            return false
        }
    }
}
