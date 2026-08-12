import Foundation
import WebKit

enum WebsiteSessionSite: String, CaseIterable, Identifiable, Sendable {
    case leetcode
    case bilibili

    var id: String { rawValue }
    var title: String { self == .leetcode ? "LeetCode 中国站" : "哔哩哔哩" }
    var domain: String { self == .leetcode ? "leetcode.cn" : "bilibili.com" }

    func isAuthenticated(cookieNames: Set<String>) -> Bool {
        switch self {
        case .leetcode: cookieNames.contains("LEETCODE_SESSION") && cookieNames.contains("csrftoken")
        case .bilibili: cookieNames.contains("SESSDATA") && cookieNames.contains("DedeUserID")
        }
    }
}

@MainActor
enum WebsiteSessionStore {
    static func authenticationStates() async -> [WebsiteSessionSite: Bool] {
        let cookies = await allCookies()
        return Dictionary(uniqueKeysWithValues: WebsiteSessionSite.allCases.map { site in
            let names = Set(cookies.filter { $0.domain.contains(site.domain) }.map(\.name))
            return (site, site.isAuthenticated(cookieNames: names))
        })
    }

    static func clear(_ site: WebsiteSessionSite) async {
        let store = WKWebsiteDataStore.default()
        let cookies = await allCookies()
        for cookie in cookies where cookie.domain.contains(site.domain) {
            await withCheckedContinuation { continuation in
                store.httpCookieStore.delete(cookie) { continuation.resume() }
            }
        }
        let types = WKWebsiteDataStore.allWebsiteDataTypes()
        let records = await withCheckedContinuation { continuation in
            store.fetchDataRecords(ofTypes: types) { continuation.resume(returning: $0) }
        }
        let matching = records.filter { $0.displayName.localizedCaseInsensitiveContains(site.domain) }
        guard !matching.isEmpty else { return }
        await withCheckedContinuation { continuation in
            store.removeData(ofTypes: types, for: matching) { continuation.resume() }
        }
    }

    static func cookies(for site: WebsiteSessionSite) async -> [HTTPCookie] {
        await allCookies().filter { $0.domain.contains(site.domain) }
    }

    private static func allCookies() async -> [HTTPCookie] {
        await withCheckedContinuation { continuation in
            WKWebsiteDataStore.default().httpCookieStore.getAllCookies { continuation.resume(returning: $0) }
        }
    }
}
