import Foundation
import ServiceManagement

/// The login-item registration surface we depend on, abstracted so unit tests
/// can inject a fake instead of touching the real `SMAppService` (which mutates
/// the user's actual login items and requires a registered app bundle).
protocol LoginItemService {
    /// Whether the app is currently registered to launch at login.
    var isEnabled: Bool { get }

    /// Registers the app as a login item. Throws on failure.
    func register() throws

    /// Unregisters the app as a login item. Throws on failure.
    func unregister() throws
}

/// `SMAppService.mainApp` conformance — the production backing.
///
/// `SMAppService` maps `.enabled` status to `isEnabled` and surfaces
/// register/unregister directly. Requires macOS 13+; the app targets 14.
extension SMAppService: LoginItemService {
    var isEnabled: Bool { status == .enabled }
}

/// Launch-at-login toggle backed by `SMAppService.mainApp` (DESIGN §2d).
///
/// `SMAppService` is the single source of truth — we never mirror the state in
/// `UserDefaults`, so the toggle reflects the system's actual registration. The
/// service is injectable so the enabled/disabled mapping is unit-testable
/// without registering a real login item.
struct LaunchAtLogin {

    private let service: LoginItemService

    init(service: LoginItemService = SMAppService.mainApp) {
        self.service = service
    }

    /// Whether the app currently launches at login.
    var isEnabled: Bool { service.isEnabled }

    /// Turns launch-at-login on or off. Idempotent: enabling when already
    /// enabled (or disabling when already disabled) is a no-op. Throws if the
    /// underlying registration call fails.
    func setEnabled(_ enabled: Bool) throws {
        if enabled {
            guard !service.isEnabled else { return }
            try service.register()
        } else {
            guard service.isEnabled else { return }
            try service.unregister()
        }
    }
}
