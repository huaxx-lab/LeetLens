import SwiftUI
import XCTest
@testable import LeetCodeAssistant

final class InlineMarkdownTests: XCTestCase {
    func testRendersEmphasisAndCodeInsteadOfShowingRawMarks() {
        let value = InlineMarkdown.attributed("先看 **单调性**，再想 `nums[i]` 的取值范围")
        let plain = String(value.characters)

        XCTAssertFalse(plain.contains("**"), "加粗记号必须被渲染掉，不能原样显示")
        XCTAssertFalse(plain.contains("`"), "行内代码记号同理")
        XCTAssertTrue(plain.contains("单调性"))
        XCTAssertTrue(plain.contains("nums[i]"))

        let bolded = value.runs.contains { $0.inlinePresentationIntent?.contains(.stronglyEmphasized) == true }
        XCTAssertTrue(bolded)
        let monospaced = value.runs.contains { run in
            run.inlinePresentationIntent?.contains(.code) == true && run.font != nil
        }
        XCTAssertTrue(monospaced, "行内代码要换成等宽字体，否则和正文糊在一起")
    }

    func testKeepsLineBreaksSoAConclusionAndAQuestionStayApart() {
        let value = InlineMarkdown.attributed("结论在这里\n那你觉得起点该满足什么条件？")
        XCTAssertTrue(String(value.characters).contains("\n"))
    }

    func testFallsBackToPlainTextRatherThanLosingContent() {
        // 半个链接、没闭合的强调——模型偶尔会写出这种东西，内容不能因此消失。
        let broken = "看看 [边界](  和 **没关的加粗"
        let value = InlineMarkdown.attributed(broken)
        XCTAssertTrue(String(value.characters).contains("边界"))
        XCTAssertTrue(String(value.characters).contains("没关的加粗"))

        XCTAssertTrue(String(InlineMarkdown.attributed("   ").characters).isEmpty)
    }
}
