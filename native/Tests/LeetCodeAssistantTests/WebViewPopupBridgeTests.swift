import Foundation
import Testing
@testable import LeetCodeAssistant

@Suite("网页弹窗尺寸")
@MainActor
struct WebViewPopupBridgeTests {
    @Test("站点没给尺寸时用够放二维码的默认值")
    func fallsBackToQRFriendlySize() {
        let size = WebViewPopupBridge.popupSize(width: nil, height: nil)
        #expect(size.width == 480)
        #expect(size.height == 620)
    }

    @Test("站点给的尺寸原样采用")
    func honoursRequestedSize() {
        let size = WebViewPopupBridge.popupSize(width: 420, height: 520)
        #expect(size.width == 420)
        #expect(size.height == 520)
    }

    @Test("过小的尺寸抬到下限，免得二维码被裁掉")
    func clampsTooSmall() {
        let size = WebViewPopupBridge.popupSize(width: 100, height: 80)
        #expect(size.width == 380)
        #expect(size.height == 420)
    }

    @Test("过大的尺寸压到上限，免得弹窗比屏幕还大")
    func clampsTooLarge() {
        let size = WebViewPopupBridge.popupSize(width: 4_000, height: 3_000)
        #expect(size.width == 1_200)
        #expect(size.height == 900)
    }
}
