import Foundation
import Observation

enum BrowserLinkTarget: String, CaseIterable, Identifiable {
    case inApp
    case systemBrowser

    var id: String { rawValue }
    var title: String {
        switch self {
        case .inApp: "内置浏览器"
        case .systemBrowser: "系统默认浏览器"
        }
    }
}

@MainActor
@Observable
final class BrowserPreferences {
    static let shared = BrowserPreferences()

    private enum Key {
        static let linkTarget = "browser.preferences.link-target"
        static let restoresSession = "browser.preferences.restore-session"
        static let asksWhereToSaveDownloads = "browser.preferences.ask-download-location"
        static let downloadDirectory = "browser.preferences.download-directory"
    }

    @ObservationIgnored private let defaults: UserDefaults

    var linkTarget: BrowserLinkTarget {
        didSet { defaults.set(linkTarget.rawValue, forKey: Key.linkTarget) }
    }
    var restoresSession: Bool {
        didSet { defaults.set(restoresSession, forKey: Key.restoresSession) }
    }
    var asksWhereToSaveDownloads: Bool {
        didSet { defaults.set(asksWhereToSaveDownloads, forKey: Key.asksWhereToSaveDownloads) }
    }
    var downloadDirectory: URL {
        didSet { defaults.set(downloadDirectory.path, forKey: Key.downloadDirectory) }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        linkTarget = BrowserLinkTarget(rawValue: defaults.string(forKey: Key.linkTarget) ?? "") ?? .inApp
        restoresSession = defaults.object(forKey: Key.restoresSession) as? Bool ?? true
        asksWhereToSaveDownloads = defaults.object(forKey: Key.asksWhereToSaveDownloads) as? Bool ?? true
        let defaultDirectory = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appending(path: "Downloads", directoryHint: .isDirectory)
        let storedDirectory = defaults.string(forKey: Key.downloadDirectory).flatMap {
            $0.isEmpty ? nil : URL(fileURLWithPath: $0, isDirectory: true)
        }
        downloadDirectory = storedDirectory ?? defaultDirectory
    }
}

struct BrowserHistoryEntry: Codable, Identifiable, Equatable, Hashable {
    let id: UUID
    let url: URL
    let title: String
    let visitedAt: Date
}

struct BrowserHistoryStore: Equatable {
    private(set) var entries: [BrowserHistoryEntry]
    let maximumEntries: Int

    init(entries: [BrowserHistoryEntry] = [], maximumEntries: Int = 500) {
        self.maximumEntries = max(1, maximumEntries)
        self.entries = Array(entries.prefix(max(1, maximumEntries)))
    }

    mutating func record(url: URL, title: String, visitedAt: Date = .now) {
        entries.removeAll { $0.url == url }
        let fallback = url.host ?? url.absoluteString
        let normalizedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        entries.insert(
            BrowserHistoryEntry(
                id: UUID(),
                url: url,
                title: normalizedTitle.isEmpty ? fallback : normalizedTitle,
                visitedAt: visitedAt
            ),
            at: 0
        )
        if entries.count > maximumEntries {
            entries.removeLast(entries.count - maximumEntries)
        }
    }

    mutating func remove(id: UUID) {
        entries.removeAll { $0.id == id }
    }

    mutating func removeAll() {
        entries.removeAll(keepingCapacity: false)
    }
}
