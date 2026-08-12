import XCTest
@testable import LeetCodeAssistant

final class LeetCodeAnalysisServiceTests: XCTestCase {
    func testTrajectoryDecodePreservesCodingPathAndReason() {
        let invalid = #"{"summary":"ok","attemptInsights":"wrong","weaknesses":[],"improvements":[]}"#

        XCTAssertThrowsError(try LeetCodeAnalysisService.decodeDraft(from: invalid)) { error in
            guard case LeetCodeAnalysisServiceError.decoding(let decodingError) = error else {
                return XCTFail("Expected decoding context, got \(error)")
            }
            guard case .typeMismatch(_, let context) = decodingError else {
                return XCTFail("Expected typeMismatch, got \(decodingError)")
            }
            XCTAssertEqual(context.codingPath.map(\.stringValue), ["attemptInsights"])
            XCTAssertTrue(error.localizedDescription.contains("attemptInsights"))
        }
    }

    func testTrajectoryDecodeReportsMissingJSONEnvelope() {
        XCTAssertThrowsError(try LeetCodeAnalysisService.decodeDraft(from: "not json")) { error in
            guard case LeetCodeAnalysisServiceError.malformedJSON = error else {
                return XCTFail("Expected malformed JSON error, got \(error)")
            }
        }
    }

    func testTrajectorySemanticValidationRejectsUnknownOrEmptyAttempts() throws {
        let valid = try LeetCodeAnalysisService.decodeDraft(from: """
        {"summary":"修复边界后通过","attemptInsights":[{"submissionId":"1","issue":"边界遗漏","change":"补充分支","outcome":"通过"}],"weaknesses":[],"improvements":[]}
        """)
        XCTAssertNoThrow(try LeetCodeAnalysisService.validate(valid, submissionIDs: ["1"]))
        XCTAssertThrowsError(try LeetCodeAnalysisService.validate(valid, submissionIDs: ["2"]))

        let empty = try LeetCodeAnalysisService.decodeDraft(from: """
        {"summary":"","attemptInsights":[],"weaknesses":[],"improvements":[]}
        """)
        XCTAssertThrowsError(try LeetCodeAnalysisService.validate(empty, submissionIDs: ["1"]))
    }
}
