import Foundation
import XCTest
@testable import LeetCodeAssistant

/// 装到 /Applications 之后，沿可执行文件向上走再也到不了仓库里的 node_modules。
/// 这条链路一断，评分、提交检测、力扣提交合并会**一起**失败，而界面上只显示
/// "没有找到原项目学习引擎运行环境"，很难看出是同一个原因。
final class LearningEngineBridgeTests: XCTestCase {
    func testBridgeResolvesElectronThroughDataDirectoryHint() throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "ElectronHint-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        // 一个可执行的替身就够：这里验证的是"提示文件有没有被读到"，不是 Electron 本身。
        let fake = directory.appending(path: "FakeElectron")
        try "#!/bin/sh\nexit 0\n".write(to: fake, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fake.path)
        try JSONSerialization.data(withJSONObject: ["path": fake.path])
            .write(to: directory.appending(path: "electron-bridge.json"), options: .atomic)

        XCTAssertEqual(
            ChatService.locateElectronExecutable(dataDirectory: directory)?.path,
            fake.path,
            "数据目录里的提示必须被读到，否则安装版永远找不到学习引擎"
        )
    }

    func testMissingHintIsNotSilentlySatisfiedByAnUnrelatedPath() throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "ElectronNoHint-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try JSONSerialization.data(withJSONObject: ["path": directory.appending(path: "gone").path])
            .write(to: directory.appending(path: "electron-bridge.json"), options: .atomic)

        // 提示指向一个不存在的文件时不能直接采信；要么继续找，要么老实返回 nil。
        let resolved = ChatService.locateElectronExecutable(dataDirectory: directory)
        if let resolved {
            XCTAssertTrue(
                FileManager.default.isExecutableFile(atPath: resolved.path),
                "返回的路径必须真的可执行"
            )
        }
    }

    /// 真机自检：数据目录里有提示、Electron 也在，就要能真的跑通一次引擎往返。
    func testLiveBridgeRoundTripWhenRuntimeIsPresent() async throws {
        let dataDirectory = URL(filePath: NSString(string: "~/Library/Application Support/leetcode-ai-helper/data").expandingTildeInPath)
        guard FileManager.default.fileExists(atPath: dataDirectory.appending(path: "learning.json").path),
              ChatService.locateElectronExecutable(dataDirectory: dataDirectory) != nil
        else { throw XCTSkip("本机没有学习引擎运行环境") }

        let bridge = LearningEngineBridge(dataDirectory: dataDirectory)
        // 只读一次设置写回：不改任何学习数据，但会完整走一遍 Electron 往返。
        let store = await MainActor.run { LegacyDataStore(dataDirectory: dataDirectory) }
        await store.hydrate()
        let current = await MainActor.run { store.learningSettings }
        try await bridge.updateSettings(
            dailyNewTarget: current.dailyNewTarget,
            weekdayReviewTarget: current.weekdayReviewTarget,
            weeklyReviewTarget: current.weeklyReviewTarget,
            preferredLanguage: current.preferredLanguage
        )
    }
}
