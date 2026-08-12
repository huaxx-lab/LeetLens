import Foundation
import XCTest
@testable import LeetCodeAssistant

/// Deleting an active knowledge item.
///
/// The native bridge previously exposed only restore/purge/emptyTrash, so an active item
/// could never be moved to the trash from this client. Going through the canonical engine
/// is what writes the deleted snapshot, the suppression tombstone and the change log
/// together — the tombstone is what stops the item being auto-recognised again later.
final class LearningDeleteTests: XCTestCase {
    @MainActor
    private func makeStore(_ directory: URL, itemID: String) throws -> LegacyDataStore {
        let fixture: [String: Any] = [
            "schemaVersion": 3,
            "items": [
                itemID: [
                    "id": itemID,
                    "kind": "knowledge",
                    "title": "滑动窗口",
                    "summary": "维护左右指针",
                    "revision": 1,
                    "masteryScore": 40,
                    "canonicalKey": "滑动窗口",
                    "sourceRefs": [],
                    "createdAt": 1_700_000_000_000,
                    "updatedAt": 1_700_000_000_000
                ]
            ],
            "deletedItems": [:],
            "suppressedItems": [:],
            "templates": [:],
            "analysis": [:],
            "reviewLog": [],
            "changeLog": []
        ]
        try JSONSerialization.data(withJSONObject: fixture)
            .write(to: directory.appending(path: "learning.json"), options: .atomic)
        return LegacyDataStore(dataDirectory: directory)
    }

    private func learningRoot(_ directory: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: directory.appending(path: "learning.json"))
        return try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    @MainActor
    func testDeletingActiveItemWritesSnapshotTombstoneAndChangeLog() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "LearningDelete-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let itemID = "l_00000000000000a1"
        let store = try makeStore(directory, itemID: itemID)
        await store.hydrate()
        XCTAssertEqual(store.learningRecords.count, 1, "Fixture did not load an active item")
        let revisionBefore = store.activeLearningRevision

        try await store.deleteLearningRecord(itemID)

        // Gone from the active set, and the UI's derived state moved on.
        XCTAssertTrue(store.learningRecords.isEmpty, "Deleted item still active")
        XCTAssertGreaterThan(store.activeLearningRevision, revisionBefore)

        let root = try learningRoot(directory)
        let items = root["items"] as? [String: Any] ?? [:]
        let deleted = root["deletedItems"] as? [String: Any] ?? [:]
        let suppressed = root["suppressedItems"] as? [String: Any] ?? [:]
        let changeLog = root["changeLog"] as? [[String: Any]] ?? []

        XCTAssertNil(items[itemID], "Item remained in the active map")
        XCTAssertNotNil(deleted[itemID], "No deleted snapshot was written")
        XCTAssertNotNil(suppressed[itemID], "No tombstone was written — item could be re-learned")
        XCTAssertTrue(
            changeLog.contains { ($0["itemId"] as? String) == itemID },
            "Delete was not recorded in the change log"
        )
    }

    /// Emptying the trash must not remove the tombstone, or the item comes back.
    @MainActor
    func testTombstoneSurvivesEmptyingTheTrash() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "LearningTombstone-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let itemID = "l_00000000000000b2"
        let store = try makeStore(directory, itemID: itemID)
        await store.hydrate()

        try await store.deleteLearningRecord(itemID)
        try await store.emptyLearningTrash()

        let root = try learningRoot(directory)
        XCTAssertNil((root["deletedItems"] as? [String: Any])?[itemID], "Trash was not emptied")
        XCTAssertNotNil(
            (root["suppressedItems"] as? [String: Any])?[itemID],
            "Tombstone was dropped, so the item can be auto-recognised again"
        )
    }

    /// Restoring goes through the canonical engine too, so it clears suppression
    /// instead of drifting from the Electron client's semantics.
    @MainActor
    func testRestoreReturnsTheItemToTheActiveSet() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "LearningRestore-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let itemID = "l_00000000000000c3"
        let store = try makeStore(directory, itemID: itemID)
        await store.hydrate()

        try await store.deleteLearningRecord(itemID)
        XCTAssertTrue(store.learningRecords.isEmpty)

        try await store.restoreLearningRecord(itemID)

        XCTAssertEqual(store.learningRecords.map(\.id), [itemID], "Restore did not bring the item back")
        let root = try learningRoot(directory)
        XCTAssertNotNil((root["items"] as? [String: Any])?[itemID])
        XCTAssertNil((root["deletedItems"] as? [String: Any])?[itemID])
    }
}
