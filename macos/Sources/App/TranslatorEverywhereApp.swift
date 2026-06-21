import SwiftUI

/// SwiftUI entry point for the menu-bar agent.
///
/// The real UI lives in `AppDelegate` (an `NSStatusItem` + menu), because an
/// `LSUIElement` agent app has no main window and must drive AppKit directly.
/// We still declare a SwiftUI `App` so later slices can attach `Settings`,
/// `Window`, or `MenuBarExtra` scenes without restructuring the entry point.
@main
struct TranslatorEverywhereApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        // No window on launch: this is a menu-bar agent (LSUIElement).
        // `Settings` is an empty scene placeholder; PreferencesWindow arrives
        // in a later slice (TECH §8.1).
        Settings {
            EmptyView()
        }
    }
}
