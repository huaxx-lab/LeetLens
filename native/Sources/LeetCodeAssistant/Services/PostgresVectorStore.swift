import Foundation

/// Durable vector storage in PostgreSQL + pgvector.
///
/// This is the shared system of record for embeddings; Redis in front of it is a hot
/// cache, and the local file remains the offline authority. Apple's Simplified Chinese
/// sentence embedding is 640-dimensional, so this owns its own table rather than reusing
/// a `vector_store` table dimensioned for a different model.
actor PostgresVectorStore: ConversationVectorStore {
    /// Stable so a Settings save can replace the backing database without rebuilding
    /// every conversation/index owner that already references this actor.
    static let shared = PostgresVectorStore(configuration: PostgresVectorConfiguration.resolve())

    static let vectorDimension = 640

    private var configuration: PostgresVectorConfiguration?
    private var didPrepareSchema = false
    /// Failures suspend the layer briefly; an unreachable database must never slow
    /// indexing down on every sync.
    private var suspendedUntil: Date?

    init(configuration: PostgresVectorConfiguration?) {
        self.configuration = configuration
    }

    func reconfigure(_ configuration: PostgresVectorConfiguration?) {
        self.configuration = configuration
        didPrepareSchema = false
        suspendedUntil = nil
    }

    func testConnection() throws {
        guard let configuration else {
            throw InfrastructureConfigurationError.disabled("PostgreSQL / pgvector")
        }
        let connection = PostgresConnection(configuration: configuration.connection)
        try connection.connect()
        defer { connection.close() }
        try prepareSchema(connection, configuration: configuration)
        _ = try connection.query("SELECT 1;")
    }

    func load(keys: Set<String>) async -> [String: [Double]] {
        let safeKeys = keys.filter(Self.isSafeKey)
        guard let configuration, !safeKeys.isEmpty, !isSuspended else { return [:] }
        let list = safeKeys.map { "'\($0)'" }.joined(separator: ",")
        let sql = """
        SELECT chunk_key, embedding::text FROM \(configuration.table) \
        WHERE model_revision = \(configuration.modelRevision) AND chunk_key IN (\(list));
        """
        guard let result = run(sql) else { return [:] }

        var vectors: [String: [Double]] = [:]
        for row in result.rows where row.count >= 2 {
            guard let key = row[0], let text = row[1], let vector = Self.parseVector(text) else { continue }
            vectors[key] = vector
        }
        return vectors
    }

    func save(_ vectors: [String: [Double]]) async {
        let usable = vectors.filter { Self.isSafeKey($0.key) && $0.value.count == Self.vectorDimension }
        guard let configuration, !usable.isEmpty, !isSuspended else { return }
        // Upsert in one statement; re-running a sync must not duplicate rows.
        let values = usable.map { key, vector in
            "('\(key)', '\(Self.formatVector(vector))'::vector, \(configuration.modelRevision), now())"
        }.joined(separator: ",")
        let sql = """
        INSERT INTO \(configuration.table) (chunk_key, embedding, model_revision, updated_at) \
        VALUES \(values) \
        ON CONFLICT (chunk_key, model_revision) DO UPDATE \
        SET embedding = EXCLUDED.embedding, updated_at = now();
        """
        _ = run(sql)
    }

    /// Drops rows no live chunk references any more.
    ///
    /// Deliberately authorised to delete remotely: the vector store is derived data, so
    /// a row that no conversation points at is garbage everywhere, and re-deriving one is
    /// a single embedding call. `keys` is only passed after a complete, non-cancelled sync,
    /// so an empty set intentionally clears this model revision after the last conversation
    /// is deleted.
    func retain(keys: Set<String>) async {
        let safeKeys = keys.filter(Self.isSafeKey)
        guard let configuration, !isSuspended else { return }
        if safeKeys.isEmpty {
            _ = run("DELETE FROM \(configuration.table) WHERE model_revision = \(configuration.modelRevision);")
        } else {
            let list = safeKeys.map { "'\($0)'" }.joined(separator: ",")
            _ = run("""
            DELETE FROM \(configuration.table) \
            WHERE model_revision = \(configuration.modelRevision) AND chunk_key NOT IN (\(list));
            """)
        }
    }

    // MARK: - Connection handling

    private var isSuspended: Bool {
        guard let suspendedUntil else { return false }
        return suspendedUntil > .now
    }

    private func run(_ sql: String) -> PostgresResult? {
        guard let configuration else { return nil }
        let connection = PostgresConnection(configuration: configuration.connection)
        do {
            try connection.connect()
            defer { connection.close() }
            if !didPrepareSchema {
                try prepareSchema(connection, configuration: configuration)
                didPrepareSchema = true
            }
            return try connection.query(sql)
        } catch {
            NSLog("Vector database unavailable: %@", error.localizedDescription)
            suspendedUntil = Date.now.addingTimeInterval(120)
            return nil
        }
    }

    private func prepareSchema(
        _ connection: PostgresConnection,
        configuration: PostgresVectorConfiguration
    ) throws {
        try connection.query("CREATE EXTENSION IF NOT EXISTS vector;")
        try connection.query("""
        CREATE TABLE IF NOT EXISTS \(configuration.table) (
          chunk_key text NOT NULL,
          embedding vector(\(Self.vectorDimension)) NOT NULL,
          model_revision integer NOT NULL,
          updated_at timestamptz NOT NULL DEFAULT now(),
          PRIMARY KEY (chunk_key, model_revision)
        );
        """)
    }

    // MARK: - Encoding

    /// Keys are SHA-256 hex. Validating that keeps the simple-query path injection-free.
    static func isSafeKey(_ key: String) -> Bool {
        !key.isEmpty && key.count <= 128 && key.allSatisfy { $0.isHexDigit && !$0.isUppercase }
    }

    static func formatVector(_ vector: [Double]) -> String {
        "[" + vector.map { String(format: "%.8g", $0) }.joined(separator: ",") + "]"
    }

    static func parseVector(_ text: String) -> [Double]? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("["), trimmed.hasSuffix("]") else { return nil }
        let body = trimmed.dropFirst().dropLast()
        guard !body.isEmpty else { return nil }
        var values: [Double] = []
        values.reserveCapacity(vectorDimension)
        for component in body.split(separator: ",") {
            guard let value = Double(component.trimmingCharacters(in: .whitespaces)) else { return nil }
            values.append(value)
        }
        return values
    }
}

struct PostgresVectorConfiguration: Sendable {
    let connection: PostgresConfiguration
    let table: String
    let modelRevision: Int

    static func resolve(modelRevision: Int = 1) -> PostgresVectorConfiguration? {
        let environment = ProcessInfo.processInfo.environment
        if let host = environment["LEETCODE_PG_HOST"], !host.isEmpty {
            return PostgresVectorConfiguration(
                connection: PostgresConfiguration(
                    host: host,
                    port: UInt16(environment["LEETCODE_PG_PORT"] ?? "") ?? 5432,
                    database: environment["LEETCODE_PG_DATABASE"] ?? "leetcode_rag",
                    user: environment["LEETCODE_PG_USER"] ?? "leetcode",
                    password: environment["LEETCODE_PG_PASSWORD"] ?? "",
                    timeout: 5
                ),
                table: environment["LEETCODE_PG_TABLE"] ?? "leetcode_rag_vectors",
                modelRevision: modelRevision
            )
        }

        guard let directory = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else { return nil }
        let url = directory.appending(path: "leetcode-ai-helper/data/vector-db.json")
        guard let data = try? Data(contentsOf: url),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let host = root["host"] as? String,
              !host.isEmpty,
              (root["enabled"] as? Bool) != false
        else { return nil }
        return PostgresVectorConfiguration(
            connection: PostgresConfiguration(
                host: host,
                port: UInt16((root["port"] as? NSNumber)?.intValue ?? 5432),
                database: root["database"] as? String ?? "leetcode_rag",
                user: root["user"] as? String ?? "leetcode",
                password: root["password"] as? String ?? "",
                timeout: (root["timeoutSeconds"] as? NSNumber)?.doubleValue ?? 5
            ),
            table: root["table"] as? String ?? "leetcode_rag_vectors",
            modelRevision: modelRevision
        )
    }
}
