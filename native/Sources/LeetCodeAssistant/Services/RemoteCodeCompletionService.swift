import Darwin
import Foundation

struct RemoteCompletionConfiguration: Sendable, Equatable {
    let host: String
    let user: String
    let sshPort: Int
    let targetPort: Int
    let identityFile: String?

    /// Reads the environment first, then `lsp.json` in the data directory.
    ///
    /// Environment variables alone are unusable for a GUI app: an app launched from
    /// Finder or the Dock inherits none of a shell's exports, so `host` stayed empty and
    /// completion silently reported itself unconfigured no matter what the server was
    /// doing. The file is the same escape hatch the other remote services use.
    init(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        dataDirectory: URL? = nil
    ) {
        let file = Self.fileSettings(dataDirectory: dataDirectory)

        let rawHost = Self.value("LEETCODE_LSP_SSH_HOST", environment, file, "host")
        host = rawHost.range(of: #"^[a-z0-9.-]+$"#, options: [.regularExpression, .caseInsensitive]) == nil ? "" : rawHost
        let rawUser = Self.value("LEETCODE_LSP_SSH_USER", environment, file, "user")
        user = rawUser.range(of: #"^[a-z_][a-z0-9_-]{0,31}$"#, options: [.regularExpression, .caseInsensitive]) == nil
            ? "leetcode-lsp"
            : rawUser
        sshPort = Self.validPort(
            environment["LEETCODE_LSP_SSH_PORT"] ?? Self.number(file, "sshPort"),
            fallback: 22
        )
        targetPort = Self.validPort(
            environment["LEETCODE_LSP_TARGET_PORT"] ?? Self.number(file, "targetPort"),
            fallback: 9_092
        )
        var path = Self.value("LEETCODE_LSP_SSH_IDENTITY_FILE", environment, file, "identityFile")
        // `~/.ssh/id_ed25519` is how people actually write this; expand it rather than
        // silently dropping the key and falling back to agent-only auth.
        if path.hasPrefix("~") {
            path = NSString(string: path).expandingTildeInPath
        }
        identityFile = path.hasPrefix("/") ? path : nil
    }

    private static func value(
        _ key: String,
        _ environment: [String: String],
        _ file: [String: Any],
        _ fileKey: String
    ) -> String {
        let fromEnvironment = environment[key, default: ""].trimmingCharacters(in: .whitespacesAndNewlines)
        if !fromEnvironment.isEmpty { return fromEnvironment }
        return (file[fileKey] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func number(_ file: [String: Any], _ key: String) -> String? {
        (file[key] as? NSNumber).map { String($0.intValue) }
    }

    private static func fileSettings(dataDirectory: URL?) -> [String: Any] {
        let directory = dataDirectory ?? FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first?.appending(path: "leetcode-ai-helper/data", directoryHint: .isDirectory)
        guard let url = directory?.appending(path: "lsp.json"),
              let data = try? Data(contentsOf: url),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              (root["enabled"] as? Bool) != false
        else { return [:] }
        return root
    }

    var isConfigured: Bool { !host.isEmpty }

    private static func validPort(_ raw: String?, fallback: Int) -> Int {
        guard let value = raw.flatMap(Int.init), (1...65_535).contains(value) else { return fallback }
        return value
    }
}

struct RemoteCompletionItem: Codable, Hashable, Sendable {
    let label: String
    let insertText: String
    let detail: String
    let kind: Int
    let sortText: String
}

struct RemoteCompletionResponse: Sendable {
    let engine: String
    let items: [RemoteCompletionItem]
}

enum RemoteCompletionError: LocalizedError {
    case unavailable(String)
    case invalidRequest(String)

    var errorDescription: String? {
        switch self {
        case .unavailable(let message), .invalidRequest(let message): message
        }
    }
}

actor RemoteCodeCompletionService {
    static let shared = RemoteCodeCompletionService()

    nonisolated private let configuration: RemoteCompletionConfiguration
    private var tunnel: RemoteSSHTunnel?
    private var tunnelTask: Task<RemoteSSHTunnel, Error>?
    private var activeRequests = 0
    private var cache: [String: CacheEntry] = [:]

    private struct CacheEntry: Sendable {
        let response: RemoteCompletionResponse
        let expires: Date
    }

    init(configuration: RemoteCompletionConfiguration = .init()) {
        self.configuration = configuration
    }

    nonisolated var isConfigured: Bool { configuration.isConfigured }

    func complete(code: String, line: Int, character: Int, language: String) async throws -> RemoteCompletionResponse {
        guard configuration.isConfigured else { throw RemoteCompletionError.unavailable("远程 Java 补全未配置") }
        guard language.lowercased() == "java" else { throw RemoteCompletionError.invalidRequest("远程语义补全仅支持 Java") }
        guard !code.isEmpty, code.utf8.count <= 192 * 1_024 else {
            throw RemoteCompletionError.invalidRequest("代码为空或超出远程补全长度限制")
        }
        let lines = code.split(separator: "\n", omittingEmptySubsequences: false)
        guard lines.indices.contains(line), character >= 0, character <= lines[line].utf16.count else {
            throw RemoteCompletionError.invalidRequest("补全光标位置无效")
        }
        // 同一光标位置的重复请求（弹层重开、回退再进）直接命中缓存，
        // 省掉 SSH 隧道往返；代码或位置一变 key 就变，不会返回陈旧结果。
        let cacheKey = "\(language)|\(line)|\(character)|\(code.hashValue)"
        if let entry = cache[cacheKey], entry.expires > Date.now {
            return entry.response
        }

        guard activeRequests < 2 else { throw RemoteCompletionError.unavailable("远程补全正在处理上一次请求") }
        activeRequests += 1
        defer { activeRequests = max(0, activeRequests - 1) }

        let tunnel = try await ensureTunnel()
        do {
            let body = try JSONEncoder().encode(CompletionRequest(language: "java", code: code, line: line, character: character))
            let payload = try await Self.requestJSON(port: tunnel.port, path: "/complete", method: "POST", body: body, timeout: 14)
            guard payload.statusCode == 200 else {
                throw RemoteCompletionError.unavailable(payload.message.isEmpty ? "远程 Java 补全暂不可用" : payload.message)
            }
            let response = RemoteCompletionResponse(
                engine: payload.engine.isEmpty ? "eclipse-jdt-ls" : String(payload.engine.prefix(80)),
                items: Self.normalizedItems(payload.items)
            )
            cache[cacheKey] = CacheEntry(response: response, expires: Date.now.addingTimeInterval(30))
            if cache.count > 160 {
                cache = cache.filter { $0.value.expires > Date.now }
            }
            return response
        } catch {
            if error is URLError { stopTunnel() }
            throw error
        }
    }

    private func ensureTunnel() async throws -> RemoteSSHTunnel {
        if let tunnel, tunnel.process.isRunning { return tunnel }
        if let tunnelTask { return try await tunnelTask.value }
        let task = Task { try await RemoteSSHTunnel.start(configuration: configuration) }
        tunnelTask = task
        do {
            let value = try await task.value
            tunnel = value
            tunnelTask = nil
            return value
        } catch {
            tunnelTask = nil
            throw error
        }
    }

    private func stopTunnel() {
        tunnelTask?.cancel()
        tunnelTask = nil
        tunnel?.stop()
        tunnel = nil
    }

    private static func normalizedItems(_ values: [CompletionPayload.Item]) -> [RemoteCompletionItem] {
        var seen = Set<String>()
        return values.compactMap { item in
            let label = String(item.label.trimmingCharacters(in: .whitespacesAndNewlines).prefix(180))
            let insertText = String((item.insertText.isEmpty ? label : item.insertText).prefix(500))
            let key = "\(label)\u{0}\(insertText)"
            guard !label.isEmpty, !insertText.isEmpty, seen.insert(key).inserted else { return nil }
            return RemoteCompletionItem(
                label: label,
                insertText: insertText,
                detail: String(item.detail.prefix(240)),
                kind: item.kind,
                sortText: String(item.sortText.prefix(80))
            )
        }
        .prefix(120)
        .map { $0 }
    }

    fileprivate static func requestJSON(
        port: Int,
        path: String,
        method: String = "GET",
        body: Data? = nil,
        timeout: TimeInterval
    ) async throws -> CompletionPayload {
        guard let url = URL(string: "http://127.0.0.1:\(port)\(path)") else {
            throw RemoteCompletionError.unavailable("本地补全隧道地址无效")
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout
        let (data, response) = try await URLSession(configuration: configuration).data(for: request)
        guard data.count <= 512 * 1_024 else { throw RemoteCompletionError.unavailable("远程补全响应过大") }
        var payload = try JSONDecoder().decode(CompletionPayload.self, from: data)
        payload.statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
        return payload
    }

    private struct CompletionRequest: Encodable {
        let language: String
        let code: String
        let line: Int
        let character: Int
    }

    /// Decoded LSP response.
    ///
    /// Hand-written `init(from:)` on purpose. Swift's synthesised `Decodable` requires
    /// every key even when the property has a default, so the old version demanded a
    /// `statusCode` field that the server never sends — it is assigned by the client
    /// *after* decoding. Every single response therefore failed with `keyNotFound`, the
    /// `try?` at the call site swallowed it, and the tunnel looked like it had timed out
    /// no matter how healthy the server was.
    fileprivate struct CompletionPayload: Decodable {
        struct Item: Decodable {
            var label = ""
            var insertText = ""
            var detail = ""
            var kind = 0
            var sortText = ""

            private enum CodingKeys: String, CodingKey {
                case label, insertText, detail, kind, sortText
            }

            init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                label = try container.decodeIfPresent(String.self, forKey: .label) ?? ""
                insertText = try container.decodeIfPresent(String.self, forKey: .insertText) ?? ""
                detail = try container.decodeIfPresent(String.self, forKey: .detail) ?? ""
                kind = try container.decodeIfPresent(Int.self, forKey: .kind) ?? 0
                sortText = try container.decodeIfPresent(String.self, forKey: .sortText) ?? ""
            }
        }

        /// Filled in by the client from the HTTP response, never sent by the server.
        var statusCode = 0
        var ok = false
        var engine = ""
        var items: [Item] = []
        var detail = ""
        var error = ""
        var message: String { detail.isEmpty ? error : detail }

        private enum CodingKeys: String, CodingKey {
            case ok, engine, items, detail, error
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            ok = try container.decodeIfPresent(Bool.self, forKey: .ok) ?? false
            engine = try container.decodeIfPresent(String.self, forKey: .engine) ?? ""
            items = try container.decodeIfPresent([Item].self, forKey: .items) ?? []
            detail = try container.decodeIfPresent(String.self, forKey: .detail) ?? ""
            error = try container.decodeIfPresent(String.self, forKey: .error) ?? ""
        }
    }
}

private final class RemoteSSHTunnel: @unchecked Sendable {
    let process: Process
    let port: Int
    private let errorPipe: Pipe

    private init(process: Process, port: Int, errorPipe: Pipe) {
        self.process = process
        self.port = port
        self.errorPipe = errorPipe
    }

    static func start(configuration: RemoteCompletionConfiguration) async throws -> RemoteSSHTunnel {
        let port = try allocateLoopbackPort()
        let process = Process()
        let errorPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        var arguments = [
            "-T", "-N", "-p", String(configuration.sshPort),
            "-o", "BatchMode=yes", "-o", "ConnectTimeout=5", "-o", "ConnectionAttempts=1",
            "-o", "ExitOnForwardFailure=yes", "-o", "ServerAliveInterval=20", "-o", "ServerAliveCountMax=2",
            "-o", "StrictHostKeyChecking=accept-new", "-o", "LogLevel=ERROR",
            "-L", "127.0.0.1:\(port):127.0.0.1:\(configuration.targetPort)"
        ]
        if let identityFile = configuration.identityFile { arguments += ["-i", identityFile] }
        arguments.append("\(configuration.user)@\(configuration.host)")
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = errorPipe
        // ssh's own diagnostics are the only way to tell "wrong key" from "port in use"
        // from "host unreachable". Discarding them made every failure look identical.
        errorPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { NSLog("SSH completion tunnel: %@", text) }
        }
        try process.run()
        let tunnel = RemoteSSHTunnel(process: process, port: port, errorPipe: errorPipe)
        do {
            // A real SSH handshake to a remote host takes several seconds — key exchange
            // plus auth plus port-forward setup. The old 3.5s budget expired mid-handshake
            // on any non-LAN server, so the tunnel was torn down just before it came up
            // and completion reported "timed out" while the server was perfectly healthy.
            let deadline = Date.now.addingTimeInterval(20)
            while Date.now < deadline {
                try Task.checkCancellation()
                guard process.isRunning else { throw RemoteCompletionError.unavailable("SSH 补全隧道已退出") }
                if let payload = try? await RemoteCodeCompletionService.requestJSON(
                    port: port,
                    path: "/health",
                    timeout: 1.5
                ), payload.statusCode == 200, payload.ok {
                    return tunnel
                }
                try await Task.sleep(for: .milliseconds(200))
            }
            throw RemoteCompletionError.unavailable("SSH 补全隧道连接超时")
        } catch {
            tunnel.stop()
            throw error
        }
    }

    func stop() {
        errorPipe.fileHandleForReading.readabilityHandler = nil
        if process.isRunning { process.terminate() }
    }

    deinit { stop() }

    private static func allocateLoopbackPort() throws -> Int {
        let descriptor = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw RemoteCompletionError.unavailable("无法创建本地补全端口") }
        defer { Darwin.close(descriptor) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        let bindResult = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0 else { throw RemoteCompletionError.unavailable("无法分配本地补全端口") }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let nameResult = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.getsockname(descriptor, $0, &length)
            }
        }
        guard nameResult == 0 else { throw RemoteCompletionError.unavailable("无法读取本地补全端口") }
        return Int(UInt16(bigEndian: address.sin_port))
    }
}
