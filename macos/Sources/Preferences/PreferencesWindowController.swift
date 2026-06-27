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
        // See OnboardingWindowController: clearing sizingOptions stops the
        // hosting controller from mutating the window's size extrema during the
        // update-constraints pass, which otherwise crashes on first show.
        hosting.sizingOptions = []
        let window = NSWindow(contentViewController: hosting)
        window.title = "Preferences"
        // Toolbar-tab preferences are fixed-width; height adapts per tab.
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.isReleasedWhenClosed = false

        // Force an initial layout + explicit content size so the first tab renders
        // correctly on first open. Without this the hosting controller (sizingOptions
        // cleared to avoid a first-show crash) never gives the TabView a proper layout
        // pass, so the first tab shows wrong content until a tab switch. Notebook-
        // WindowController avoids this with an explicit setContentSize; do the same
        // here, but computed since the Preferences height varies per tab.
        hosting.view.layoutSubtreeIfNeeded()
        let fitting = hosting.view.fittingSize
        if fitting.width > 0, fitting.height > 0 {
            window.setContentSize(fitting)
        } else {
            // Fallback if the TabView can't report a usable fitting size: match
            // PreferencesView's fixed width (460 + 20pt padding each side) and a
            // height that comfortably fits the tallest tab.
            window.setContentSize(NSSize(width: 500, height: 460))
        }
        window.center()
        self.window = window

        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }
}
