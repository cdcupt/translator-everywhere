import AppKit
import SwiftUI

/// Owns the first-run onboarding window (DESIGN §2f).
///
/// Gated on `SettingsStore.didOnboard`: `presentIfNeeded()` shows the window
/// only on the first launch (or whenever the flag is still unset). When the
/// flow reaches Done and the user dismisses it, the flag is set and the window
/// closes. Reusable via `present()` for the "hotkey pressed while ungranted"
/// path, which reopens onboarding regardless of the flag.
@MainActor
final class OnboardingWindowController {

    private let settings: SettingsStore
    private let permission: PermissionService
    private var window: NSWindow?
    private var model: OnboardingModel?

    init(
        settings: SettingsStore = SettingsStore(),
        permission: PermissionService = PermissionService()
    ) {
        self.settings = settings
        self.permission = permission
    }

    /// Shows onboarding only if the user hasn't completed it yet.
    func presentIfNeeded() {
        guard !settings.didOnboard else { return }
        present()
    }

    /// Shows the onboarding window, creating it on first use and bringing it
    /// forward thereafter. Used both for first-run and the ungranted-hotkey path.
    func present() {
        if let window {
            // Re-check in case permission changed while hidden.
            model?.recheck()
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            return
        }

        let model = OnboardingModel(permission: permission) { [weak self] in
            self?.finish()
        }
        let hosting = NSHostingController(rootView: OnboardingView(model: model))
        let window = NSWindow(contentViewController: hosting)
        window.title = "Welcome"
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        window.center()

        self.model = model
        self.window = window

        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    /// Records completion and closes the window.
    private func finish() {
        settings.didOnboard = true
        window?.close()
    }
}
