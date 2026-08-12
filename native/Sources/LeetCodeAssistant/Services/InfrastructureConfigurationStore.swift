import Foundation

struct RedisSettingsDraft: Equatable {
    var enabled = false
    var host = ""
    var port = "6379"
    var password = ""
    var keyPrefix = "lca:"
    var timeoutSeconds = "2"

    func configuration() throws -> RedisConfiguration? {
        guard enabled else { return nil }
        let normalizedHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedHost.isEmpty else { throw InfrastructureConfigurationError.missingRedisHost }
        guard let parsedPort = UInt16(port), parsedPort > 0 else {
            throw InfrastructureConfigurationError.invalidPort("Redis")
        }
        guard let timeout = TimeInterval(timeoutSeconds), (0.25...30).contains(timeout) else {
            throw InfrastructureConfigurationError.invalidTimeout("Redis")
        }
        let prefix = keyPrefix.trimmingCharacters(in: .whitespacesAndNewlines)
        return RedisConfiguration(
            host: normalizedHost,
            port: parsedPort,
            password: password.isEmpty ? nil : password,
            keyPrefix: prefix.isEmpty ? "lca:" : prefix,
            timeout: timeout
        )
    }
}

struct VectorDatabaseSettingsDraft: Equatable {
    var enabled = false
    var host = ""
    var port = "5432"
    var database = "leetcode_rag"
    var user = "leetcode"
    var password = ""
    var table = "leetcode_rag_vectors"
    var timeoutSeconds = "5"

    func configuration(modelRevision: Int = 1) throws -> PostgresVectorConfiguration? {
        guard enabled else { return nil }
        let normalizedHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedDatabase = database.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedUser = user.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedTable = table.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedHost.isEmpty else { throw InfrastructureConfigurationError.missingPostgresHost }
        guard !normalizedDatabase.isEmpty, !normalizedUser.isEmpty else {
            throw InfrastructureConfigurationError.missingPostgresIdentity
        }
        guard let parsedPort = UInt16(port), parsedPort > 0 else {
            throw InfrastructureConfigurationError.invalidPort("PostgreSQL")
        }
        guard let timeout = TimeInterval(timeoutSeconds), (0.5...30).contains(timeout) else {
            throw InfrastructureConfigurationError.invalidTimeout("PostgreSQL")
        }
        guard Self.isSafeIdentifier(normalizedTable) else {
            throw InfrastructureConfigurationError.invalidTable
        }
        return PostgresVectorConfiguration(
            connection: PostgresConfiguration(
                host: normalizedHost,
                port: parsedPort,
                database: normalizedDatabase,
                user: normalizedUser,
                password: password,
                timeout: timeout
            ),
            table: normalizedTable,
            modelRevision: modelRevision
        )
    }

    private static func isSafeIdentifier(_ value: String) -> Bool {
        guard let first = value.first, first == "_" || first.isLetter else { return false }
        return value.allSatisfy { $0 == "_" || $0.isLetter || $0.isNumber }
    }
}

enum InfrastructureConfigurationStore {
    static var hasEnvironmentOverrides: Bool {
        let environment = ProcessInfo.processInfo.environment
        return !(environment["LEETCODE_REDIS_HOST"] ?? "").isEmpty
            || !(environment["LEETCODE_PG_HOST"] ?? "").isEmpty
    }

    static func loadRedis() -> RedisSettingsDraft {
        let root = readJSON(named: "redis.json")
        return RedisSettingsDraft(
            enabled: (root["enabled"] as? Bool) == true,
            host: root["host"] as? String ?? "",
            port: String((root["port"] as? NSNumber)?.intValue ?? 6379),
            password: root["password"] as? String ?? "",
            keyPrefix: root["keyPrefix"] as? String ?? "lca:",
            timeoutSeconds: numberText(root["timeoutSeconds"], fallback: 2)
        )
    }

    static func loadVectorDatabase() -> VectorDatabaseSettingsDraft {
        let root = readJSON(named: "vector-db.json")
        return VectorDatabaseSettingsDraft(
            enabled: (root["enabled"] as? Bool) == true,
            host: root["host"] as? String ?? "",
            port: String((root["port"] as? NSNumber)?.intValue ?? 5432),
            database: root["database"] as? String ?? "leetcode_rag",
            user: root["user"] as? String ?? "leetcode",
            password: root["password"] as? String ?? "",
            table: root["table"] as? String ?? "leetcode_rag_vectors",
            timeoutSeconds: numberText(root["timeoutSeconds"], fallback: 5)
        )
    }

    static func save(redis: RedisSettingsDraft, vectorDatabase: VectorDatabaseSettingsDraft) throws {
        _ = try redis.configuration()
        _ = try vectorDatabase.configuration()
        try writeJSON([
            "enabled": redis.enabled,
            "host": redis.host.trimmingCharacters(in: .whitespacesAndNewlines),
            "port": Int(redis.port) ?? 6379,
            "password": redis.password,
            "keyPrefix": redis.keyPrefix.trimmingCharacters(in: .whitespacesAndNewlines),
            "timeoutSeconds": Double(redis.timeoutSeconds) ?? 2
        ], named: "redis.json")
        try writeJSON([
            "enabled": vectorDatabase.enabled,
            "host": vectorDatabase.host.trimmingCharacters(in: .whitespacesAndNewlines),
            "port": Int(vectorDatabase.port) ?? 5432,
            "database": vectorDatabase.database.trimmingCharacters(in: .whitespacesAndNewlines),
            "user": vectorDatabase.user.trimmingCharacters(in: .whitespacesAndNewlines),
            "password": vectorDatabase.password,
            "table": vectorDatabase.table.trimmingCharacters(in: .whitespacesAndNewlines),
            "timeoutSeconds": Double(vectorDatabase.timeoutSeconds) ?? 5
        ], named: "vector-db.json")
    }

    private static func numberText(_ value: Any?, fallback: Double) -> String {
        let number = (value as? NSNumber)?.doubleValue ?? fallback
        return number.rounded() == number ? String(Int(number)) : String(number)
    }

    private static func readJSON(named name: String) -> [String: Any] {
        guard let data = try? Data(contentsOf: configurationDirectory.appending(path: name)),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [:] }
        return root
    }

    private static func writeJSON(_ root: [String: Any], named name: String) throws {
        let directory = configurationDirectory
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let url = directory.appending(path: name)
        let data = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: url, options: [.atomic])
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    private static var configurationDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "leetcode-ai-helper/data", directoryHint: .isDirectory)
    }
}

enum InfrastructureConfigurationError: LocalizedError {
    case missingRedisHost
    case missingPostgresHost
    case missingPostgresIdentity
    case invalidPort(String)
    case invalidTimeout(String)
    case invalidTable
    case disabled(String)

    var errorDescription: String? {
        switch self {
        case .missingRedisHost: "请填写 Redis 主机地址"
        case .missingPostgresHost: "请填写 PostgreSQL 主机地址"
        case .missingPostgresIdentity: "请填写 PostgreSQL 数据库名和用户名"
        case .invalidPort(let service): "\(service) 端口无效"
        case .invalidTimeout(let service): "\(service) 超时应在允许范围内"
        case .invalidTable: "向量表名只能包含字母、数字和下划线，且不能以数字开头"
        case .disabled(let service): "请先启用 \(service)"
        }
    }
}
