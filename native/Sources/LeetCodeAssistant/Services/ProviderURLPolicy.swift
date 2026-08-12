import Foundation

/// Canonical Provider Base URL rules, mirroring `src/integrations/provider-settings.js`.
///
/// The native client previously only trimmed whitespace, so it accepted remote `http://`,
/// URLs carrying credentials, and pasted generation endpoints. Every one of those sends
/// an `Authorization` / `x-api-key` header somewhere the user did not intend — over
/// plaintext, or to a host embedded in the URL's userinfo. Both clients write the same
/// `settings.json`, so they must agree on exactly one normal form.
enum ProviderURLPolicy {
    struct Normalized: Equatable, Sendable {
        let apiBase: String
        /// Set when the user pasted a generation endpoint rather than an API root.
        let endpointHint: String
    }

    enum Failure: LocalizedError, Equatable {
        case invalidURL
        case unsupportedScheme
        case insecureRemote
        case embeddedCredentials
        case queryOrFragment
        case endpointEscapesBase

        var errorDescription: String? {
            switch self {
            case .invalidURL: "API Base URL 格式无效"
            case .unsupportedScheme: "API Base URL 仅支持 HTTP/HTTPS"
            case .insecureRemote: "远程 API Base URL 必须使用 HTTPS"
            case .embeddedCredentials: "API Base URL 不能包含账号或密码"
            case .queryOrFragment: "API Base URL 不能包含查询参数或片段"
            case .endpointEscapesBase: "API 端点不能离开 Base URL"
            }
        }
    }

    /// Plaintext HTTP is only ever acceptable to the local machine.
    static func isLoopback(_ hostname: String) -> Bool {
        var normalized = hostname.trimmingCharacters(in: .whitespaces).lowercased()
        if normalized.hasPrefix("["), normalized.hasSuffix("]") {
            normalized = String(normalized.dropFirst().dropLast())
        }
        if normalized == "localhost" || normalized == "::1" { return true }
        let parts = normalized.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4, parts[0] == "127" else { return false }
        return parts.allSatisfy { part in
            guard !part.isEmpty, part.count <= 3, part.allSatisfy(\.isNumber) else { return false }
            return (Int(part) ?? 256) <= 255
        }
    }

    /// Converts an SDK base URL *or* a pasted generation endpoint back to its API root.
    ///
    /// Provider-specific path segments (for example Aliyun's `compatible-mode/v1`) are
    /// deliberately preserved — unknown providers must not be forced onto `/v1`.
    static func normalize(_ value: String) throws -> Normalized {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              var components = URLComponents(string: trimmed),
              let scheme = components.scheme?.lowercased(),
              let host = components.host,
              !host.isEmpty
        else { throw Failure.invalidURL }

        guard ["http", "https"].contains(scheme) else { throw Failure.unsupportedScheme }
        if scheme == "http", !isLoopback(host) { throw Failure.insecureRemote }
        if components.user != nil || components.password != nil { throw Failure.embeddedCredentials }
        if components.query != nil || components.fragment != nil { throw Failure.queryOrFragment }

        var path = components.path
        while path.contains("//") { path = path.replacingOccurrences(of: "//", with: "/") }
        while path.hasSuffix("/") { path.removeLast() }

        var endpointHint = ""
        for (suffix, hint) in [("/chat/completions", "chat"), ("/responses", "responses"), ("/messages", "messages")] {
            guard path.lowercased().hasSuffix(suffix) else { continue }
            path = String(path.dropLast(suffix.count))
            endpointHint = hint
            break
        }

        components.scheme = scheme
        components.path = path
        guard let url = components.url else { throw Failure.invalidURL }
        var apiBase = url.absoluteString
        while apiBase.hasSuffix("/") { apiBase.removeLast() }
        return Normalized(apiBase: apiBase, endpointHint: endpointHint)
    }

    /// Resolves model metadata endpoints from the same validated base used for generation.
    ///
    /// Provider-specific paths such as `/compatible-mode/v1` stay intact. A root API base
    /// may additionally try `/v1/models`, but callers must only use that fallback after a
    /// 404/405; auth and transport failures must never trigger a second credentialed guess.
    static func modelEndpoints(base: String) throws -> [URL] {
        let normalized = try normalize(base)
        guard var components = URLComponents(string: normalized.apiBase) else {
            throw Failure.invalidURL
        }
        var path = components.path
        while path.hasSuffix("/") { path.removeLast() }

        var candidates: [URL] = []
        components.path = path + "/models"
        if let url = components.url {
            try assertContained(url, in: normalized.apiBase)
            candidates.append(url)
        }
        if path.isEmpty {
            components.path = "/v1/models"
            if let url = components.url {
                try assertContained(url, in: normalized.apiBase)
                candidates.append(url)
            }
        }
        guard !candidates.isEmpty else { throw Failure.invalidURL }
        return candidates
    }

    /// Resolves the request URL for a mode and re-checks it against the base.
    ///
    /// Applied at request time as well as at save time: settings.json is shared with the
    /// Electron client and can be edited by hand, so a value that never passed through
    /// `normalize` must still not be able to redirect a key somewhere else.
    static func endpoint(base: String, mode: String) throws -> URL {
        let normalized = try normalize(base)
        let suffix = switch mode {
        case "responses": "/responses"
        case "messages": "/messages"
        default: "/chat/completions"
        }
        guard let url = URL(string: normalized.apiBase + suffix) else { throw Failure.invalidURL }

        try assertContained(url, in: normalized.apiBase)
        return url
    }

    private static func assertContained(_ url: URL, in normalizedBase: String) throws {
        // Containment: the resolved URL must stay on the base's origin and path.
        guard let resolved = URLComponents(string: url.absoluteString),
              let baseComponents = URLComponents(string: normalizedBase),
              resolved.scheme == baseComponents.scheme,
              resolved.host == baseComponents.host,
              resolved.port == baseComponents.port,
              resolved.path.hasPrefix(baseComponents.path)
        else { throw Failure.endpointEscapesBase }
    }
}
