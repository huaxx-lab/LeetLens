import XCTest
@testable import LeetCodeAssistant

final class ProviderCredentialCacheTests: XCTestCase {
    func testCacheIsScopedByProviderAndSettingsRevision() async throws {
        let cache = ProviderCredentialCache()
        let counter = CredentialLoadCounter()
        let firstRevision = ProviderCredentialCache.Revision(modifiedAt: 1, fileSize: 10, fileIdentifier: 100)
        let secondRevision = ProviderCredentialCache.Revision(modifiedAt: 2, fileSize: 10, fileIdentifier: 101)

        let first = try await cache.value(
            settingsPath: "/tmp/settings.json",
            providerID: "provider-a",
            revision: firstRevision
        ) { await counter.next(prefix: "a") }
        let cached = try await cache.value(
            settingsPath: "/tmp/settings.json",
            providerID: "provider-a",
            revision: firstRevision
        ) { await counter.next(prefix: "a") }
        let otherProvider = try await cache.value(
            settingsPath: "/tmp/settings.json",
            providerID: "provider-b",
            revision: firstRevision
        ) { await counter.next(prefix: "b") }
        let changedSettings = try await cache.value(
            settingsPath: "/tmp/settings.json",
            providerID: "provider-a",
            revision: secondRevision
        ) { await counter.next(prefix: "a") }

        XCTAssertEqual(first, "a-1")
        XCTAssertEqual(cached, first)
        XCTAssertEqual(otherProvider, "b-2")
        XCTAssertEqual(changedSettings, "a-3")
        let loadCount = await counter.count
        XCTAssertEqual(loadCount, 3)
    }
}

private actor CredentialLoadCounter {
    private(set) var count = 0

    func next(prefix: String) -> String {
        count += 1
        return "\(prefix)-\(count)"
    }
}
