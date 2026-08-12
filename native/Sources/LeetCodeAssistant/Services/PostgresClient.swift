import CommonCrypto
import CryptoKit
import Darwin
import Foundation

/// Minimal PostgreSQL v3 client: startup, SCRAM-SHA-256 auth, simple query.
///
/// Only what the vector store needs. Uses blocking sockets with receive/send timeouts
/// because the auth handshake is a multi-step exchange; callers keep it off the main
/// thread by driving it from an actor.
struct PostgresConfiguration: Sendable {
    let host: String
    let port: UInt16
    let database: String
    let user: String
    let password: String
    let timeout: TimeInterval
}

enum PostgresError: LocalizedError {
    case connectionFailed(String)
    case authenticationFailed(String)
    case server(String)
    case protocolViolation(String)
    case timedOut

    var errorDescription: String? {
        switch self {
        case .connectionFailed(let detail): "无法连接向量数据库：\(detail)"
        case .authenticationFailed(let detail): "向量数据库认证失败：\(detail)"
        case .server(let detail): "向量数据库返回错误：\(detail)"
        case .protocolViolation(let detail): "向量数据库协议错误：\(detail)"
        case .timedOut: "向量数据库响应超时"
        }
    }
}

/// One simple-query result set.
struct PostgresResult {
    let columns: [String]
    let rows: [[String?]]
}

final class PostgresConnection {
    private var descriptor: Int32 = -1
    private var buffer = Data()
    private let configuration: PostgresConfiguration

    init(configuration: PostgresConfiguration) {
        self.configuration = configuration
    }

    deinit { close() }

    func close() {
        guard descriptor >= 0 else { return }
        _ = Darwin.close(descriptor)
        descriptor = -1
    }

    // MARK: - Connect

    func connect() throws {
        var hints = addrinfo(
            ai_flags: 0,
            ai_family: AF_UNSPEC,
            ai_socktype: SOCK_STREAM,
            ai_protocol: IPPROTO_TCP,
            ai_addrlen: 0,
            ai_canonname: nil,
            ai_addr: nil,
            ai_next: nil
        )
        var info: UnsafeMutablePointer<addrinfo>?
        let status = getaddrinfo(configuration.host, String(configuration.port), &hints, &info)
        guard status == 0, let resolved = info else {
            throw PostgresError.connectionFailed("无法解析主机 \(configuration.host)")
        }
        defer { freeaddrinfo(info) }

        var candidate = resolved
        while true {
            let socketDescriptor = socket(
                candidate.pointee.ai_family,
                candidate.pointee.ai_socktype,
                candidate.pointee.ai_protocol
            )
            if socketDescriptor >= 0 {
                applyTimeouts(socketDescriptor)
                if Darwin.connect(socketDescriptor, candidate.pointee.ai_addr, candidate.pointee.ai_addrlen) == 0 {
                    descriptor = socketDescriptor
                    break
                }
                _ = Darwin.close(socketDescriptor)
            }
            guard let next = candidate.pointee.ai_next else {
                throw PostgresError.connectionFailed("连接被拒绝")
            }
            candidate = next
        }

        try startup()
    }

    private func applyTimeouts(_ socketDescriptor: Int32) {
        var timeval = timeval(
            tv_sec: Int(configuration.timeout),
            tv_usec: Int32((configuration.timeout - Double(Int(configuration.timeout))) * 1_000_000)
        )
        setsockopt(socketDescriptor, SOL_SOCKET, SO_RCVTIMEO, &timeval, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(socketDescriptor, SOL_SOCKET, SO_SNDTIMEO, &timeval, socklen_t(MemoryLayout<timeval>.size))
        var one: Int32 = 1
        setsockopt(socketDescriptor, IPPROTO_TCP, TCP_NODELAY, &one, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(socketDescriptor, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
    }

    // MARK: - Handshake

    private func startup() throws {
        var body = Data()
        body.appendBigEndian(Int32(196_608)) // protocol 3.0
        for (key, value) in [
            ("user", configuration.user),
            ("database", configuration.database),
            ("client_encoding", "UTF8")
        ] {
            body.append(Data(key.utf8)); body.append(0)
            body.append(Data(value.utf8)); body.append(0)
        }
        body.append(0)

        var packet = Data()
        packet.appendBigEndian(Int32(body.count + 4))
        packet.append(body)
        try send(packet)

        while true {
            let message = try readMessage()
            switch message.type {
            case UInt8(ascii: "R"):
                if try handleAuthentication(message.payload) { return }
            case UInt8(ascii: "E"):
                throw PostgresError.authenticationFailed(Self.errorText(message.payload))
            case UInt8(ascii: "S"), UInt8(ascii: "K"):
                continue // parameter status / backend key
            case UInt8(ascii: "Z"):
                return // ready for query
            default:
                continue
            }
        }
    }

    /// Returns true once authentication has completed.
    private func handleAuthentication(_ payload: Data) throws -> Bool {
        guard payload.count >= 4 else { throw PostgresError.protocolViolation("认证消息过短") }
        let code = payload.readBigEndianInt32(at: payload.startIndex)
        switch code {
        case 0:
            return false // AuthenticationOk; wait for ReadyForQuery
        case 10:
            try authenticateSCRAM()
            return false
        case 3:
            var packet = Data()
            packet.append(UInt8(ascii: "p"))
            let secret = Data(configuration.password.utf8) + Data([0])
            packet.appendBigEndian(Int32(secret.count + 4))
            packet.append(secret)
            try send(packet)
            return false
        default:
            throw PostgresError.authenticationFailed("不支持的认证方式（code \(code)）")
        }
    }

    private func authenticateSCRAM() throws {
        let clientNonce = Data((0..<24).map { _ in UInt8.random(in: 33...125) })
            .base64EncodedString()
        let clientFirstBare = "n=,r=\(clientNonce)"
        let clientFirst = "n,," + clientFirstBare

        var initial = Data()
        initial.append(Data("SCRAM-SHA-256".utf8)); initial.append(0)
        initial.appendBigEndian(Int32(clientFirst.utf8.count))
        initial.append(Data(clientFirst.utf8))
        try sendTagged("p", initial)

        // AuthenticationSASLContinue
        let continueMessage = try readMessage()
        guard continueMessage.type == UInt8(ascii: "R") else {
            throw PostgresError.authenticationFailed(Self.errorText(continueMessage.payload))
        }
        let serverFirst = String(
            decoding: continueMessage.payload.dropFirst(4),
            as: UTF8.self
        )
        var attributes: [Character: String] = [:]
        for field in serverFirst.split(separator: ",") {
            guard let separator = field.firstIndex(of: "="), let key = field.first else { continue }
            attributes[key] = String(field[field.index(after: separator)...])
        }
        guard let combinedNonce = attributes["r"],
              let saltText = attributes["s"],
              let salt = Data(base64Encoded: saltText),
              let iterationsText = attributes["i"],
              let iterations = Int(iterationsText),
              combinedNonce.hasPrefix(clientNonce)
        else { throw PostgresError.authenticationFailed("SCRAM 服务器响应无效") }

        let saltedPassword = try Self.pbkdf2(
            password: configuration.password,
            salt: salt,
            iterations: iterations
        )
        let clientKey = Self.hmac(key: saltedPassword, message: Data("Client Key".utf8))
        let storedKey = Data(SHA256.hash(data: clientKey))
        let clientFinalWithoutProof = "c=biws,r=\(combinedNonce)"
        let authMessage = Data("\(clientFirstBare),\(serverFirst),\(clientFinalWithoutProof)".utf8)
        let clientSignature = Self.hmac(key: storedKey, message: authMessage)
        let proof = Data(zip(clientKey, clientSignature).map { $0 ^ $1 })
        let clientFinal = "\(clientFinalWithoutProof),p=\(proof.base64EncodedString())"

        try sendTagged("p", Data(clientFinal.utf8))

        // AuthenticationSASLFinal
        let finalMessage = try readMessage()
        guard finalMessage.type == UInt8(ascii: "R") else {
            throw PostgresError.authenticationFailed(Self.errorText(finalMessage.payload))
        }
    }

    // MARK: - Query

    @discardableResult
    func query(_ sql: String) throws -> PostgresResult {
        try sendTagged("Q", Data(sql.utf8) + Data([0]))

        var columns: [String] = []
        var rows: [[String?]] = []
        var failure: String?

        while true {
            let message = try readMessage()
            switch message.type {
            case UInt8(ascii: "T"):
                columns = Self.parseRowDescription(message.payload)
            case UInt8(ascii: "D"):
                rows.append(Self.parseDataRow(message.payload))
            case UInt8(ascii: "E"):
                failure = Self.errorText(message.payload)
            case UInt8(ascii: "Z"):
                if let failure { throw PostgresError.server(failure) }
                return PostgresResult(columns: columns, rows: rows)
            default:
                continue
            }
        }
    }

    // MARK: - Framing

    private struct Message {
        let type: UInt8
        let payload: Data
    }

    private func sendTagged(_ tag: String, _ payload: Data) throws {
        var packet = Data()
        packet.append(Data(tag.utf8))
        packet.appendBigEndian(Int32(payload.count + 4))
        packet.append(payload)
        try send(packet)
    }

    private func send(_ data: Data) throws {
        var offset = 0
        try data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            while offset < data.count {
                let written = Darwin.send(descriptor, base.advanced(by: offset), data.count - offset, 0)
                guard written > 0 else { throw PostgresError.connectionFailed("写入失败") }
                offset += written
            }
        }
    }

    private func readMessage() throws -> Message {
        try fill(to: 5)
        let type = buffer[buffer.startIndex]
        let length = Int(buffer.readBigEndianInt32(at: buffer.startIndex + 1))
        guard length >= 4 else { throw PostgresError.protocolViolation("长度字段无效") }
        try fill(to: 1 + length)
        let payloadStart = buffer.startIndex + 5
        let payload = Data(buffer[payloadStart..<(buffer.startIndex + 1 + length)])
        buffer = Data(buffer[(buffer.startIndex + 1 + length)...])
        return Message(type: type, payload: payload)
    }

    private func fill(to count: Int) throws {
        var chunk = [UInt8](repeating: 0, count: 16_384)
        while buffer.count < count {
            let received = recv(descriptor, &chunk, chunk.count, 0)
            if received > 0 {
                buffer.append(contentsOf: chunk[0..<received])
                continue
            }
            if received == 0 { throw PostgresError.connectionFailed("连接已关闭") }
            if errno == EAGAIN || errno == EWOULDBLOCK { throw PostgresError.timedOut }
            throw PostgresError.connectionFailed("读取失败（errno \(errno)）")
        }
    }

    // MARK: - Decoding

    private static func parseRowDescription(_ payload: Data) -> [String] {
        var names: [String] = []
        var cursor = payload.startIndex + 2
        while cursor < payload.endIndex {
            guard let terminator = payload[cursor...].firstIndex(of: 0) else { break }
            names.append(String(decoding: payload[cursor..<terminator], as: UTF8.self))
            cursor = terminator + 1 + 18 // fixed per-field metadata
        }
        return names
    }

    private static func parseDataRow(_ payload: Data) -> [String?] {
        var values: [String?] = []
        var cursor = payload.startIndex
        guard payload.count >= 2 else { return values }
        let count = Int(payload.readBigEndianInt16(at: cursor))
        cursor += 2
        for _ in 0..<count {
            guard cursor + 4 <= payload.endIndex else { break }
            let length = Int(payload.readBigEndianInt32(at: cursor))
            cursor += 4
            if length < 0 {
                values.append(nil)
                continue
            }
            let end = min(cursor + length, payload.endIndex)
            values.append(String(decoding: payload[cursor..<end], as: UTF8.self))
            cursor = end
        }
        return values
    }

    private static func errorText(_ payload: Data) -> String {
        var parts: [String] = []
        var cursor = payload.startIndex
        while cursor < payload.endIndex, payload[cursor] != 0 {
            let field = payload[cursor]
            guard let terminator = payload[(cursor + 1)...].firstIndex(of: 0) else { break }
            let text = String(decoding: payload[(cursor + 1)..<terminator], as: UTF8.self)
            if field == UInt8(ascii: "M") { parts.append(text) }
            cursor = terminator + 1
        }
        return parts.joined(separator: " ")
    }

    // MARK: - Crypto

    private static func hmac(key: Data, message: Data) -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: message, using: SymmetricKey(data: key)))
    }

    private static func pbkdf2(password: String, salt: Data, iterations: Int) throws -> Data {
        var derived = [UInt8](repeating: 0, count: 32)
        let passwordBytes = Array(password.utf8)
        let status = salt.withUnsafeBytes { saltBytes -> Int32 in
            CCKeyDerivationPBKDF(
                CCPBKDFAlgorithm(kCCPBKDF2),
                passwordBytes.map { Int8(bitPattern: $0) }, passwordBytes.count,
                saltBytes.bindMemory(to: UInt8.self).baseAddress, salt.count,
                CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
                UInt32(iterations),
                &derived, derived.count
            )
        }
        guard status == kCCSuccess else { throw PostgresError.authenticationFailed("PBKDF2 失败") }
        return Data(derived)
    }
}

private extension Data {
    mutating func appendBigEndian(_ value: Int32) {
        var bigEndian = value.bigEndian
        append(contentsOf: Swift.withUnsafeBytes(of: &bigEndian) { Array($0) })
    }

    func readBigEndianInt32(at index: Index) -> Int32 {
        var value: UInt32 = 0
        for offset in 0..<4 { value = (value << 8) | UInt32(self[index + offset]) }
        return Int32(bitPattern: value)
    }

    func readBigEndianInt16(at index: Index) -> Int16 {
        var value: UInt16 = 0
        for offset in 0..<2 { value = (value << 8) | UInt16(self[index + offset]) }
        return Int16(bitPattern: value)
    }
}
