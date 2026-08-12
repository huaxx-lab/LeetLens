import Foundation
import XCTest
@testable import LeetCodeAssistant

/// Two instances sharing one data directory clobber each other's JSON, so a second
/// launch must hand focus to the first rather than start a rival writer.
final class SingleInstanceGuardTests: XCTestCase {
    private let bundleID = "com.example.leetcode"

    func testFirstInstanceProceeds() {
        let decision = SingleInstanceGuard.decide(
            currentPID: 100,
            others: [(pid: 100, bundleIdentifier: bundleID)],
            bundleIdentifier: bundleID
        )
        XCTAssertEqual(decision, .proceed)
    }

    func testSecondInstanceDefersToTheRunningOne() {
        let decision = SingleInstanceGuard.decide(
            currentPID: 200,
            others: [
                (pid: 100, bundleIdentifier: bundleID),
                (pid: 200, bundleIdentifier: bundleID)
            ],
            bundleIdentifier: bundleID
        )
        XCTAssertEqual(decision, .activateExistingAndExit(pid: 100))
    }

    /// With several rivals the choice must be deterministic, not order-dependent.
    func testOldestRivalIsChosenDeterministically() {
        let ascending = SingleInstanceGuard.decide(
            currentPID: 400,
            others: [
                (pid: 300, bundleIdentifier: bundleID),
                (pid: 100, bundleIdentifier: bundleID)
            ],
            bundleIdentifier: bundleID
        )
        let descending = SingleInstanceGuard.decide(
            currentPID: 400,
            others: [
                (pid: 100, bundleIdentifier: bundleID),
                (pid: 300, bundleIdentifier: bundleID)
            ],
            bundleIdentifier: bundleID
        )
        XCTAssertEqual(ascending, .activateExistingAndExit(pid: 100))
        XCTAssertEqual(ascending, descending)
    }

    /// A different bundle is a deliberate side-by-side run (debug next to installed).
    func testOtherBundlesDoNotBlockLaunch() {
        let decision = SingleInstanceGuard.decide(
            currentPID: 200,
            others: [
                (pid: 100, bundleIdentifier: "com.example.other"),
                (pid: 200, bundleIdentifier: bundleID)
            ],
            bundleIdentifier: bundleID
        )
        XCTAssertEqual(decision, .proceed)
    }

    /// Without an identity we cannot tell rivals apart, so never block the launch.
    func testMissingBundleIdentifierNeverBlocks() {
        XCTAssertEqual(
            SingleInstanceGuard.decide(
                currentPID: 200,
                others: [(pid: 100, bundleIdentifier: nil)],
                bundleIdentifier: nil
            ),
            .proceed
        )
        XCTAssertEqual(
            SingleInstanceGuard.decide(
                currentPID: 200,
                others: [(pid: 100, bundleIdentifier: "")],
                bundleIdentifier: ""
            ),
            .proceed
        )
    }
}
