import AppKit
import SwiftUI

/// Owns the single Preferences window (DESIGN §2d).
///
/// An `LSUIElement` agent has no main window, so we host the SwiftUI
/// `PreferencesView` in an `NSWindow` we manage directly (same pattern as the
/// Notebook window). `show()` creates it on first use and brings it forward on
/// subsequent opens.
@MainActor
final class PreferencesWindowController {

    private let settings: SettingsStore
    private let keychain: KeychainStore
    private let launchAtLogin: LaunchAtLogin
    private let accountModel: AccountViewModel
    private var window: NSWindow?

    init(
        settings: SettingsStore = SettingsStore(),
        keychain: KeychainStore = KeychainStore(),
        launchAtLogin: LaunchAtLogin = LaunchAtLogin(),
        accountModel: AccountViewModel
    ) {
        self.settings = settings
        self.keychain = keychain
        self.launchAtLogin = launchAtLogin
        self.accountModel = accountModel
    }

    /// Brings the Preferences window forward, creating it on first use.
    func show() {
        if let window {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            return
        }

        let root = PreferencesView(
            settings: settings,
            keychain: keychain,
            launchAtLogin: launchAtLogin,
            accountModel: accountModel
        )
        let hosting = NSHostingController(rootView: root)
        let window = NSWindow(contentViewController: hosting)
        window.title = "Preferences"
        // Toolbar-tab preferences are fixed-width; height adapts per tab.
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.isReleasedWhenClosed = false
        window.center()
        self.window = window

        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }
}
