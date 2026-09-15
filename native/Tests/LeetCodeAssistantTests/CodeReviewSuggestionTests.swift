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

    /// 2026-09 用户截图：替换代码写成 `java.util.Map<...> map = new java.util.HashMap<>()`。
    /// 力扣 Java 已默认导入 java.util.* 等包，全限定名和 import 都不该出现。
    func testJavaReplacementDropsDefaultImportsAndQualifiedNames() {
        let replacement = """
        import java.util.*;
        import java.util.function.Function;
        java.util.Map<Integer, Integer> map = new java.util.HashMap<>();
        java.util.Deque<Integer> stack = new java.util.ArrayDeque<>();
        java.util.stream.IntStream.range(0, n).forEach(i -> {});
        java.util.concurrent.ConcurrentHashMap<Integer, Integer> keep = null;
        """
        let simplified = LeetCodeJudgeEnvironment.simplify(replacement, language: "java")
        XCTAssertFalse(simplified.contains("import java.util"))
        XCTAssertTrue(simplified.contains("Map<Integer, Integer> map = new HashMap<>();"))
        XCTAssertTrue(simplified.contains("Deque<Integer> stack = new ArrayDeque<>();"))
        XCTAssertTrue(simplified.contains("IntStream.range(0, n)"))
        XCTAssertTrue(simplified.contains("java.util.concurrent.ConcurrentHashMap"), "concurrent 不在默认导入里，不能删")
        XCTAssertEqual(LeetCodeJudgeEnvironment.simplify("import java.util.*;", language: "python3"), "import java.util.*;", "只处理 Java")
    }

    func testResolvedJavaSuggestionUsesShortNames() throws {
        let source = "class Solution {\n    public int subarraySum(int[] nums, int k) {\n        Map<Integer,Integer> map = new HashMap();\n        return 0;\n    }\n}"
        let suggestion = try XCTUnwrap(CodeReviewPolicy.resolve([
            CodeReviewRawIssue(startLine: 3, endLine: 3, original: "Map<Integer,Integer> map = new HashMap();",
                               replacement: "java.util.Map<Integer,Integer> map = new java.util.HashMap<>();")
        ], code: source, language: "java").first)
        XCTAssertEqual(suggestion.replacement, "        Map<Integer,Integer> map = new HashMap<>();")
    }

    func testPromptsTellModelAboutLeetCodeImports() {
        XCTAssertTrue(LeetCodeJudgeEnvironment.promptNote(language: "java").contains("不要写 import"))
        let context = LeetCodeAssistantContext.prompt(.init(
            frontendID: "560", title: "和为 K 的子数组", difficulty: "中等", statement: "", language: "java",
            code: "class Solution {}", isPristine: false, selection: nil, judgeResult: nil, diagnostics: []
        ))
        XCTAssertTrue(context.contains("java.util.*、java.util.function.*") && context.contains("不要写 import"), "问 AI 的上下文里也要带上默认导入说明")
    }

    func testDetectsRepliesThatPointAtSpecificLines() {
        XCTAssertTrue(CodeReviewPolicy.mentionsSpecificLines("① 第 8 行：for(int i = 0;i<plen;p++)"))
        XCTAssertTrue(CodeReviewPolicy.mentionsSpecificLines("看第3–5行的边界"))
        XCTAssertTrue(CodeReviewPolicy.mentionsSpecificLines("the bug is on line 12"))
        XCTAssertFalse(CodeReviewPolicy.mentionsSpecificLines("这道题可以用双指针，时间复杂度 O(n)"))
    }
}
