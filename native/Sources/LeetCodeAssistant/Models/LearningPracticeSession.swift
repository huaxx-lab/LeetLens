import Foundation
import Observation

/// 复习页的作答草稿。
///
/// 以前 `answer` 和 `answerDrafts` 都是 `ReviewWorkspaceView` 的 `@State`，而各页面是
/// `switch` 出来的——切到刷题页再回来，视图被销毁重建，写了一半的代码就没了；
/// 连"切到别的复习项再切回来"也只在同一次视图生命周期内有效。
///
/// 和刷题页的代码草稿同一套做法：状态挪到会话对象里，并防抖落盘。
@MainActor
@Observable
final class LearningPracticeSession {
    static let fileName = "learning-drafts.json"
    static let saveDelay: Duration = .milliseconds(700)
    /// 草稿上限。按最近编辑时间淘汰，避免一年下来把文件撑大。
    static let maximumDrafts = 120

    struct Draft: Codable, Equatable {
        var answer: String
        var updatedAt: Date
    }

    struct Archive: Codable, Equatable {
        var drafts: [String: Draft] = [:]
    }

    private(set) var archive = Archive()
    @ObservationIgnored private var directory: URL?
    @ObservationIgnored private var pendingSave: Task<Void, Never>?
    @ObservationIgnored private var isDirty = false

    func attach(directory: URL) {
        guard self.directory != directory else { return }
        self.directory = directory
        let url = directory.appending(path: Self.fileName)
        guard let data = try? Data(contentsOf: url) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        if let decoded = try? decoder.decode(Archive.self, from: data) { archive = decoded }
    }

    func draft(for key: String) -> String? {
        guard !key.isEmpty else { return nil }
        return archive.drafts[key]?.answer
    }

    /// 记录一份草稿。和起始代码一致的作答不算草稿——存了它，
    /// 下次"重新生成"给出新的起始代码时反而会被旧的盖住。
    func record(answer: String, for key: String, starter: String, now: Date = .now) {
        guard !key.isEmpty else { return }
        if Self.isPristine(answer, starter: starter) {
            guard archive.drafts.removeValue(forKey: key) != nil else { return }
            scheduleSave()
            return
        }
        guard archive.drafts[key]?.answer != answer else { return }
        archive.drafts[key] = Draft(answer: answer, updatedAt: now)
        prune()
        scheduleSave()
    }

    func discard(_ key: String) {
        guard archive.drafts.removeValue(forKey: key) != nil else { return }
        scheduleSave()
    }

    /// 只比较去掉首尾空白后的内容：起始代码常带尾随换行，光标停一下不该算作改动。
    static func isPristine(_ answer: String, starter: String) -> Bool {
        answer.trimmingCharacters(in: .whitespacesAndNewlines)
            == starter.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func prune() {
        guard archive.drafts.count > Self.maximumDrafts else { return }
        let survivors = archive.drafts
            .sorted { $0.value.updatedAt > $1.value.updatedAt }
            .prefix(Self.maximumDrafts)
        archive.drafts = Dictionary(uniqueKeysWithValues: survivors.map { ($0.key, $0.value) })
    }

    private func scheduleSave() {
        isDirty = true
        pendingSave?.cancel()
        pendingSave = Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.saveDelay)
            guard !Task.isCancelled else { return }
            self?.flush()
        }
    }

    /// 写入是防抖的，**离开前台 / 退出前必须 flush**，否则最后不到一秒的输入会丢。
    func flush() {
        pendingSave?.cancel()
        pendingSave = nil
        guard isDirty, let directory else { return }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(archive) else { return }
        let url = directory.appending(path: Self.fileName)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        isDirty = false
    }
}
