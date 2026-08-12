import Foundation

/// 各供应商的模型列表缓存。
///
/// 原来这份列表是 `ComposerView` 的 `@State`：视图一重建就没了，
/// 于是**每次打开聊天界面都要把三家供应商的 /models 重拉一遍**——既慢又白费请求。
/// 现在提到全局并落盘，冷启动直接用上次的结果；要更新走菜单里的「刷新全部模型」。
@MainActor
@Observable
final class ModelCatalog {
    static let shared = ModelCatalog()

    private(set) var modelsByProvider: [String: [String]] = [:]
    private(set) var loadingProviderIDs: Set<String> = []
    private(set) var lastRefreshedAt: Date?

    @ObservationIgnored private var storageURL: URL?
    @ObservationIgnored private var didLoadFromDisk = false

    func models(for providerID: String) -> [String] {
        modelsByProvider[providerID] ?? []
    }

    var isLoading: Bool { !loadingProviderIDs.isEmpty }

    /// 从磁盘恢复。只做一次，后续调用直接返回。
    func restore(dataDirectory: URL) {
        guard !didLoadFromDisk else { return }
        didLoadFromDisk = true
        let url = dataDirectory.appendingPathComponent("model-catalog.json")
        storageURL = url
        guard
            let data = try? Data(contentsOf: url),
            let payload = try? JSONDecoder().decode(Payload.self, from: data)
        else { return }
        modelsByProvider = payload.modelsByProvider
        lastRefreshedAt = payload.refreshedAt
    }

    /// 只补还没有缓存的供应商——新加一家供应商时不用手动刷新全部。
    func loadMissing(providerIDs: [String], using fetch: @escaping (String) async throws -> [String]) async {
        let missing = providerIDs.filter { modelsByProvider[$0] == nil }
        guard !missing.isEmpty else { return }
        await load(providerIDs: missing, using: fetch)
    }

    /// 「刷新全部模型」走这里，无条件重拉。
    func refresh(providerIDs: [String], using fetch: @escaping (String) async throws -> [String]) async {
        await load(providerIDs: providerIDs, using: fetch)
    }

    /// 供应商被删掉后清掉它的缓存，免得列表里留着幽灵条目。
    func prune(keeping providerIDs: Set<String>) {
        let stale = modelsByProvider.keys.filter { !providerIDs.contains($0) }
        guard !stale.isEmpty else { return }
        for id in stale { modelsByProvider.removeValue(forKey: id) }
        persist()
    }

    private func load(providerIDs: [String], using fetch: @escaping (String) async throws -> [String]) async {
        for id in providerIDs {
            loadingProviderIDs.insert(id)
            defer { loadingProviderIDs.remove(id) }
            do {
                modelsByProvider[id] = try await fetch(id)
            } catch is CancellationError {
                // 视图被拆掉导致的取消不该把缓存写成空列表——保留上一次的结果。
                continue
            } catch {
                // 拉不到就记成空数组：区分"没拉过"(nil) 和"拉过但没有"(空)，
                // 后者不再反复重试，用户可以手动刷新。
                if modelsByProvider[id] == nil { modelsByProvider[id] = [] }
            }
        }
        lastRefreshedAt = .now
        persist()
    }

    private func persist() {
        guard let storageURL else { return }
        let payload = Payload(modelsByProvider: modelsByProvider, refreshedAt: lastRefreshedAt)
        guard let data = try? JSONEncoder().encode(payload) else { return }
        try? data.write(to: storageURL, options: .atomic)
    }

    private struct Payload: Codable {
        var modelsByProvider: [String: [String]]
        var refreshedAt: Date?
    }
}
