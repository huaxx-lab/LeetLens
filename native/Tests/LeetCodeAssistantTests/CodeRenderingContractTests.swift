import Foundation
import XCTest
@testable import LeetCodeAssistant

final class CodeRenderingContractTests: XCTestCase {
    func testRichRenderersUseOneSharedCodeBlockContract() throws {
        let conversation = try resource("conversation", extension: "html")
        let solution = try resource("solution", extension: "html")
        let graph = try resource("graph", extension: "html")
        let script = try resource("code-block", extension: "js")
        let stylesheet = try resource("code-block", extension: "css")

        for html in [conversation, solution, graph] {
            XCTAssertTrue(html.contains("code-block.css"))
            XCTAssertTrue(html.contains("code-block.js"))
            XCTAssertTrue(html.contains("window.CodeBlock"))
        }
        XCTAssertTrue(script.contains("canonicalLanguage"))
        XCTAssertTrue(script.contains("copyButton"))
        XCTAssertTrue(script.contains("showCopied"))
        XCTAssertTrue(script.contains("1200"))
        XCTAssertTrue(stylesheet.contains(".code-block"))
        XCTAssertTrue(stylesheet.contains(".code-head"))
        XCTAssertTrue(stylesheet.contains("min-width: max-content"))
    }

    func testEveryRichRendererCopiesThroughNativePasteboardBridge() throws {
        let conversation = try resource("conversation", extension: "html")
        let solution = try resource("solution", extension: "html")
        let graph = try resource("graph", extension: "html")

        XCTAssertTrue(conversation.contains("messageHandlers?.copyCode"))
        XCTAssertTrue(solution.contains("messageHandlers?.copyCode"))
        XCTAssertTrue(graph.contains("post('copyCode'"))
        XCTAssertFalse(solution.contains("navigator" + ".clipboard"))
    }

    func testGraphHandlesDetailCopyBeforePopupIsolation() throws {
        let graph = try resource("graph", extension: "html")
        let clickHandler = try XCTUnwrap(graph.range(of: "viewport.addEventListener('click'"))
        let copy = try XCTUnwrap(graph.range(of: "const copy = event.target.closest('.copy')", range: clickHandler.lowerBound..<graph.endIndex))
        let popup = try XCTUnwrap(graph.range(of: "if (inPopup(event.target)) return;", range: clickHandler.lowerBound..<graph.endIndex))

        XCTAssertLessThan(copy.lowerBound, popup.lowerBound)
    }

    /// 详情卡的交互契约。这几条一旦破掉，卡片就退回成"表单"：
    /// 拖不动、卡片里长出第二个滚动条、写完还要找保存按钮。
    func testGraphDetailCardBehavesLikeANote() throws {
        let graph = try resource("graph", extension: "html")

        // 顶栏能拖，拖过之后固定在用户放的位置。
        XCTAssertTrue(graph.contains("dt-grip"))
        XCTAssertTrue(graph.contains("event.target.closest('.dt-bar')"))
        XCTAssertTrue(graph.contains("detailOffset"))
        // 卡片内部不出现滚动条。
        XCTAssertTrue(graph.contains("#detail .dt-scroll::-webkit-scrollbar { width: 0; height: 0; display: none; }"))
        // 就地编辑：失焦即存，没有保存/取消按钮。
        XCTAssertTrue(graph.contains("area.onblur"))
        XCTAssertTrue(graph.contains("commitEdit"))
        XCTAssertFalse(graph.contains("'保存笔记'"))
        XCTAssertFalse(graph.contains("'发布评论'"))
        // 评论和笔记合成一种东西，桥上不再有评论通道。
        XCTAssertFalse(graph.contains("commentAdded"))
        XCTAssertFalse(graph.contains("commentRemoved"))
        // Shift 拖拽是建链接的快捷方式。
        XCTAssertTrue(graph.contains("event.shiftKey ? nodeAt(event.target) : null"))
        XCTAssertTrue(graph.contains("rubberwires"))
    }

    private func resource(_ name: String, extension fileExtension: String) throws -> String {
        let url = try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: fileExtension))
        return try String(contentsOf: url, encoding: .utf8)
    }
}
