import JavaScriptCore
import XCTest
@testable import LeetCodeAssistant

/// 编辑器补全的落位与泛型判定。
///
/// 这两段逻辑住在 `editor.html` 里，但它们是纯函数——把源码里的函数体挖出来丢进
/// JavaScriptCore 就能真跑，不用 WKWebView，也不用把断言退化成"源码里有没有这个字符串"。
/// 行为在 WKWebView harness 里另外端到端验证过（远端 `sort(int[] a)` 整段选中、
/// `ans.add()` 光标进括号、`new ArrayList<>()` 停末尾、`Map<I` 给出 Integer）。
final class CodeEditorCompletionTests: XCTestCase {
    private var context: JSContext!

    override func setUpWithError() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "Sources/LeetCodeAssistant/Resources/CodeEditor/editor.html")
        let source = try String(contentsOf: url, encoding: .utf8)
        let js = try [
            Self.declaration(named: "NO_ARGUMENT_METHODS", in: source, kind: .constant),
            Self.declaration(named: "bracketSpan", in: source, kind: .function),
            Self.declaration(named: "calleeName", in: source, kind: .function),
            Self.declaration(named: "placeholderSpan", in: source, kind: .function),
            Self.declaration(named: "maskLiterals", in: source, kind: .function),
            Self.declaration(named: "javaGenericArgumentPrefix", in: source, kind: .function)
        ].joined(separator: "\n")
        context = JSContext()
        context.exceptionHandler = { _, value in XCTFail("JS 异常：\(value?.toString() ?? "?")") }
        context.evaluateScript(js)
        XCTAssertTrue(context.objectForKeyedSubscript("placeholderSpan").isObject, "函数没挖出来")
    }

    // MARK: - 光标落位

    /// 括号里真的有参数：整段选中，打字直接覆盖。
    func testFilledParameterListIsSelected() {
        XCTAssertEqual(span("sort(int[] a)"), Span(from: 5, to: 12))
        XCTAssertEqual(span("computeIfAbsent(K k, Function f)"), Span(from: 16, to: 31))
        // 嵌套括号按深度配对，取最外层那个 `)`。
        XCTAssertEqual(span("max(a, min(b, c))"), Span(from: 4, to: 16))
        // 泛型同理：`Map<K, V>` 选中 `K, V`。
        XCTAssertEqual(span("Map<K, V>"), Span(from: 4, to: 8))
        XCTAssertEqual(span("List<Integer>"), Span(from: 5, to: 12))
    }

    /// 空括号但方法需要参数：光标收进括号里。
    func testEmptyParenthesesOfArgumentTakingMethodsPlaceTheCursorInside() {
        XCTAssertEqual(span("add()"), Span(from: 4, to: 4))
        XCTAssertEqual(span("Arrays.sort()"), Span(from: 12, to: 12))
        XCTAssertEqual(span("Math.abs()"), Span(from: 9, to: 9))
        XCTAssertEqual(span("getOrDefault()"), Span(from: 13, to: 13))
    }

    /// 2026-09-17 用户反馈：`new ArrayList<>()` 这种补完就该往下写，光标不该钻进括号。
    /// 构造器按"大写开头"识别，无参方法查表。
    func testConstructorsAndNoArgumentMethodsLeaveTheCursorAtTheEnd() {
        XCTAssertNil(span("ArrayList<>()"))
        XCTAssertNil(span("new ArrayList<>()"))
        XCTAssertNil(span("PriorityQueue<>()"))
        XCTAssertNil(span("StringBuilder()"))
        XCTAssertNil(span("size()"))
        XCTAssertNil(span("toCharArray()"))
        XCTAssertNil(span("length"), "没有括号的标识符不动光标")
    }

    /// 边界：空串、裸括号、JDT 给半截的候选。
    func testDegenerateCompletionTexts() {
        XCTAssertNil(span(""))
        XCTAssertNil(span("()"), "没有方法名就不猜")
        XCTAssertNil(span("foo("), "只有左括号、里面是空的")
        XCTAssertEqual(span("sort(int[] a"), Span(from: 5, to: 12), "右括号缺失时选到末尾")
        XCTAssertEqual(span("Map<K"), Span(from: 4, to: 5))
    }

    // MARK: - 泛型参数位

    func testGenericArgumentPositionsAreDetected() {
        XCTAssertEqual(generic("HashMap<I"), "I")
        XCTAssertEqual(generic("        Map<String, I"), "I")
        XCTAssertEqual(generic("Map<String, List<I"), "I", "嵌套泛型")
        XCTAssertEqual(generic("        Map<"), "", "刚敲下尖括号，还没有前缀")
        XCTAssertEqual(generic("List<Integer> x = new HashMap<"), "")
        XCTAssertEqual(generic("Map<String, Function<Integer, I"), "I", "泛型里带函数式接口")
    }

    /// 关键的反例：小于号、右移、lambda 箭头、字符串和注释都不能被当成泛型。
    func testComparisonsAndLiteralsAreNotGenerics() {
        XCTAssertNil(generic("        if (i < n"), "`<` 前面是小写变量，不是类型")
        XCTAssertNil(generic("a<b && c>d"))
        XCTAssertNil(generic("int a = b >> 2"), "右移不能把空栈弹崩")
        XCTAssertNil(generic("Map<String, Integer> map"), "已经闭合")
        XCTAssertNil(generic("Map<String, List<Integer>> m"), "两层一起闭合")
        XCTAssertNil(generic("String s = \"a<b\""), "字符串字面量里的尖括号")
        XCTAssertNil(generic("char c = '<'"), "字符字面量")
        XCTAssertNil(generic("// Map<I"), "行注释")
        XCTAssertNil(generic("Map<String, Integer> m; list.forEach(x -> x"), "lambda 箭头不是闭合")
        XCTAssertNil(generic("vector<i", language: "cpp"), "远端语义补全只有 Java，这套只对 Java 生效")
    }

    // MARK: - 调用

    private struct Span: Equatable { let from: Int; let to: Int }

    private func span(_ text: String) -> Span? {
        let value = context.objectForKeyedSubscript("placeholderSpan").call(withArguments: [text])
        guard let value, !value.isNull, !value.isUndefined else { return nil }
        return Span(from: Int(value.objectForKeyedSubscript("from").toInt32()),
                    to: Int(value.objectForKeyedSubscript("to").toInt32()))
    }

    private func generic(_ line: String, language: String = "java") -> String? {
        let value = context.objectForKeyedSubscript("javaGenericArgumentPrefix").call(withArguments: [line, language])
        guard let value, !value.isNull, !value.isUndefined else { return nil }
        return value.toString()
    }

    // MARK: - 从 HTML 里挖函数

    private enum DeclarationKind {
        case function, constant
        /// 函数只数大括号（参数表里的圆括号不算）；`const X = new Set([...])` 三种都要数。
        var brackets: (open: Set<Character>, close: Set<Character>) {
            switch self {
            case .function: (["{"], ["}"])
            case .constant: (["{", "[", "("], ["}", "]", ")"])
            }
        }
    }

    private static func declaration(named name: String, in source: String, kind: DeclarationKind) throws -> String {
        let head = kind == .function ? "function \(name)(" : "const \(name) ="
        guard let start = source.range(of: head)?.lowerBound else {
            throw XCTSkip("editor.html 里没有 \(name)")
        }
        let (open, close) = kind.brackets
        var depth = 0
        var started = false
        var index = start
        while index < source.endIndex {
            let character = source[index]
            if open.contains(character) { depth += 1; started = true }
            else if close.contains(character) {
                depth -= 1
                if started, depth == 0 {
                    let body = String(source[start...index])
                    return kind == .function ? body : body + ";"
                }
            }
            index = source.index(after: index)
        }
        throw XCTSkip("\(name) 括号不配对")
    }
}

/// Java 当前方法作用域补全：力扣模板里的方法参数必须离线可用，不能完全依赖远端 JDT。
final class JavaScopeCompletionTests: XCTestCase {
    private var context: JSContext!

    override func setUpWithError() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "Sources/LeetCodeAssistant/Resources/CodeEditor/editor.html")
        let source = try String(contentsOf: url, encoding: .utf8)
        let memberStart = try XCTUnwrap(source.range(of: "const MEMBER_COMPLETIONS =")?.lowerBound)
        let memberEnd = try XCTUnwrap(source.range(of: "const JAVA_CONSTRUCTOR_COMPLETIONS =")?.lowerBound)
        let functionStart = try XCTUnwrap(source.range(of: "function normalizedJavaType(")?.lowerBound)
        let functionEnd = try XCTUnwrap(source.range(of: "function javaConstructorCompletions(")?.lowerBound)

        context = JSContext()
        context.exceptionHandler = { _, value in XCTFail("JS 异常：\(value?.toString() ?? "?")") }
        context.evaluateScript(String(source[memberStart..<memberEnd]) + String(source[functionStart..<functionEnd]))
        XCTAssertTrue(context.objectForKeyedSubscript("javaSymbolsInSource").isObject)
    }

    func testTreeNodeMethodParameterCompletesRoot() throws {
        let source = """
        /**
         * Definition for a binary tree node.
         * TreeNode left;
         * TreeNode right;
         */
        class Solution {
            public int maxDepth(TreeNode root) {
                ro
        """
        let items = try identifierItems(source, prefix: "ro")
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items[0]["text"] as? String, "root")
        XCTAssertEqual(items[0]["detail"] as? String, "TreeNode · 方法参数")
    }

    func testTreeNodeAndListNodeMembersAreTypeAware() throws {
        let tree = "class Solution { int maxDepth(TreeNode root) { root."
        XCTAssertEqual(try memberTexts(tree, owner: "root"), ["val", "left", "right"])
        XCTAssertEqual(try memberTexts(tree, owner: "root", prefix: "le"), ["left"])

        let list = "class Solution { ListNode reverse(ListNode head) { head."
        XCTAssertEqual(try memberTexts(list, owner: "head"), ["val", "next"])
    }

    func testGenericArrayAndVarargsParametersKeepTheirTypes() throws {
        let source = """
        class Solution {
            int f(final Map<String, List<Integer>> graph, int[] nums, TreeNode... roots) {
        """
        let graph = try identifierItems(source, prefix: "gr").first
        let nums = try identifierItems(source, prefix: "nu").first
        let roots = try identifierItems(source, prefix: "roo").first
        XCTAssertEqual(graph?["detail"] as? String, "Map<String, List<Integer>> · 方法参数")
        XCTAssertEqual(nums?["detail"] as? String, "int[] · 方法参数")
        XCTAssertEqual(roots?["detail"] as? String, "TreeNode[] · 方法参数")
    }

    func testParametersDoNotLeakAcrossMethodsOrFromComments() throws {
        let source = """
        /** TreeNode root; TreeNode right; */
        class Solution {
            void first(TreeNode root) {}
            void second(int value) { ro
        """
        XCTAssertTrue(try identifierItems(source, prefix: "ro").isEmpty)
    }

    func testCurrentMethodLocalVariableStillCompletes() throws {
        let source = "class Solution { void f(TreeNode root) { int result = 0; res"
        let item = try XCTUnwrap(identifierItems(source, prefix: "res").first)
        XCTAssertEqual(item["text"] as? String, "result")
        XCTAssertEqual(item["detail"] as? String, "int · 局部变量")
    }

    private func identifierItems(_ source: String, prefix: String) throws -> [[String: Any]] {
        let value = context.objectForKeyedSubscript("javaIdentifierCompletionItems")
            .call(withArguments: [source, prefix])
        return try XCTUnwrap(value?.toArray() as? [[String: Any]])
    }

    private func memberTexts(_ source: String, owner: String, prefix: String = "") throws -> [String] {
        let value = context.objectForKeyedSubscript("javaMemberCompletionItems")
            .call(withArguments: [source, owner, prefix])
        let items = try XCTUnwrap(value?.toArray() as? [[String: Any]])
        return items.compactMap { $0["text"] as? String }
    }
}
