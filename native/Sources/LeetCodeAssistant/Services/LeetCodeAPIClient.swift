import Foundation
import WebKit

enum LeetCodeAPIError: LocalizedError {
    case signedOut
    case invalidResponse(String, statusCode: Int? = nil)

    var statusCode: Int? {
        switch self {
        case .signedOut: nil
        case let .invalidResponse(_, statusCode): statusCode
        }
    }

    var errorDescription: String? {
        switch self {
        case .signedOut:
            "请先在账户连接中登录 LeetCode 中国站"
        case let .invalidResponse(message, _):
            message
        }
    }
}

enum LeetCodeStatus {
    private static let acceptedDisplays: Set<String> = ["ACCEPTED", "AC", "通过", "答案正确"]

    static func isAccepted(statusCode: Int, display: String) -> Bool {
        statusCode == 10 || acceptedDisplays.contains(display.trimmingCharacters(in: .whitespacesAndNewlines).uppercased())
    }
}

enum LeetCodeJudgePolling {
    static func shouldFallbackFromV2(_ error: Error) -> Bool {
        (error as? LeetCodeAPIError)?.statusCode == 404
    }
}

struct LeetCodeJudgeProgress: Sendable, Equatable {
    enum Phase: Sendable {
        case queued
        case judging
        case syncing
        case finished
    }

    let phase: Phase
    let status: String
    let elapsed: TimeInterval
    let attempt: Int
}

struct LeetCodeJudgeResult: Sendable, Equatable {
    let kind: String
    let taskID: String
    let state: String
    let status: String
    let statusCode: Int
    let accepted: Bool
    let totalCorrect: Int
    let totalTestCases: Int
    let runtime: String
    let memory: String
    let compileError: String
    let runtimeError: String
    let input: String
    let output: String
    let expectedOutput: String
    let compareResult: String
    let aiJudgeMessage: String
}

struct LeetCodeRemoteSubmission: Sendable, Equatable {
    let id: String
    let status: String
    let language: String
    let timestamp: TimeInterval
    let title: String
    let runtime: String
    let memory: String
    let url: String
    /// 力扣自己返回的 slug。账号级同步以前靠标题反查本地题库，本地没见过的题
    /// （在浏览器里刷的、不在任何题单里的）会被整条丢掉，再也进不了分析队列。
    var titleSlug = ""
}

@MainActor
final class LeetCodeAPIClient {
    static let shared = LeetCodeAPIClient()

    private static let origin = "https://leetcode.cn"
    private static let rootReferer = "https://leetcode.cn/"
    private static let graphQLPath = "/graphql/"

    private init() {}

    func fetchWorkspace(titleSlug: String) async throws -> [String: Any] {
        let data = try await graphQL(
            query: Self.workspaceQuery,
            variables: ["titleSlug": titleSlug]
        )
        guard let question = data["question"] as? [String: Any] else {
            throw LeetCodeAPIError.invalidResponse("力扣没有返回可作答的题目")
        }
        return try normalizeWorkspace(question)
    }

    /// 题面底部操作栏要的那几个数。点赞数、题解数、提示是公开的；
    /// `isLiked` / `isFavor` 只有带上会话才有值，没登录时是 nil / false。
    func fetchQuestionMeta(titleSlug: String) async throws -> LeetCodeQuestionMeta {
        let data = try await graphQL(
            query: Self.questionMetaQuery,
            variables: ["titleSlug": titleSlug],
            requiresAuth: false
        )
        guard let question = data["question"] as? [String: Any] else {
            throw LeetCodeAPIError.invalidResponse("力扣没有返回题目信息")
        }
        return LeetCodeQuestionMeta(
            likes: question["likes"] as? Int ?? 0,
            dislikes: question["dislikes"] as? Int ?? 0,
            solutionCount: question["solutionNum"] as? Int ?? 0,
            isLiked: question["isLiked"] as? Bool,
            isFavorite: question["isFavor"] as? Bool ?? false,
            hints: (question["hints"] as? [String])?.filter { !$0.isEmpty } ?? []
        )
    }

    func fetchSolutions(
        titleSlug: String,
        first: Int = 20,
        skip: Int = 0
    ) async throws -> LeetCodeSolutionPage {
        let data = try await graphQL(
            query: Self.solutionListQuery,
            variables: ["questionSlug": titleSlug, "first": first, "skip": skip],
            requiresAuth: false
        )
        guard let root = data["questionSolutionArticles"] as? [String: Any] else {
            throw LeetCodeAPIError.invalidResponse("力扣没有返回题解列表")
        }
        let edges = root["edges"] as? [[String: Any]] ?? []
        let items = edges.compactMap { edge -> LeetCodeSolutionSummary? in
            guard let node = edge["node"] as? [String: Any],
                  let slug = node["slug"] as? String, !slug.isEmpty
            else { return nil }
            let author = node["author"] as? [String: Any]
            let profile = author?["profile"] as? [String: Any]
            return LeetCodeSolutionSummary(
                id: node["uuid"] as? String ?? slug,
                slug: slug,
                title: node["title"] as? String ?? "未命名题解",
                summary: (node["summary"] as? String ?? "").replacingOccurrences(of: "\n", with: " "),
                views: node["hitCount"] as? Int ?? 0,
                authorName: (profile?["realName"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                    ?? author?["username"] as? String ?? "",
                authorAvatar: profile?["userAvatar"] as? String ?? "",
                createdAt: node["createdAt"] as? String ?? "",
                isOfficial: (author?["username"] as? String) == "LeetCode-Solution"
            )
        }
        return LeetCodeSolutionPage(total: root["totalNum"] as? Int ?? items.count, items: items)
    }

    func fetchSolutionArticle(slug: String) async throws -> LeetCodeSolutionArticle {
        let data = try await graphQL(
            query: Self.solutionArticleQuery,
            variables: ["slug": slug],
            requiresAuth: false
        )
        guard let article = data["solutionArticle"] as? [String: Any],
              let content = article["content"] as? String, !content.isEmpty
        else {
            throw LeetCodeAPIError.invalidResponse("这篇题解暂时读不到正文")
        }
        var videos: [LeetCodeSolutionVideo] = []
        for uuid in Self.solutionVideoUUIDs(in: content) {
            if let video = try? await fetchSolutionVideoInfo(uuid: uuid) {
                videos.append(video)
            }
        }
        return LeetCodeSolutionArticle(
            slug: slug,
            title: article["title"] as? String ?? "题解",
            markdown: content,
            videos: videos
        )
    }

    func fetchSolutionVideoInfo(uuid: String) async throws -> LeetCodeSolutionVideo {
        let data = try await graphQL(
            query: Self.solutionVideoQuery,
            variables: ["uuid": uuid],
            requiresAuth: false
        )
        guard let root = data["videosVideoInfo"] as? [String: Any] else {
            throw LeetCodeAPIError.invalidResponse("力扣没有返回视频信息")
        }
        let info = root["videoInfo"] as? [String: Any] ?? [:]
        let size = root["videoSize"] as? [String: Any] ?? [:]
        return LeetCodeSolutionVideo(
            uuid: uuid,
            playAuth: root["playAuth"] as? String ?? "",
            status: root["status"] as? String ?? "",
            videoID: info["videoId"] as? String ?? "",
            coverURL: info["coverUrl"] as? String ?? "",
            width: size["width"] as? Int ?? 0,
            height: size["height"] as? Int ?? 0,
            articleChargeType: root["articleChargeType"] as? String ?? "",
            canSee: root["canSee"] as? Bool ?? false
        )
    }

    nonisolated static func solutionVideoUUIDs(in markdown: String) -> [String] {
        let pattern = #"!\[[^\]]*\]\(([0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12})\)"#
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(markdown.startIndex..<markdown.endIndex, in: markdown)
        var seen = Set<String>()
        return expression.matches(in: markdown, range: range).compactMap { match in
            guard let valueRange = Range(match.range(at: 1), in: markdown) else { return nil }
            let value = String(markdown[valueRange]).lowercased()
            return seen.insert(value).inserted ? value : nil
        }
    }

    func fetchSubmissionDetail(_ submission: LeetCodeSubmission) async throws -> [String: Any] {
        let data: [String: Any]
        do {
            data = try await graphQL(
                query: Self.submissionDetailQuery,
                variables: ["submissionId": submission.id]
            )
        } catch {
            data = try await graphQL(
                query: Self.submissionDetailFallbackQuery,
                variables: ["submissionId": submission.id]
            )
        }
        guard var detail = data["submissionDetail"] as? [String: Any] else {
            throw LeetCodeAPIError.invalidResponse("暂时无法读取这条提交的详情")
        }
        let output = detail["outputDetail"] as? [String: Any] ?? [:]
        detail.merge(output) { current, _ in current }
        detail["id"] = submission.id
        detail["titleSlug"] = (detail["question"] as? [String: Any])?["titleSlug"] ?? submission.titleSlug
        detail["runtimeDisplay"] = detail["runtime"] ?? submission.runtime
        detail["memoryDisplay"] = detail["memory"] ?? submission.memory
        detail["totalCorrect"] = detail["passedTestCaseCnt"] ?? 0
        detail["totalTestcases"] = detail["totalTestCaseCnt"] ?? 0
        return detail
    }

    func fetchSubmissions(titleSlug: String, limit: Int = 40) async throws -> [LeetCodeRemoteSubmission] {
        var values: [LeetCodeRemoteSubmission] = []
        var lastKey: String?
        let requestedLimit = min(100, max(1, limit))
        repeat {
            var variables: [String: Any] = [
                "offset": values.count,
                "limit": min(20, requestedLimit - values.count)
            ]
            if !titleSlug.isEmpty { variables["questionSlug"] = titleSlug }
            if let lastKey, !lastKey.isEmpty { variables["lastKey"] = lastKey }
            let data = try await graphQL(query: Self.submissionListQuery, variables: variables)
            guard let list = data["submissionList"] as? [String: Any] else { break }
            let page = (list["submissions"] as? [[String: Any]] ?? []).compactMap { raw -> LeetCodeRemoteSubmission? in
                let id = Self.string(raw["id"])
                guard !id.isEmpty else { return nil }
                return LeetCodeRemoteSubmission(
                    id: id,
                    status: Self.string(raw["statusDisplay"]),
                    language: Self.string(raw["lang"]),
                    timestamp: Self.double(raw["timestamp"]),
                    title: Self.string(raw["title"]),
                    runtime: Self.string(raw["runtime"]),
                    memory: Self.string(raw["memory"]),
                    url: Self.string(raw["url"]),
                    // 力扣中国的 SubmissionDumpNode 没有 titleSlug 字段，写进查询会整条报错。
                    // 按题拉取时 slug 是我们自己传进去的，直接盖上；
                    // 全账号同步（没有 slug）那条链路仍旧靠标题去匹配。
                    titleSlug: titleSlug
                )
            }
            values.append(contentsOf: page)
            lastKey = list["lastKey"] as? String
            let hasNext = list["hasNext"] as? Bool ?? false
            if !hasNext || page.isEmpty || values.count >= requestedLimit { break }
        } while values.count < requestedLimit
        return Array(values.prefix(requestedLimit))
    }

    func runCode(
        titleSlug: String,
        questionID: String,
        language: String,
        code: String,
        testCase: String,
        progress: @escaping @MainActor (LeetCodeJudgeProgress) -> Void = { _ in }
    ) async throws -> LeetCodeJudgeResult {
        let response = try await restJSON(
            path: "/problems/\(titleSlug)/interpret_solution/",
            method: "POST",
            body: [
                "lang": language,
                "question_id": questionID,
                "typed_code": code,
                "data_input": testCase,
                "interpret_id": NSNull()
            ],
            referer: Self.problemReferer(titleSlug)
        )
        let taskID = try judgeTaskID(response, kind: "run")
        progress(.init(phase: .queued, status: "已进入运行队列", elapsed: 0, attempt: 0))
        return try await pollJudge(taskID: taskID, kind: "run", useV2: false, progress: progress)
    }

    func submitCode(
        titleSlug: String,
        questionID: String,
        language: String,
        code: String,
        progress: @escaping @MainActor (LeetCodeJudgeProgress) -> Void = { _ in }
    ) async throws -> LeetCodeJudgeResult {
        let response = try await restJSON(
            path: "/problems/\(titleSlug)/submit/",
            method: "POST",
            body: ["lang": language, "question_id": questionID, "typed_code": code],
            referer: Self.problemReferer(titleSlug)
        )
        let taskID = try judgeTaskID(response, kind: "submit")
        progress(.init(phase: .queued, status: "已提交，等待判题", elapsed: 0, attempt: 0))
        let result = try await pollJudge(taskID: taskID, kind: "submit", useV2: true, progress: progress)
        progress(.init(phase: .syncing, status: "正在同步提交记录", elapsed: 0, attempt: 0))
        return result
    }

    /// - Parameter requiresAuth: 点赞数、提示、题解这些是**公开**数据，
    ///   没登录也该能看；只有提交、收藏状态这类才必须带会话。
    private func graphQL(
        query: String,
        variables: [String: Any],
        requiresAuth: Bool = true
    ) async throws -> [String: Any] {
        let cookies = await allLeetCodeCookies()
        if requiresAuth,
           !cookies.contains(where: { $0.name == "LEETCODE_SESSION" && !$0.value.isEmpty }) {
            throw LeetCodeAPIError.signedOut
        }

        guard let url = Self.endpointURL(path: Self.graphQLPath) else {
            throw LeetCodeAPIError.invalidResponse("力扣服务地址无效")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(Self.origin, forHTTPHeaderField: "Origin")
        request.setValue(Self.rootReferer, forHTTPHeaderField: "Referer")
        if let cookie = HTTPCookie.requestHeaderFields(with: cookies)["Cookie"] {
            request.setValue(cookie, forHTTPHeaderField: "Cookie")
        }
        if let csrf = cookies.first(where: { $0.name == "csrftoken" })?.value, !csrf.isEmpty {
            request.setValue(csrf, forHTTPHeaderField: "x-csrftoken")
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: ["query": query, "variables": variables])

        let (payload, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw LeetCodeAPIError.invalidResponse("力扣服务没有返回有效响应")
        }
        let object = try JSONSerialization.jsonObject(with: payload) as? [String: Any]
        if let error = (object?["errors"] as? [[String: Any]])?.first?["message"] as? String {
            throw LeetCodeAPIError.invalidResponse(error)
        }
        guard (200..<300).contains(http.statusCode), let data = object?["data"] as? [String: Any] else {
            throw LeetCodeAPIError.invalidResponse("力扣服务请求失败（\(http.statusCode)）", statusCode: http.statusCode)
        }
        return data
    }

    private func restJSON(
        path: String,
        method: String = "GET",
        body: [String: Any]? = nil,
        referer: String = LeetCodeAPIClient.rootReferer
    ) async throws -> [String: Any] {
        guard path.range(of: #"^/[a-z0-9_?=&./-]+$"#, options: [.regularExpression, .caseInsensitive]) != nil,
              let url = Self.endpointURL(path: path)
        else { throw LeetCodeAPIError.invalidResponse("力扣请求地址无效") }
        let cookies = await allLeetCodeCookies()
        guard cookies.contains(where: { $0.name == "LEETCODE_SESSION" && !$0.value.isEmpty }) else {
            throw LeetCodeAPIError.signedOut
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(Self.origin, forHTTPHeaderField: "Origin")
        request.setValue(referer, forHTTPHeaderField: "Referer")
        if let cookie = HTTPCookie.requestHeaderFields(with: cookies)["Cookie"] {
            request.setValue(cookie, forHTTPHeaderField: "Cookie")
        }
        if let csrf = cookies.first(where: { $0.name == "csrftoken" })?.value, !csrf.isEmpty {
            request.setValue(csrf, forHTTPHeaderField: "x-csrftoken")
        }
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let (payload, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw LeetCodeAPIError.invalidResponse("力扣判题服务没有返回有效响应")
        }
        let object = (try? JSONSerialization.jsonObject(with: payload) as? [String: Any]) ?? [:]
        guard (200..<300).contains(http.statusCode) else {
            let detail = Self.string(object["error"] ?? object["message"] ?? object["detail"])
            let message: String
            switch http.statusCode {
            case 401, 403: message = detail.isEmpty ? "力扣登录已失效，请重新登录" : detail
            case 429: message = "提交过于频繁，请稍后再试"
            default: message = detail.isEmpty ? "力扣判题服务请求失败（\(http.statusCode)）" : detail
            }
            throw LeetCodeAPIError.invalidResponse(message, statusCode: http.statusCode)
        }
        return object
    }

    private func pollJudge(
        taskID: String,
        kind: String,
        useV2 initialUseV2: Bool,
        progress: @escaping @MainActor (LeetCodeJudgeProgress) -> Void
    ) async throws -> LeetCodeJudgeResult {
        let start = Date.now
        var useV2 = initialUseV2
        for attempt in 0..<80 where Date.now.timeIntervalSince(start) < 90 {
            try Task.checkCancellation()
            let suffix = useV2 ? "/v2/check/" : "/check/"
            let raw: [String: Any]
            do {
                raw = try await restJSON(path: "/submissions/detail/\(taskID)\(suffix)")
            } catch {
                if useV2, LeetCodeJudgePolling.shouldFallbackFromV2(error) {
                    useV2 = false
                    continue
                }
                throw error
            }
            let state = Self.string(raw["state"]).uppercased()
            let status = Self.string(raw["status_msg"] ?? raw["statusMessage"] ?? raw["status_display"])
            let elapsed = Date.now.timeIntervalSince(start)
            if ["SUCCESS", "FAILURE", "REVOKED"].contains(state) {
                let result = normalizeJudgeResult(raw, taskID: taskID, kind: kind)
                progress(.init(phase: .finished, status: result.status, elapsed: elapsed, attempt: attempt + 1))
                return result
            }
            progress(.init(phase: .judging, status: status.isEmpty ? "力扣判题中" : status, elapsed: elapsed, attempt: attempt + 1))
            try await Task.sleep(for: .milliseconds(min(1_600, 220 + attempt * 90)))
        }
        throw LeetCodeAPIError.invalidResponse("力扣判题超时，可稍后在提交记录中查看结果")
    }

    private func judgeTaskID(_ response: [String: Any], kind: String) throws -> String {
        let nested = response["data"] as? [String: Any] ?? [:]
        let raw = response["interpret_id"] ?? response["submission_id"] ?? response["task_id"] ?? response["id"]
            ?? nested["interpret_id"] ?? nested["submission_id"] ?? nested["task_id"]
        let value = Self.string(raw)
        let pattern = kind == "run" ? #"^[a-z0-9_.-]{1,120}$"# : #"^\d+$"#
        guard value.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil else {
            let detail = Self.string(response["error"] ?? response["message"] ?? response["detail"] ?? nested["error"] ?? nested["message"])
            throw LeetCodeAPIError.invalidResponse(detail.isEmpty ? "力扣没有返回有效的\(kind == "run" ? "运行" : "提交")任务" : detail)
        }
        return value
    }

    private func normalizeJudgeResult(_ raw: [String: Any], taskID: String, kind: String) -> LeetCodeJudgeResult {
        let state = Self.string(raw["state"]).uppercased()
        let status = Self.string(raw["status_msg"] ?? raw["statusMessage"] ?? raw["status_display"])
        let statusCode = Int(Self.double(raw["status_code"]))
        let accepted = LeetCodeStatus.isAccepted(statusCode: statusCode, display: status)
        return LeetCodeJudgeResult(
            kind: kind,
            taskID: taskID,
            state: state,
            status: status.isEmpty ? (accepted ? "通过" : "判题完成") : status,
            statusCode: statusCode,
            accepted: accepted,
            totalCorrect: max(0, Int(Self.double(raw["total_correct"]))),
            totalTestCases: max(0, Int(Self.double(raw["total_testcases"]))),
            runtime: Self.string(raw["status_runtime"] ?? raw["runtime"]),
            memory: Self.string(raw["status_memory"] ?? raw["memory"]),
            compileError: Self.boundedText(raw["compile_error"] ?? raw["full_compile_error"]),
            runtimeError: Self.boundedText(raw["runtime_error"] ?? raw["full_runtime_error"]),
            input: Self.boundedText(raw["input"] ?? raw["last_testcase"]),
            output: Self.boundedText(raw["code_output"] ?? raw["std_output_list"] ?? raw["std_output"]),
            expectedOutput: Self.boundedText(raw["expected_output"]),
            compareResult: Self.boundedText(raw["compare_result"], limit: 10_000),
            aiJudgeMessage: Self.boundedText(raw["ai_judge_message"], limit: 4_000)
        )
    }

    private func allLeetCodeCookies() async -> [HTTPCookie] {
        await withCheckedContinuation { continuation in
            WKWebsiteDataStore.default().httpCookieStore.getAllCookies { cookies in
                continuation.resume(returning: cookies.filter { $0.domain.contains("leetcode.cn") })
            }
        }
    }

    private func normalizeWorkspace(_ raw: [String: Any]) throws -> [String: Any] {
        let slug = raw["titleSlug"] as? String ?? ""
        guard !slug.isEmpty, raw["questionId"] != nil else {
            throw LeetCodeAPIError.invalidResponse("力扣返回的题目数据不完整")
        }
        let snippets = (raw["codeSnippets"] as? [[String: Any]] ?? []).compactMap { snippet -> [String: Any]? in
            let languageSlug = (snippet["langSlug"] as? String ?? "").lowercased()
            let code = snippet["code"] as? String ?? ""
            guard !languageSlug.isEmpty, !code.isEmpty else { return nil }
            return [
                "lang": snippet["lang"] as? String ?? languageSlug,
                "langSlug": languageSlug,
                "code": String(code.prefix(100_000))
            ]
        }
        let examples = officialExamples(from: raw)
        let tags = (raw["topicTags"] as? [[String: Any]] ?? []).compactMap { tag -> [String: Any]? in
            let name = tag["translatedName"] as? String ?? tag["name"] as? String ?? ""
            guard !name.isEmpty else { return nil }
            return ["name": name, "slug": tag["slug"] as? String ?? ""]
        }
        let question: [String: Any] = [
            "questionId": String(describing: raw["questionId"] ?? ""),
            "frontendId": raw["questionFrontendId"] as? String ?? "",
            "title": raw["title"] as? String ?? "",
            "translatedTitle": raw["translatedTitle"] as? String ?? raw["title"] as? String ?? "",
            "titleSlug": slug,
            "difficulty": raw["difficulty"] as? String ?? "",
            "content": raw["translatedContent"] as? String ?? raw["content"] as? String ?? "",
            "paidOnly": raw["isPaidOnly"] as? Bool ?? false,
            "enableRunCode": raw["enableRunCode"] as? Bool ?? true,
            "enableSubmit": raw["enableSubmit"] as? Bool ?? true,
            "topicTags": tags,
            "exampleTestcases": examples
        ]
        return ["question": question, "snippets": snippets]
    }

    private static func string(_ value: Any?) -> String {
        if let value = value as? String { return value }
        if let value = value as? NSNumber { return value.stringValue }
        return ""
    }

    private static func double(_ value: Any?) -> Double {
        if let value = value as? NSNumber { return value.doubleValue }
        if let value = value as? String { return Double(value) ?? 0 }
        return 0
    }

    private static func boundedText(_ value: Any?, limit: Int = 50_000) -> String {
        if let value = value as? String { return String(value.prefix(limit)) }
        guard let value,
              JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted])
        else { return "" }
        return String(String(decoding: data, as: UTF8.self).prefix(limit))
    }

    private static func endpointURL(path: String) -> URL? {
        guard var components = URLComponents(string: origin) else { return nil }
        components.path = path
        return components.url
    }

    private static func problemReferer(_ titleSlug: String) -> String {
        guard titleSlug.range(of: #"^[a-z0-9][a-z0-9-]{0,99}$"#, options: [.regularExpression, .caseInsensitive]) != nil,
              let url = endpointURL(path: "/problems/\(titleSlug)/")
        else { return rootReferer }
        return url.absoluteString
    }

    private func officialExamples(from question: [String: Any]) -> [String] {
        let source = question["exampleTestcases"] as? String ?? question["sampleTestCase"] as? String ?? ""
        let lines = source.split(whereSeparator: \.isNewline).map(String.init).filter { !$0.isEmpty }
        var parameterCount = 1
        if let metadata = question["metaData"] as? String,
           let data = metadata.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           object["systemdesign"] as? Bool != true {
            parameterCount = max(1, (object["params"] as? [Any])?.count ?? 1)
        } else if let metadata = question["metaData"] as? String,
                  let data = metadata.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  object["systemdesign"] as? Bool == true {
            parameterCount = 2
        }
        return stride(from: 0, to: lines.count, by: parameterCount).map { index in
            lines[index..<min(lines.count, index + parameterCount)].joined(separator: "\n")
        }
    }

    private static let workspaceQuery = #"""
    query questionWorkspace($titleSlug: String!) {
      question(titleSlug: $titleSlug) {
        questionId questionFrontendId title titleSlug translatedTitle difficulty
        content translatedContent isPaidOnly enableRunCode enableSubmit metaData
        topicTags { name translatedName slug }
        codeSnippets { code lang langSlug }
        sampleTestCase exampleTestcases
      }
    }
    """#

    // 字段名是对着 leetcode.cn 的 /graphql/ 逐个试出来的（introspection 是关的）：
    // `solutionNum` 是题解数，`hints` 是官方提示，`isLiked`/`isFavor` 需要会话。
    // 「N 人在线」不在 GraphQL 里——那是协同编辑的实时功能，所以底部栏不做这一项。
    private static let questionMetaQuery = #"""
    query questionMeta($titleSlug: String!) {
      question(titleSlug: $titleSlug) {
        questionFrontendId likes dislikes solutionNum isLiked isFavor hints
      }
    }
    """#

    private static let solutionListQuery = #"""
    query questionSolutionArticles($questionSlug: String!, $first: Int, $skip: Int) {
      questionSolutionArticles(questionSlug: $questionSlug, first: $first, skip: $skip, orderBy: DEFAULT) {
        totalNum
        edges {
          node {
            uuid title slug summary hitCount createdAt
            author { username profile { userAvatar realName } }
          }
        }
      }
    }
    """#

    private static let solutionArticleQuery = #"""
    query solutionArticle($slug: String!) {
      solutionArticle(slug: $slug, orderBy: DEFAULT) { uuid title slug content }
    }
    """#

    private static let solutionVideoQuery = #"""
    query videoInfo($uuid: UUID!) {
      videosVideoInfo(uuid: $uuid, fetchType: PLAY_AUTH) {
        playAuth status articleChargeType canSee
        videoInfo { videoId coverUrl }
        videoSize { width height }
      }
    }
    """#

    private static let submissionDetailQuery = #"""
    query submissionDetails($submissionId: ID!) {
      submissionDetail(submissionId: $submissionId) {
        code timestamp statusDisplay runtime memory rawMemory runtimePercentile memoryPercentile lang langVerboseName aiJudgeMessage
        question { questionId titleSlug hasFrontendPreview }
        passedTestCaseCnt totalTestCaseCnt
        ... on GeneralSubmissionNode { outputDetail { runtimeError compileError lastTestcase codeOutput expectedOutput input } }
        ... on ContestSubmissionNode { outputDetail { runtimeError compileError lastTestcase codeOutput expectedOutput input } }
      }
    }
    """#

    private static let submissionDetailFallbackQuery = #"""
    query submissionDetails($submissionId: ID!) {
      submissionDetail(submissionId: $submissionId) {
        code timestamp statusDisplay runtime memory rawMemory lang langVerboseName aiJudgeMessage
        question { questionId titleSlug hasFrontendPreview }
        passedTestCaseCnt totalTestCaseCnt
        ... on GeneralSubmissionNode { outputDetail { runtimeError compileError lastTestcase codeOutput expectedOutput input } }
        ... on ContestSubmissionNode { outputDetail { runtimeError compileError lastTestcase codeOutput expectedOutput input } }
      }
    }
    """#

    private static let submissionListQuery = #"""
    query submissionList($offset: Int!, $limit: Int!, $lastKey: String, $questionSlug: String) {
      submissionList(offset: $offset, limit: $limit, lastKey: $lastKey, questionSlug: $questionSlug) {
        lastKey hasNext
        submissions { id statusDisplay lang timestamp title runtime memory url }
      }
    }
    """#
}

/// 题面底部操作栏的数据。
struct LeetCodeQuestionMeta: Equatable, Sendable {
    var likes = 0
    var dislikes = 0
    var solutionCount = 0
    /// 需要登录才有值：nil 表示未登录或力扣没返回。
    var isLiked: Bool?
    var isFavorite = false
    var hints: [String] = []

    static let empty = LeetCodeQuestionMeta()
}

struct LeetCodeSolutionSummary: Identifiable, Equatable, Sendable {
    let id: String
    let slug: String
    let title: String
    let summary: String
    let views: Int
    let authorName: String
    let authorAvatar: String
    let createdAt: String
    /// 力扣官方题解的作者账号固定是 `LeetCode-Solution`。
    var isOfficial = false
}

struct LeetCodeSolutionPage: Equatable, Sendable {
    var total = 0
    var items: [LeetCodeSolutionSummary] = []
}

struct LeetCodeSolutionArticle: Equatable, Sendable {
    let slug: String
    let title: String
    /// 力扣题解正文是 Markdown，交给 `LeetCodeSolutionWebView` 渲染。
    let markdown: String
    let videos: [LeetCodeSolutionVideo]
}

struct LeetCodeSolutionVideo: Equatable, Sendable {
    let uuid: String
    let playAuth: String
    let status: String
    let videoID: String
    let coverURL: String
    let width: Int
    let height: Int
    let articleChargeType: String
    let canSee: Bool

    var javaScriptValue: [String: Any] {
        [
            "uuid": uuid,
            "playAuth": playAuth,
            "status": status,
            "videoID": videoID,
            "coverURL": coverURL,
            "width": width,
            "height": height,
            "articleChargeType": articleChargeType,
            "canSee": canSee
        ]
    }
}
