import AppKit
import CoreGraphics

/// Screen-recording permission gate (TECH §8.1, §8.6b).
///
/// Wraps `CGPreflightScreenCaptureAccess()` / `CGRequestScreenCaptureAccess()`
/// and deep-links to the Screen Recording pane in System Settings. macOS only
/// honours a *newly* granted screen-recording permission after the app is
/// relaunched, so the coordinator must surface that relaunch hint (§8.6b).
struct PermissionService {

    /// System Settings deep link for the Screen Recording privacy pane.
    static let screenCaptureSettingsURL =
        "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"

    /// The grant check. Injected so the capture flow is unit-testable without the
    /// real (un-mockable) `CGPreflightScreenCaptureAccess()`.
    private let grantedCheck: () -> Bool

    /// Default initializer reads the live system grant.
    init() {
        self.grantedCheck = { CGPreflightScreenCaptureAccess() }
    }

    /// Test seam: inject a fixed grant state.
    init(isGranted: Bool) {
        self.grantedCheck = { isGranted }
    }

    /// Non-prompting check the coordinator calls *before* capturing.
    /// Returns `true` only when screen-recording access is already granted.
    var isGranted: Bool {
        grantedCheck()
    }

    /// Same as `isGranted`; kept for call-site readability.
    func hasScreenCaptureAccess() -> Bool {
        grantedCheck()
    }

    /// Prompts for screen-recording access. The system shows its own dialog the
    /// first time; thereafter it is a no-op and the user must use Settings.
    ///
    /// - Returns: `true` if access is already granted at call time. A fresh
    ///   grant still requires a relaunch before capture works (§8.6b).
    @discardableResult
    func requestAccess() -> Bool {
        CGRequestScreenCaptureAccess()
    }

    /// Opens the Screen Recording pane in System Settings so the user can toggle
    /// access on. No-ops if the URL cannot be constructed.
    func openSettings() {
        guard let url = URL(string: Self.screenCaptureSettingsURL) else { return }
        NSWorkspace.shared.open(url)
    }
}
