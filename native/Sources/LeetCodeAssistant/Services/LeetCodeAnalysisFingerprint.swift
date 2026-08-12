import CryptoKit
import Foundation

/// Content fingerprints for the submission-analysis cache.
///
/// Deduplication used to be a plain `analyzedSubmissionIds` set, so a corrected detail,
/// a changed solution or a newer prompt could not invalidate anything, while a partial
/// failure re-queued work that had already been analysed. Hashing the actual content
/// makes "unchanged" mean unchanged, and makes any real change re-analyse exactly once.
///
/// Mirrors `src/integrations/leetcode-analysis.js` so both clients agree on cache keys.
enum LeetCodeAnalysisFingerprint {
    /// Bump when the analyser's prompt or output contract changes.
    static let analyzerVersion = 1
    static let promptVersion = 1
    /// Namespace version for every key this module writes.
    static let keyVersion = 1

    /// Per-submission identity: id + terminal status + language + code + detail body.
    static func itemFingerprint(_ detail: LeetCodeSubmissionDetail, problemRevision: String = "") -> String {
        let fields: [String] = [
            detail.id,
            detail.status,
            detail.language,
            digest(detail.code),
            detailHash(detail),
            problemRevision
        ]
        return digest(fields.joined(separator: "\u{0}"), length: 24)
    }

    /// Hash of the detail body itself, so a corrected detail invalidates its analysis.
    static func detailHash(_ detail: LeetCodeSubmissionDetail) -> String {
        let normalized: [String] = [
            detail.id,
            detail.status,
            detail.language,
            detail.runtime,
            detail.memory,
            detail.runtimeError,
            detail.compileError,
            detail.lastTestCase,
            detail.actualOutput,
            detail.expectedOutput,
            String(detail.correctCaseCount),
            String(detail.totalCaseCount)
        ]
        return digest(normalized.joined(separator: "\u{0}"), length: 24)
    }

    /// Identity of a whole analysis request: its inputs plus everything that shapes output.
    static func analysisFingerprint(
        details: [LeetCodeSubmissionDetail],
        modelProfile: String,
        problemRevision: String = ""
    ) -> String {
        let items = details
            .map { itemFingerprint($0, problemRevision: problemRevision) }
            .sorted()
        let payload = ([
            "v\(analyzerVersion)",
            "p\(promptVersion)",
            modelProfile
        ] + items).joined(separator: "\u{0}")
        return digest(payload, length: 24)
    }

    // MARK: - Keys

    static func analysisKey(slug: String, fingerprint: String) -> String {
        "analysis:v\(keyVersion):\(slug):\(fingerprint)"
    }

    static func analyzedKey(slug: String, itemFingerprint: String) -> String {
        "analyzed:v\(keyVersion):\(slug):\(itemFingerprint)"
    }

    static func detailKey(submissionID: String) -> String {
        "subdetail:v\(keyVersion):\(submissionID)"
    }

    static func detailLockKey(submissionID: String) -> String {
        "lock:detail:v\(keyVersion):\(submissionID)"
    }

    // MARK: - Hashing

    private static func digest(_ text: String, length: Int = 24) -> String {
        let hash = SHA256.hash(data: Data(text.utf8))
        return String(hash.map { String(format: "%02x", $0) }.joined().prefix(length))
    }
}
