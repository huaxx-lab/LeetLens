import CryptoKit
import Foundation

/// B 站公开视频检索（**只读**）。
///
/// 走 `x/web-interface/wbi/search/type` 搜索接口。这条链路要 WBI 签名：
/// 从 nav 接口取 `img_url` / `sub_url` 两个密钥，按固定的混淆表拼出 mixinKey，
/// 对排序后的查询串加盐做 MD5。签名算法是公开的社区共识，力扣题解页之外的
/// 视频检索没有更稳的官方入口。
///
/// Cookie 优先取应用内浏览器里的 B 站会话（用户登录过就是登录态，结果更准），
/// 没有登录态时匿名补一对 `buvid3/buvid4` 也能搜。整条链路不发任何写请求。
@MainActor
enum BilibiliAPIClient {
    private static let userAgent =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.4 Safari/605.1.15"
    private static let referer = "https://www.bilibili.com"

    /// WBI 混淆表。顺序一个字都不能动——它决定 imgKey/subKey 怎么交错成盐。
    private static let mixinKeyTable: [Int] = [
        46, 47, 18, 2, 53, 8, 23, 32, 15, 50, 10, 31, 58, 3, 45, 35,
        27, 43, 5, 49, 33, 9, 42, 19, 29, 28, 14, 39, 12, 38, 41, 13,
        37, 48, 7, 16, 24, 55, 40, 61, 26, 17, 0, 1, 60, 51, 30, 4,
        22, 25, 54, 21, 56, 59, 6, 63, 57, 62, 11, 36, 20, 34, 44, 52
    ]

    /// 检索公开视频。任何失败都返回空数组——工具层会把空当成"没搜到"，
    /// 检索这种锦上添花的能力不该把整个 ReAct 循环打崩。
    static func search(query: String) async -> [LearningAgentTools.VideoHit] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        do {
            let cookies = await ensureBuvid(WebsiteSessionStore.cookies(for: .bilibili))
            let mixinKey = try await fetchMixinKey(cookies: cookies)
            let timestamp = Int(Date.now.timeIntervalSince1970)
            var parameters: [String: String] = [
                "search_type": "video",
                "keyword": trimmed,
                "page": "1",
                "page_size": "20",
                "wts": "\(timestamp)"
            ]
            parameters["w_rid"] = signature(for: parameters, mixinKey: mixinKey)
            let queryString = parameters
                .sorted { $0.key < $1.key }
                .map { "\($0.key)=\(encode($0.value))" }
                .joined(separator: "&")
            guard let url = URL(string: "https://api.bilibili.com/x/web-interface/wbi/search/type?\(queryString)")
            else { return [] }

            var request = URLRequest(url: url)
            request.timeoutInterval = 15
            request.setValue(referer, forHTTPHeaderField: "Referer")
            request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
            if let cookieHeader = HTTPCookie.requestHeaderFields(with: cookies)["Cookie"] {
                request.setValue(cookieHeader, forHTTPHeaderField: "Cookie")
            }
            let (payload, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200,
                  let root = try JSONSerialization.jsonObject(with: payload) as? [String: Any],
                  (root["code"] as? Int) == 0,
                  let results = (root["data"] as? [String: Any])?["result"] as? [[String: Any]]
            else { return [] }

            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "zh_CN")
            formatter.dateFormat = "yyyy 年 M 月 d 日"
            return results.compactMap { item -> LearningAgentTools.VideoHit? in
                guard (item["type"] as? String) == "video",
                      let bvid = item["bvid"] as? String, !bvid.isEmpty
                else { return nil }
                let title = stripHTML(item["title"] as? String ?? "")
                guard !title.isEmpty else { return nil }
                var cover = item["pic"] as? String ?? ""
                if cover.hasPrefix("//") { cover = "https:\(cover)" }
                let publishedAt = (item["pubdate"] as? Int).map {
                    formatter.string(from: Date(timeIntervalSince1970: TimeInterval($0)))
                } ?? ""
                return LearningAgentTools.VideoHit(
                    bvid: bvid,
                    title: title,
                    description: stripHTML(item["description"] as? String ?? "").prefix(220).description,
                    author: item["author"] as? String ?? "",
                    coverURL: cover,
                    duration: item["duration"] as? String ?? "",
                    playCount: item["play"] as? Int ?? 0,
                    publishedAt: publishedAt
                )
            }
        } catch {
            NSLog("Bilibili video search failed: %@", error.localizedDescription)
            return []
        }
    }

    // MARK: - WBI 签名

    /// 匿名搜索至少要 `buvid3/buvid4`。浏览器里登录过就直接用现成 Cookie，
    /// 没有就从公开的指纹接口补一对——不写任何存储。
    private static func ensureBuvid(_ cookies: [HTTPCookie]) async -> [HTTPCookie] {
        guard !cookies.contains(where: { $0.name == "buvid3" }),
              let url = URL(string: "https://api.bilibili.com/x/frontend/finger/spi"),
              let (payload, _) = try? await URLSession.shared.data(from: url),
              let root = try? JSONSerialization.jsonObject(with: payload) as? [String: Any],
              let data = root["data"] as? [String: Any],
              let buvid3 = data["b_3"] as? String,
              let buvid4 = data["b_4"] as? String
        else { return cookies }
        var merged = cookies
        for (name, value) in [("buvid3", buvid3), ("buvid4", buvid4)] {
            guard let cookie = HTTPCookie(properties: [
                .name: name, .value: value, .domain: ".bilibili.com", .path: "/"
            ]) else { continue }
            merged.append(cookie)
        }
        return merged
    }

    private static func fetchMixinKey(cookies: [HTTPCookie]) async throws -> String {
        guard let url = URL(string: "https://api.bilibili.com/x/web-interface/nav") else {
            throw URLError(.badURL)
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        request.setValue(referer, forHTTPHeaderField: "Referer")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        if let cookieHeader = HTTPCookie.requestHeaderFields(with: cookies)["Cookie"] {
            request.setValue(cookieHeader, forHTTPHeaderField: "Cookie")
        }
        let (payload, _) = try await URLSession.shared.data(for: request)
        let root = (try? JSONSerialization.jsonObject(with: payload) as? [String: Any]) ?? [:]
        // 未登录时 code = -101，但 wbi_img 照给——所以不看 code 只看数据。
        let wbi = ((root["data"] as? [String: Any])?["wbi_img"] as? [String: Any]) ?? [:]
        let combined = key(fromAssetURL: wbi["img_url"] as? String ?? "")
            + key(fromAssetURL: wbi["sub_url"] as? String ?? "")
        let characters = Array(combined)
        guard characters.count >= 64 else { throw URLError(.cannotParseResponse) }
        return String(mixinKeyTable.prefix(32).compactMap { index in
            index < characters.count ? characters[index] : nil
        })
    }

    /// 密钥藏在资源 URL 的文件名里（不含扩展名）。
    private static func key(fromAssetURL value: String) -> String {
        let name = URL(string: value)?.lastPathComponent ?? value
        return name.replacingOccurrences(of: #"\..*$"#, with: "", options: .regularExpression)
    }

    /// 签名串：参数按 key 排序、WBI 转义后拼接，末尾加 mixinKey 做 MD5。
    /// 注意参与签名的 value 用的是 B 站自己的转义口径（encode），
    /// 与实际请求 URL 用的编码一致，否则服务端验签不过。
    private static func signature(for parameters: [String: String], mixinKey: String) -> String {
        let joined = parameters
            .sorted { $0.key < $1.key }
            .map { "\($0.key)=\(encode($0.value))" }
            .joined(separator: "&")
        return md5Hex(joined + mixinKey)
    }

    /// B 站的 WBI 转义比 RFC3986 还严：`!'()*` 也要编码。
    /// 只放行非保留字符里的 `-_.~`，其余全部百分号化。
    private static func encode(_ value: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-_.~")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }

    /// WBI 规定用 MD5——这里不是安全场景，只是接口签名；
    /// CryptoKit 的 `Insecure.MD5` 正是为这类遗留摘要准备的。
    private static func md5Hex(_ value: String) -> String {
        let digest = Insecure.MD5.hash(data: Data(value.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// 搜索结果的标题里带着 `<em class="keyword">` 高亮标签，展示前剥掉。
    private static func stripHTML(_ value: String) -> String {
        value
            .replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&amp;", with: "&")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
