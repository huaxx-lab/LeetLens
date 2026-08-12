import Foundation
import Observation

@MainActor
@Observable
final class ProviderSettingsModel {
    struct Status: Equatable {
        enum Kind: Equatable { case info, success, error }
        let kind: Kind
        let text: String
    }

    let dataStore: LegacyDataStore

    private(set) var selectedProviderID: String?
    private(set) var availableModels: [String] = []
    private(set) var isFetchingModels = false
    private(set) var isTestingConnection = false
    private(set) var status: Status?
    var pendingDeleteID: String?

    var nameDraft = "" { didSet { draftDidChange() } }
    var apiBaseDraft = "" { didSet { draftDidChange() } }
    var modelDraft = "" { didSet { draftDidChange() } }
    var apiKeyDraft = "" { didSet { draftDidChange() } }
    var responseMode = "自动" { didSet { draftDidChange() } }

    @ObservationIgnored private var isLoadingDraft = false
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private var modelFetchTask: Task<Void, Never>?
    @ObservationIgnored private var connectionTestTask: Task<Void, Never>?
    @ObservationIgnored private var statusResetTask: Task<Void, Never>?

    init(dataStore: LegacyDataStore) {
        self.dataStore = dataStore
        let activeProviderID = dataStore.settings.activeProviderID
        selectedProviderID = dataStore.providers.first { $0.id == activeProviderID }?.id
            ?? dataStore.providers.first?.id
        syncDrafts(from: selectedProviderID)
    }

    var selectedProvider: ProviderRecord? {
        guard let selectedProviderID else { return nil }
        return dataStore.providers.first { $0.id == selectedProviderID }
    }

    var pendingDeleteProvider: ProviderRecord? {
        dataStore.providers.first { $0.id == pendingDeleteID }
    }

    var apiBaseIssue: String? {
        let trimmed = apiBaseDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        do {
            _ = try ProviderURLPolicy.normalize(trimmed)
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    var isDirty: Bool {
        guard let provider = selectedProvider else { return false }
        if !apiKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return true }
        return apiBaseDraft != provider.apiBase
            || modelDraft != provider.model
            || persistedMode != provider.mode
            || (canRename && nameDraft != provider.name)
    }

    /// 内置三家不能改名：名字和图标资源绑在一起，改了就对不上。
    var canRename: Bool { selectedProvider?.assetName == nil }

    var persistedMode: String {
        switch responseMode {
        case "Chat Completions": "chat"
        case "Responses": "responses"
        default: "auto"
        }
    }

    func select(_ id: String) {
        guard dataStore.providers.contains(where: { $0.id == id }) else { return }
        flushSave()
        modelFetchTask?.cancel()
        connectionTestTask?.cancel()
        isFetchingModels = false
        isTestingConnection = false
        availableModels = []
        status = nil
        selectedProviderID = id
        syncDrafts(from: id)
    }

    func storeDidChange() {
        let currentID = selectedProviderID
        let selectedStillExists = dataStore.providers.contains { $0.id == currentID }
        if selectedStillExists, isDirty { return }
        let resolvedID = selectedStillExists
            ? currentID
            : dataStore.providers.first { $0.id == dataStore.settings.activeProviderID }?.id
                ?? dataStore.providers.first?.id
        if resolvedID != currentID {
            saveTask?.cancel()
            saveTask = nil
            modelFetchTask?.cancel()
            connectionTestTask?.cancel()
            isFetchingModels = false
            isTestingConnection = false
            availableModels = []
            status = nil
            selectedProviderID = resolvedID
        }
        syncDrafts(from: resolvedID)
    }

    func addProvider() {
        flushSave()
        do {
            let id = try dataStore.addProvider()
            select(id)
            showStatus(Status(kind: .success, text: "已添加自定义供应商"))
        } catch {
            showStatus(Status(kind: .error, text: "添加失败：\(error.localizedDescription)"))
        }
    }

    func requestDelete(_ id: String) {
        guard dataStore.providers.first(where: { $0.id == id })?.assetName == nil else { return }
        pendingDeleteID = id
    }

    func confirmDelete() {
        guard let id = pendingDeleteID else { return }
        pendingDeleteID = nil
        flushSave()
        do {
            try dataStore.deleteProvider(id)
            storeDidChange()
            showStatus(Status(kind: .success, text: "自定义供应商已删除"))
        } catch {
            showStatus(Status(kind: .error, text: "删除失败：\(error.localizedDescription)"))
        }
    }

    func activate(_ id: String) {
        flushSave()
        do {
            try dataStore.activateProvider(id)
            showStatus(Status(kind: .success, text: "已设为默认供应商"))
        } catch {
            showStatus(Status(kind: .error, text: error.localizedDescription))
        }
    }

    func saveRoute(_ key: String, providerID: String?) {
        do {
            if let providerID,
               !dataStore.providers.contains(where: { $0.id == providerID && $0.isConfigured }) {
                showStatus(Status(kind: .error, text: "路由保存失败：供应商尚未完成配置"))
                return
            }
            try dataStore.saveTaskRoute(key, providerID: providerID)
            showStatus(Status(kind: .success, text: "任务路由已保存"))
        } catch {
            showStatus(Status(kind: .error, text: "路由保存失败：\(error.localizedDescription)"))
        }
    }

    func fetchModels() {
        guard let providerID = selectedProvider?.id else { return }
        flushSave()
        modelFetchTask?.cancel()
        isFetchingModels = true
        showStatus(Status(kind: .info, text: "正在获取模型..."))
        modelFetchTask = Task { [weak self] in
            guard let self else { return }
            defer { if !Task.isCancelled { self.isFetchingModels = false } }
            do {
                let models = try await ChatService(dataDirectory: self.dataStore.dataDirectory)
                    .listModels(providerID: providerID)
                try Task.checkCancellation()
                guard self.selectedProvider?.id == providerID else { return }
                self.availableModels = models
                if !models.contains(self.modelDraft), let first = models.first {
                    self.modelDraft = first
                }
                self.showStatus(Status(
                    kind: models.isEmpty ? .info : .success,
                    text: models.isEmpty ? "服务端没有返回模型" : "获取成功，共 \(models.count) 个模型"
                ))
            } catch is CancellationError {
            } catch {
                guard self.selectedProvider?.id == providerID else { return }
                self.showStatus(Status(kind: .error, text: "获取失败：\(error.localizedDescription)"))
            }
        }
    }

    func testConnection() {
        guard let providerID = selectedProvider?.id else { return }
        flushSave()
        connectionTestTask?.cancel()
        isTestingConnection = true
        showStatus(Status(kind: .info, text: "正在测试连接..."))
        connectionTestTask = Task { [weak self] in
            guard let self else { return }
            defer { if !Task.isCancelled { self.isTestingConnection = false } }
            do {
                let models = try await ChatService(dataDirectory: self.dataStore.dataDirectory)
                    .listModels(providerID: providerID)
                try Task.checkCancellation()
                guard self.selectedProvider?.id == providerID else { return }
                self.showStatus(Status(kind: .success, text: "连接成功，服务端可用模型 \(models.count) 个"))
            } catch is CancellationError {
            } catch {
                guard self.selectedProvider?.id == providerID else { return }
                self.showStatus(Status(kind: .error, text: "连接失败：\(error.localizedDescription)"))
            }
        }
    }

    func teardown() {
        saveTask?.cancel()
        saveTask = nil
        modelFetchTask?.cancel()
        connectionTestTask?.cancel()
        statusResetTask?.cancel()
        persist(showSuccess: false)
    }

    private func draftDidChange() {
        guard !isLoadingDraft else { return }
        scheduleSave()
    }

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            self?.persist(showSuccess: false)
        }
    }

    private func flushSave() {
        guard saveTask != nil else { return }
        saveTask?.cancel()
        persist(showSuccess: false)
    }

    private func persist(showSuccess: Bool) {
        saveTask = nil
        guard let provider = selectedProvider, isDirty else { return }
        guard apiBaseIssue == nil else { return }
        do {
            try dataStore.saveProvider(
                id: provider.id,
                apiBase: apiBaseDraft,
                apiKey: apiKeyDraft,
                model: modelDraft,
                mode: persistedMode
            )
            let name = nameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
            if canRename, !name.isEmpty, name != provider.name {
                try dataStore.renameProvider(provider.id, to: name)
            }
            syncDrafts(from: provider.id)
            if showSuccess { showStatus(Status(kind: .success, text: "已安全保存")) }
        } catch {
            showStatus(Status(kind: .error, text: "保存失败：\(error.localizedDescription)"))
        }
    }

    private func syncDrafts(from id: String?) {
        guard let id,
              let provider = dataStore.providers.first(where: { $0.id == id })
        else {
            isLoadingDraft = true
            nameDraft = ""
            apiBaseDraft = ""
            modelDraft = ""
            apiKeyDraft = ""
            responseMode = "自动"
            isLoadingDraft = false
            return
        }
        isLoadingDraft = true
        nameDraft = provider.name
        apiBaseDraft = provider.apiBase
        modelDraft = provider.model
        apiKeyDraft = ""
        responseMode = switch provider.mode {
        case "chat": "Chat Completions"
        case "responses": "Responses"
        default: "自动"
        }
        isLoadingDraft = false
    }

    private func showStatus(_ value: Status) {
        statusResetTask?.cancel()
        status = value
        guard value.kind != .error else { return }
        statusResetTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(2600))
            guard !Task.isCancelled else { return }
            self?.status = nil
        }
    }
}
