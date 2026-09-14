import Foundation

extension Bundle {
    /// SwiftPM generates `Bundle.module` which searches adjacent to the executable or in
    /// the build-time scratch directory. When packaged into a macOS `.app`, resource
    /// bundles reside in `Contents/Resources/` (as required by code signing to avoid
    /// unsealed contents errors), while the `$TMPDIR` build scratch directory is
    /// eventually purged by macOS. When both fail, `Bundle.module` triggers a runtime fatalError.
    ///
    /// Resolving via `Bundle.main.resourceURL` first allows packaged `.app` bundles
    /// as well as `swift run` development modes to find bundled resources reliably.
    static let appResources: Bundle = {
        let bundleName = "LeetCodeAssistant_LeetCodeAssistant.bundle"
        if let url = Bundle.main.resourceURL,
           let bundle = Bundle(url: url.appendingPathComponent(bundleName)) {
            return bundle
        }
        return .module
    }()
}
