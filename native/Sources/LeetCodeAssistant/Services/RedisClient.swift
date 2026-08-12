import Darwin
import Foundation

/// Minimal RESP client for the caches that genuinely benefit from Redis.
///
/// Scope is deliberate: analysis results, submission details and usage counters — hot,
/// small, reconstructible values shared between the Electron and native clients. Bulk
/// state (conversations, learning.json) and embeddings live elsewhere.
///
/// Never a dependency: every call is deadline-bounded, failures return nothing and trip
/// a short circuit breaker, and callers fall back to their existing local path.
struct RedisConfiguration: Sendable {
    let host: String
    let port: UInt16
    let password: String?
    let keyPrefix: String
    let timeout: TimeInterval

    static func resolve() -> RedisConfiguration? {
        let environment = ProcessInfo.processInfo.environment
        if let host = environment["LEETCODE_REDIS_HOST"], !host.isEmpty {
            return RedisConfiguration(
                host: host,
                port: UInt16(environment["LEETCODE_REDIS_PORT"] ?? "") ?? 6379,
                password: environment["LEETCODE_REDIS_PASSWORD"].flatMap { $0.isEmpty ? nil : $0 },
                keyPrefix: environment["LEETCODE_REDIS_PREFIX"] ?? "lca:",
                timeout: 2
            )
        }
        guard let directory = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else { return nil }
        let url = directory.appending(path: "leetcode-ai-helper/data/redis.json")
        guard let data = try? Data(contentsOf: url),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let host = root["host"] as? String,
              !host.isEmpty,
              (root["enabled"] as? Bool) != false
        else { return nil }
        return RedisConfiguration(
            host: host,
            port: UInt16((root["port"] as? NSNumber)?.intValue ?? 6379),
            password: (root["password"] as? String).flatMap { $0.isEmpty ? nil : $0 },
            keyPrefix: root["keyPrefix"] as? String ?? "lca:",
            timeout: (root["timeoutSeconds"] as? NSNumber)?.doubleValue ?? 2
        )
    }
}

actor RedisClient {
    /// A stable process-wide instance lets Settings replace the connection at runtime.
    /// Keeping the actor alive also means callers never need to retain a stale client.
    static let shared = RedisClient(configuration: RedisConfiguration.resolve())

    private var configuration: RedisConfiguration?
    private var suspendedUntil: Date?

    init(configuration: RedisConfiguration?) {
        self.configuration = configuration
    }

    var isAvailable: Bool {
        guard configuration != nil else { return false }
        guard let suspendedUntil else { return true }
        return suspendedUntil <= .now
    }

    func reconfigure(_ configuration: RedisConfiguration?) {
        self.configuration = configuration
        suspendedUntil = nil
    }

    func ping() async -> Bool {
        guard case .simple(let value)? = await run(["PING"]) else { return false }
        return value == "PONG"
    }

    // MARK: - Commands

    func get(_ key: String) async -> Data? {
        guard case .bulk(let data)? = await run(["GET", prefixed(key)]) else { return nil }
        return data
    }

    func setValue(_ value: Data, for key: String, ttl: TimeInterval) async {
        _ = await run(["SET", prefixed(key)], binary: [value], trailing: ["EX", String(Int(ttl.rounded()))])
    }

    /// Returns true when this caller acquired the lock. Used to coalesce in-flight work.
    func acquireLock(_ key: String, ttl: TimeInterval) async -> Bool {
        guard configuration != nil else { return true }
        let reply = await run(["SET", prefixed(key), "1", "NX", "EX", String(Int(ttl.rounded()))])
        if case .simple(let text)? = reply { return text == "OK" }
        return false
    }

    func releaseLock(_ key: String) async {
        _ = await run(["DEL", prefixed(key)])
    }

    func exists(_ key: String) async -> Bool {
        if case .integer(let count)? = await run(["EXISTS", prefixed(key)]) { return count > 0 }
        return false
    }

    /// O(1) counter increments; replaces rewriting an aggregate file per request.
    func incrementCounters(_ increments: [(key: String, field: String, by: Int)], ttl: TimeInterval?) async {
        guard !increments.isEmpty else { return }
        var payload = Data()
        for increment in increments where increment.by != 0 {
            payload.append(RESP.array([
                "HINCRBY", prefixed(increment.key), increment.field, String(increment.by)
            ]))
        }
        guard !payload.isEmpty else { return }
        var expected = increments.filter { $0.by != 0 }.count
        if let ttl {
            for key in Set(increments.map(\.key)) {
                payload.append(RESP.array(["EXPIRE", prefixed(key), String(Int(ttl.rounded()))]))
                expected += 1
            }
        }
        _ = await send(payload, expectedReplies: expected)
    }

    func counters(_ key: String) async -> [String: Int] {
        guard case .array(let values)? = await run(["HGETALL", prefixed(key)]) else { return [:] }
        var result: [String: Int] = [:]
        var index = values.startIndex
        while index + 1 < values.endIndex {
            if case .bulk(let field) = values[index], let field,
               case .bulk(let amount) = values[index + 1], let amount,
               let count = Int(String(decoding: amount, as: UTF8.self)) {
                result[String(decoding: field, as: UTF8.self)] = count
            }
            index += 2
        }
        return result
    }

    // MARK: - Plumbing

    private func prefixed(_ key: String) -> String {
        (configuration?.keyPrefix ?? "lca:") + key
    }

    private func run(
        _ arguments: [String],
        binary: [Data] = [],
        trailing: [String] = []
    ) async -> RESP.Value? {
        let parts = arguments.map { Data($0.utf8) } + binary + trailing.map { Data($0.utf8) }
        return await send(RESP.arrayData(parts), expectedReplies: 1)
    }

    private func send(_ payload: Data, expectedReplies: Int) async -> RESP.Value? {
        guard isAvailable, expectedReplies > 0, let configuration else { return nil }
        var request = Data()
        if let password = configuration.password {
            request.append(RESP.array(["AUTH", password]))
        }
        request.append(payload)
        let authReplies = configuration.password == nil ? 0 : 1

        do {
            let replies = try RedisConnection.exchange(
                host: configuration.host,
                port: configuration.port,
                payload: request,
                expectedReplies: authReplies + expectedReplies,
                timeout: configuration.timeout
            )
            guard replies.count > authReplies else { return suspendAndFail() }
            if authReplies == 1, case .error = replies[0] { return suspendAndFail() }
            if case .error(let message) = replies[authReplies] {
                NSLog("Redis command failed: %@", message)
                return nil
            }
            return replies[authReplies]
        } catch {
            return suspendAndFail()
        }
    }

    private func suspendAndFail() -> RESP.Value? {
        suspendedUntil = Date.now.addingTimeInterval(120)
        return nil
    }
}

/// RESP encoding/decoding. Only the verbs these caches need.
enum RESP {
    enum Value: Equatable {
        case simple(String)
        case error(String)
        case integer(Int)
        case bulk(Data?)
        case array([Value])
    }

    static func array(_ arguments: [String]) -> Data {
        arrayData(arguments.map { Data($0.utf8) })
    }

    static func arrayData(_ arguments: [Data]) -> Data {
        var data = Data("*\(arguments.count)\r\n".utf8)
        for argument in arguments {
            data.append(Data("$\(argument.count)\r\n".utf8))
            data.append(argument)
            data.append(Data("\r\n".utf8))
        }
        return data
    }

    /// Returns nil when `buffer` does not yet hold a complete reply.
    static func parse(_ buffer: Data, from start: Data.Index) -> (Value, Data.Index)? {
        guard start < buffer.endIndex, let lineEnd = lineTerminator(in: buffer, from: start) else { return nil }
        let marker = buffer[start]
        let payload = String(decoding: buffer[(start + 1)..<lineEnd], as: UTF8.self)
        let next = lineEnd + 2

        switch marker {
        case UInt8(ascii: "+"): return (.simple(payload), next)
        case UInt8(ascii: "-"): return (.error(payload), next)
        case UInt8(ascii: ":"): return (.integer(Int(payload) ?? 0), next)
        case UInt8(ascii: "$"):
            guard let length = Int(payload) else { return nil }
            if length < 0 { return (.bulk(nil), next) }
            let end = next + length
            guard buffer.endIndex >= end + 2 else { return nil }
            return (.bulk(Data(buffer[next..<end])), end + 2)
        case UInt8(ascii: "*"):
            guard let count = Int(payload) else { return nil }
            if count < 0 { return (.array([]), next) }
            var values: [Value] = []
            var cursor = next
            for _ in 0..<count {
                guard let (value, moved) = parse(buffer, from: cursor) else { return nil }
                values.append(value)
                cursor = moved
            }
            return (.array(values), cursor)
        default:
            return nil
        }
    }

    private static func lineTerminator(in buffer: Data, from start: Data.Index) -> Data.Index? {
        var index = start
        while index + 1 < buffer.endIndex {
            if buffer[index] == UInt8(ascii: "\r"), buffer[index + 1] == UInt8(ascii: "\n") { return index }
            index += 1
        }
        return nil
    }
}

/// One-shot blocking exchange. Called from an actor, so it never touches the main thread.
private enum RedisConnection {
    enum Failure: Error { case unreachable, closed, timedOut }

    static func exchange(
        host: String,
        port: UInt16,
        payload: Data,
        expectedReplies: Int,
        timeout: TimeInterval
    ) throws -> [RESP.Value] {
        let descriptor = try connect(host: host, port: port, timeout: timeout)
        defer { Darwin.close(descriptor) }

        var offset = 0
        try payload.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            while offset < payload.count {
                let written = Darwin.send(descriptor, base.advanced(by: offset), payload.count - offset, 0)
                guard written > 0 else { throw Failure.closed }
                offset += written
            }
        }

        var buffer = Data()
        var parsed: [RESP.Value] = []
        var chunk = [UInt8](repeating: 0, count: 65_536)
        while parsed.count < expectedReplies {
            let received = recv(descriptor, &chunk, chunk.count, 0)
            if received > 0 {
                buffer.append(contentsOf: chunk[0..<received])
                var cursor = buffer.startIndex
                while parsed.count < expectedReplies, let (value, moved) = RESP.parse(buffer, from: cursor) {
                    parsed.append(value)
                    cursor = moved
                }
                if cursor > buffer.startIndex { buffer = Data(buffer[cursor...]) }
                continue
            }
            if received == 0 { throw Failure.closed }
            if errno == EAGAIN || errno == EWOULDBLOCK { throw Failure.timedOut }
            throw Failure.closed
        }
        return parsed
    }

    private static func connect(host: String, port: UInt16, timeout: TimeInterval) throws -> Int32 {
        var hints = addrinfo(
            ai_flags: 0, ai_family: AF_UNSPEC, ai_socktype: SOCK_STREAM, ai_protocol: IPPROTO_TCP,
            ai_addrlen: 0, ai_canonname: nil, ai_addr: nil, ai_next: nil
        )
        var info: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, String(port), &hints, &info) == 0, let resolved = info else {
            throw Failure.unreachable
        }
        defer { freeaddrinfo(info) }

        var candidate = resolved
        while true {
            let descriptor = socket(
                candidate.pointee.ai_family, candidate.pointee.ai_socktype, candidate.pointee.ai_protocol
            )
            if descriptor >= 0 {
                var limit = timeval(
                    tv_sec: Int(timeout),
                    tv_usec: Int32((timeout - Double(Int(timeout))) * 1_000_000)
                )
                setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &limit, socklen_t(MemoryLayout<timeval>.size))
                setsockopt(descriptor, SOL_SOCKET, SO_SNDTIMEO, &limit, socklen_t(MemoryLayout<timeval>.size))
                var one: Int32 = 1
                setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
                if Darwin.connect(descriptor, candidate.pointee.ai_addr, candidate.pointee.ai_addrlen) == 0 {
                    return descriptor
                }
                Darwin.close(descriptor)
            }
            guard let next = candidate.pointee.ai_next else { throw Failure.unreachable }
            candidate = next
        }
    }
}
