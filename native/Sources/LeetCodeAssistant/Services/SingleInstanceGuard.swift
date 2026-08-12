import AppKit
import Foundation

/// Restores the Electron client's single-instance behaviour.
///
/// Every store mutation is a read-modify-write over shared JSON in Application Support.
/// Two concurrent instances therefore silently clobber each other: whoever writes last
/// wins, and the other process's conversations or settings simply disappear. The old
/// client held a single-instance lock; the native entry point had none.
enum SingleInstanceGuard {
    /// What a launching instance should do about the processes already running.
    enum Decision: Equatable {
        case proceed
        /// Another instance owns the data directory; hand focus over and exit.
        case activateExistingAndExit(pid: pid_t)
    }

    /// Pure decision function so the policy is testable without launching apps.
    ///
    /// `others` should exclude the current process. Only instances of the *same* bundle
    /// count — a debug build sitting next to the installed app is a deliberate
    /// side-by-side run, not an accidental double launch.
    static func decide(currentPID: pid_t, others: [(pid: pid_t, bundleIdentifier: String?)],
                       bundleIdentifier: String?) -> Decision {
        guard let bundleIdentifier, !bundleIdentifier.isEmpty else { return .proceed }
        let rivals = others
            .filter { $0.pid != currentPID && $0.bundleIdentifier == bundleIdentifier }
            .map(\.pid)
            .sorted()
        guard let first = rivals.first else { return .proceed }
        return .activateExistingAndExit(pid: first)
    }

    /// Applies the policy at launch. Returns true when this process may continue.
    @discardableResult
    @MainActor
    static func enforce() -> Bool {
        let identifier = Bundle.main.bundleIdentifier
        guard let identifier, !identifier.isEmpty else { return true }

        let running = NSRunningApplication
            .runningApplications(withBundleIdentifier: identifier)
            .map { (pid: $0.processIdentifier, bundleIdentifier: $0.bundleIdentifier) }
        let decision = decide(
            currentPID: ProcessInfo.processInfo.processIdentifier,
            others: running,
            bundleIdentifier: identifier
        )

        switch decision {
        case .proceed:
            return true
        case .activateExistingAndExit(let pid):
            NSRunningApplication(processIdentifier: pid)?
                .activate(options: [.activateAllWindows])
            NSApplication.shared.terminate(nil)
            return false
        }
    }
}
