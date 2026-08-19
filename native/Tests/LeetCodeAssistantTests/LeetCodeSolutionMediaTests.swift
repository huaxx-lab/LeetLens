import XCTest
@testable import LeetCodeAssistant

final class LeetCodeSolutionMediaTests: XCTestCase {
    func testExtractsAndDeduplicatesOfficialVideoUUIDs() {
        let markdown = """
        ![1.两数之和.mp4](4547de8a-5963-4caf-9281-c22ee751ab12)
        ![重复](4547DE8A-5963-4CAF-9281-C22EE751AB12)
        ![普通图片](https://assets.leetcode.cn/example.png)
        """

        XCTAssertEqual(
            LeetCodeAPIClient.solutionVideoUUIDs(in: markdown),
            ["4547de8a-5963-4caf-9281-c22ee751ab12"]
        )
    }

    func testSolutionCardViewsLabelUsesChineseUnits() {
        XCTAssertEqual(LeetCodeAPIClient.viewsLabel(0), "")
        XCTAssertEqual(LeetCodeAPIClient.viewsLabel(860), "860浏览")
        XCTAssertEqual(LeetCodeAPIClient.viewsLabel(71_000), "7.1万浏览")
    }
}
