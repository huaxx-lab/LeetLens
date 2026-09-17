import XCTest
@testable import LeetCodeAssistant

final class LeetCodeJudgeDiagnosticsTests: XCTestCase {
    func testLeetCodeJavaCompileErrorMapsDirectlyToOneBasedLine() {
        let result = judge(compileError: "Line 21: error: incompatible types: missing return value")
        XCTAssertEqual(LeetCodeJudgeDiagnosticParser.parse(result, codeLineCount: 32), [
            LeetCodeEditorIssue(line: 21, message: "incompatible types: missing return value")
        ])
    }

    func testLineAndCharacterFormatDropsCompilerPrefix() {
        let result = judge(compileError: "Line 7: Char 12: error: illegal character: '\\u200b'")
        XCTAssertEqual(LeetCodeJudgeDiagnosticParser.parse(result, codeLineCount: 10), [
            LeetCodeEditorIssue(line: 7, message: "illegal character: '\\u200b'")
        ])
    }

    func testClangFileLineColumnFormat() {
        let result = judge(compileError: "solution.cpp:14:9: error: expected ';' after expression")
        XCTAssertEqual(LeetCodeJudgeDiagnosticParser.parse(result, codeLineCount: 20), [
            LeetCodeEditorIssue(line: 14, message: "expected ';' after expression")
        ])
    }

    func testPythonTracebackUsesFollowingExceptionMessage() {
        let result = judge(runtimeError: """
        Traceback (most recent call last):
          File "Solution.py", line 5, in maxDepth
            return root.left.val
        AttributeError: 'NoneType' object has no attribute 'left'
        """)
        XCTAssertEqual(LeetCodeJudgeDiagnosticParser.parse(result, codeLineCount: 12), [
            LeetCodeEditorIssue(line: 5, message: "AttributeError: 'NoneType' object has no attribute 'left'")
        ])
    }

    func testJavaStackFrameUsesTopLevelRuntimeMessage() {
        let result = judge(runtimeError: """
        java.lang.NullPointerException: Cannot read field "left" because "root" is null
            at Solution.maxDepth(Solution.java:24)
            at Driver.main(Driver.java:9)
        """)
        XCTAssertEqual(LeetCodeJudgeDiagnosticParser.parse(result, codeLineCount: 32), [
            LeetCodeEditorIssue(line: 24, message: "java.lang.NullPointerException: Cannot read field \"left\" because \"root\" is null")
        ])
    }

    func testDuplicateAndOutOfRangeLocationsAreRejected() {
        let result = judge(compileError: """
        Line 3: error: bad return
        Line 3: error: bad return
        Line 99: error: generated wrapper, not user code
        """)
        XCTAssertEqual(LeetCodeJudgeDiagnosticParser.parse(result, codeLineCount: 10), [
            LeetCodeEditorIssue(line: 3, message: "bad return")
        ])
    }

    func testAnsiFormattingDoesNotPreventParsing() {
        let escape = String(UnicodeScalar(27))
        let result = judge(compileError: "\(escape)[31mLine 2: error: missing return value\(escape)[0m")
        XCTAssertEqual(LeetCodeJudgeDiagnosticParser.parse(result, codeLineCount: 5), [
            LeetCodeEditorIssue(line: 2, message: "missing return value")
        ])
    }

    func testErrorsWithoutUserCodeLineDoNotGuess() {
        let result = judge(compileError: "Compilation failed inside generated wrapper")
        XCTAssertTrue(LeetCodeJudgeDiagnosticParser.parse(result, codeLineCount: 10).isEmpty)
    }

    private func judge(compileError: String = "", runtimeError: String = "") -> LeetCodeJudgeResult {
        LeetCodeJudgeResult(
            kind: "submit", taskID: "t", state: "SUCCESS", status: "Compile Error",
            statusCode: 20, accepted: false, totalCorrect: 0, totalTestCases: 1,
            runtime: "", memory: "", compileError: compileError, runtimeError: runtimeError,
            input: "", output: "", expectedOutput: "", compareResult: "", aiJudgeMessage: ""
        )
    }
}
