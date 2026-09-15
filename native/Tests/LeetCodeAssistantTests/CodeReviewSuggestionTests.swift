import XCTest
@testable import LeetCodeAssistant

final class CodeReviewSuggestionTests: XCTestCase {
    private let code = """
    class Solution {
        public List<List<Integer>> partition(String s) {
            List<Integer> ans = new ArrayList<>();
            int plen = s.length();
            for(int i = 0;i<plen;p++) {
                ans.add(i);
            }
            List<Integer> ans = new ArrayList<>();
            return null;
        }
    }
    """

    /// 用户截图里 AI 说的两处：第 5 行 p++ → i++，第 8 行重复声明删掉。
    func testResolvesIssuesEvenWhenModelReformatsTheOriginal() {
        let issues = [
            CodeReviewRawIssue(startLine: 5, endLine: 5, severity: "error", title: "循环变量写错",
                               original: "for (int i = 0; i < plen; p++) {", replacement: "for (int i = 0; i < plen; i++) {"),
            CodeReviewRawIssue(startLine: 8, endLine: 8, severity: "error", title: "重复声明",
                               original: "List<Integer> ans = new ArrayList<>();", replacement: "")
        ]
        let suggestions = CodeReviewPolicy.resolve(issues, code: code, idPrefix: "t")
        XCTAssertEqual(suggestions.map(\.startLine), [5, 8])
        XCTAssertEqual(suggestions[0].original, "        for(int i = 0;i<plen;p++) {", "original 回填成编辑器里逐字的原文")
        XCTAssertEqual(suggestions[0].replacement, "        for (int i = 0; i < plen; i++) {", "丢了的缩进按原文补回")
        XCTAssertEqual(suggestions[0].severity, .error)
    }

    func testDropsUnlocatableNoOpAndOverlappingIssues() {
        let issues = [
            CodeReviewRawIssue(startLine: 5, endLine: 5, original: "while (true) {", replacement: "x"),
            CodeReviewRawIssue(startLine: 6, endLine: 6, original: "ans.add(i);", replacement: "ans.add( i );"),
            CodeReviewRawIssue(startLine: 5, endLine: 6, original: "for(int i = 0;i<plen;p++) {\n    ans.add(i);", replacement: "for (int i = 0; i < plen; i++) {\n    ans.add(i);"),
            CodeReviewRawIssue(startLine: 6, endLine: 6, original: "ans.add(i);", replacement: "ans.add(i * 2);")
        ]
        let suggestions = CodeReviewPolicy.resolve(issues, code: code, idPrefix: "t")
        XCTAssertEqual(suggestions.count, 1, "找不到的、只改空白的、和已收下区间重叠的都丢掉")
        XCTAssertEqual(suggestions.first?.startLine, 5)
        XCTAssertEqual(suggestions.first?.endLine, 6)
    }

    func testRelocatesAfterLinesInsertedAboveAndExpiresWhenLineIsEdited() throws {
        let suggestion = try XCTUnwrap(CodeReviewPolicy.resolve([
            CodeReviewRawIssue(startLine: 5, endLine: 5, original: "for(int i = 0;i<plen;p++) {", replacement: "for(int i = 0;i<plen;i++) {")
        ], code: code).first)

        let shifted = code.replacingOccurrences(of: "int plen = s.length();", with: "int plen = s.length();\n        // TODO\n        // 再加一行")
        XCTAssertEqual(CodeReviewPolicy.relocate(suggestion, in: shifted)?.startLine, 7)

        let edited = code.replacingOccurrences(of: "p++", with: "i++")
        XCTAssertNil(CodeReviewPolicy.relocate(suggestion, in: edited), "用户自己改过这一行，建议作废")
    }

    func testApplyReplacesAndDeletesWholeLines() throws {
        let suggestions = CodeReviewPolicy.resolve([
            CodeReviewRawIssue(startLine: 5, endLine: 5, original: "for(int i = 0;i<plen;p++) {", replacement: "for (int i = 0; i < plen; i++) {"),
            CodeReviewRawIssue(startLine: 8, endLine: 8, original: "List<Integer> ans = new ArrayList<>();", replacement: "")
        ], code: code)
        var result = code
        for suggestion in suggestions.reversed() {
            result = try XCTUnwrap(CodeReviewPolicy.apply(suggestion, to: result))
        }
        XCTAssertTrue(result.contains("for (int i = 0; i < plen; i++) {"))
        XCTAssertEqual(result.components(separatedBy: "List<Integer> ans").count - 1, 1, "重复声明删掉，只剩一处")
        XCTAssertEqual(result.components(separatedBy: "\n").count, code.components(separatedBy: "\n").count - 1)
    }

    func testDecodesLenientModelOutput() throws {
        let json = #"{"issues":[{"line":"3","severity":"ERROR","original":"int x","replacement":"long x"},{"title":"缺字段"}]}"#
        let response = try JSONDecoder().decode(CodeReviewResponse.self, from: Data(json.utf8))
        XCTAssertEqual(response.issues.count, 2)
        XCTAssertEqual(response.issues[0].startLine, 3)
        XCTAssertEqual(response.issues[0].endLine, 3)
        let resolved = CodeReviewPolicy.resolve(response.issues, code: "a\nb\nint x = 1;\n")
        XCTAssertTrue(resolved.isEmpty, "\"int x\" 不是整行原文，定位不到就不标")
    }

    func testDetectsRepliesThatPointAtSpecificLines() {
        XCTAssertTrue(CodeReviewPolicy.mentionsSpecificLines("① 第 8 行：for(int i = 0;i<plen;p++)"))
        XCTAssertTrue(CodeReviewPolicy.mentionsSpecificLines("看第3–5行的边界"))
        XCTAssertTrue(CodeReviewPolicy.mentionsSpecificLines("the bug is on line 12"))
        XCTAssertFalse(CodeReviewPolicy.mentionsSpecificLines("这道题可以用双指针，时间复杂度 O(n)"))
    }
}
