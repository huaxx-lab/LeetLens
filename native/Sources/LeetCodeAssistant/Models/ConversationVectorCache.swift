import CryptoKit
import Foundation

/// Persistent, content-addressed storage for conversation chunk embeddings.
///
/// Rebuilding every vector on launch was pure waste: a chunk whose text has not
/// changed always produces the same vector for the same embedding revision. Keying on
/// `hash(revision + text)` makes reuse exact, makes edits cost only the chunks that
/// actually changed, and makes deletions a matter of not referencing a key any more.
protocol ConversationVectorStore: Sendable {
    /// Returns whichever of `keys` the store knows about. Missing keys are simply absent.
    func load(keys: Set<String>) async -> [String: [Double]]
    /// Persists newly computed vectors. Best effort — a failure must not break indexing.
    func save(_ vectors: [String: [Double]]) async
}

enum ConversationVectorKey {
    /// Content address for one chunk.
    ///
    /// The embedding revision is part of the key so an OS model update invalidates old
    /// vectors instead of silently mixing incompatible vector spaces.
    static func make(text: String, embeddingRevision: Int) -> String {
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
        var hasher = SHA256()
        hasher.update(data: Data("v1|\(embeddingRevision)|".utf8))
        hasher.update(data: Data(normalized.utf8))
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

/// File-backed vector store in the app data directory.
///
/// This is the authoritative store: it must work with no network, so the index can
/// always be rebuilt incrementally offline. Remote stores sit in front of it as a
/// shared cache, never as a dependency.
actor LocalVectorStore: ConversationVectorStore {
    private let fileURL: URL
    private var cache: [String: [Double]]?
    private var isDirty = false

    init(dataDirectory: URL) {
        fileURL = dataDirectory.appending(path: "rag-vectors.json")
    }

    private func loadedCache() -> [String: [Double]] {
        if let cache { return cache }
        let loaded: [String: [Double]]
        if let data = try? Data(contentsOf: fileURL),
           let decoded = try? JSONDecoder().decode(StoredPayload.self, from: data) {
            loaded = decoded.vectors
        } else {
            loaded = [:]
        }
        cache = loaded
        return loaded
    }

    func load(keys: Set<String>) async -> [String: [Double]] {
        let all = loadedCache()
        return all.filter { keys.contains($0.key) }
    }

    func save(_ vectors: [String: [Double]]) async {
        guard !vectors.isEmpty else { return }
        var all = loadedCache()
        for (key, vector) in vectors { all[key] = vector }
        cache = all
        isDirty = true
        flush()
    }

    /// Drops entries no longer referenced by any live chunk, so deleting conversations
    /// eventually reclaims their vectors instead of growing the file forever.
    func retain(keys: Set<String>) async {
        let all = loadedCache()
        let retained = all.filter { keys.contains($0.key) }
        guard retained.count != all.count else { return }
        cache = retained
        isDirty = true
        flush()
    }

    func count() async -> Int { loadedCache().count }

    private func flush() {
        guard isDirty, let cache else { return }
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let data = try JSONEncoder().encode(StoredPayload(vectors: cache))
            try data.write(to: fileURL, options: .atomic)
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: fileURL.path
            )
            isDirty = false
        } catch {
            // A cache that cannot persist still works in memory for this session.
            NSLog("Vector cache write failed: %@", error.localizedDescription)
        }
    }

    private struct StoredPayload: Codable {
        let vectors: [String: [Double]]
    }
}

/// Two-tier read-through store.
///
/// - `local`: on-disk file, the offline authority. Always consulted first.
/// - `durable`: PostgreSQL + pgvector, the shared system of record for embeddings.
///
/// The database tier is an accelerator, never a dependency: calls are bounded and any
/// failure degrades to local-only behaviour. Nothing here is on the first-window or
/// send path.
struct LayeredVectorStore: ConversationVectorStore {
    let local: LocalVectorStore
    let durable: (any ConversationVectorStore)?

    func load(keys: Set<String>) async -> [String: [Double]] {
        var found = await local.load(keys: keys)
        let missing = keys.subtracting(found.keys)
        guard !missing.isEmpty, let durable else { return found }

        let stored = await durable.load(keys: missing)
        guard !stored.isEmpty else { return found }
        // Promote database hits locally so the next launch needs no network at all.
        await local.save(stored)
        for (key, vector) in stored { found[key] = vector }
        return found
    }

    func save(_ vectors: [String: [Double]]) async {
        await local.save(vectors)
        await durable?.save(vectors)
    }

    /// Garbage-collects both tiers against the complete live key set.
    func retain(keys: Set<String>) async {
        await local.retain(keys: keys)
        if let durable = durable as? PostgresVectorStore {
            await durable.retain(keys: keys)
        }
    }
}
