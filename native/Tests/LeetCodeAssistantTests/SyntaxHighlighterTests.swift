import SwiftUI
import XCTest
@testable import LeetCodeAssistant

@MainActor
final class SyntaxHighlighterTests: XCTestCase {
    /// 提交出错时「失败用例 / 实际输出」走这里。旧实现把每个 token 用 `Text + Text` 串起来，
    /// 约 6 000 个 token 就把主线程栈打穿（2.3.1 的两份崩溃报告都是这个栈）。
    /// 这里用 3 000 个数字（仍在着色阈值内、token 数超过崩溃线）真正排一次版。
    func testLargeFailingCaseRendersWithoutDeepTextConcatenation() {
        let input = "[" + (0..<3_000).map(String.init).joined(separator: ",") + "]"
        XCTAssertLessThan(input.utf16.count, SyntaxCodeHighlighter.highlightCharacterLimit)

        let rendered = SyntaxCodeHighlighter.render(input)
        XCTAssertEqual(String(rendered.text.characters), input)
        XCTAssertFalse(rendered.isTruncated)
        XCTAssertGreaterThan(rendered.runCount, 1, "阈值内仍然要着色")

        let renderer = ImageRenderer(content: Text(rendered.text).textSelection(.enabled).frame(width: 600))
        XCTAssertNotNil(renderer.nsImage)
    }

    func testAdjacentTokensWithSameStyleShareOneRun() {
        // 标识符、括号、空白都是 plain，必须合并成一段。
        let plain = SyntaxCodeHighlighter.render("foo(bar, baz)")
        XCTAssertEqual(plain.runCount, 1)
        XCTAssertEqual(String(plain.text.characters), "foo(bar, baz)")

        // 数字与逗号交替：数字一段、逗号一段，不会每个字符各一段。
        let numbers = SyntaxCodeHighlighter.render("1,2,3")
        XCTAssertEqual(numbers.runCount, 5)
    }

    func testHugeOutputSkipsHighlightingAndTruncatesDisplayOnly() {
        let input = String(repeating: "1234567890,", count: 10_000)
        let rendered = SyntaxCodeHighlighter.render(input)

        XCTAssertTrue(rendered.isTruncated)
        XCTAssertEqual(rendered.source, input, "复制按钮依赖完整原文")
        let visible = String(rendered.text.characters)
        XCTAssertTrue(visible.hasPrefix(String(input.prefix(1_000))))
        XCTAssertTrue(visible.contains("内容过长"))
        XCTAssertLessThan(visible.utf16.count, SyntaxCodeHighlighter.displayCharacterLimit + 200)
        XCTAssertEqual(rendered.runCount, 2, "超过着色阈值只剩正文一段 + 截断说明一段")
    }

    func testTruncationNeverSplitsSurrogatePairs() {
        let limit = SyntaxCodeHighlighter.displayCharacterLimit
        let input = String(repeating: "a", count: limit - 1) + String(repeating: "😀", count: 10)
        let rendered = SyntaxCodeHighlighter.render(input)
        let body = String(rendered.text.characters).components(separatedBy: "\n\n……").first ?? ""
        XCTAssertFalse(body.unicodeScalars.contains { $0.value == 0xFFFD })
        XCTAssertLessThanOrEqual(body.utf16.count, limit)
    }
}
