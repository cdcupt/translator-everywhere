import AppKit
import SwiftUI

/// Owns the single Vocabulary Notebook window (DESIGN §2c).
///
/// The notebook is a real, standalone, resizable window (not a popover). An
/// `LSUIElement` agent has no main window, so we host the SwiftUI `NotebookView`
/// in an `NSWindow` we manage directly. `show()` creates it on first use and
/// brings it forward on subsequent opens.
@MainActor
final class NotebookWindowController {

    private let store: NotebookStore
    private let resolver: EngineResolver
    private var window: NSWindow?

    init(store: NotebookStore, resolver: EngineResolver = EngineResolver()) {
        self.store = store
        self.resolver = resolver
    }

    /// Brings the notebook window forward, creating it on first use.
    func show() {
        if let window {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            return
        }

        let root = NotebookView(store: store, resolver: resolver)
        let hosting = NSHostingController(rootView: root)
        // See OnboardingWindowController: clearing sizingOptions stops the
        // hosting controller from mutating the window's size extrema during the
        // update-constraints pass, which otherwise crashes on first show.
        hosting.sizingOptions = []
        let window = NSWindow(contentViewController: hosting)
        window.title = "Notebook"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.setContentSize(NSSize(width: 820, height: 520))
        window.contentMinSize = NSSize(width: 720, height: 420)
        window.isReleasedWhenClosed = false
        window.center()
        self.window = window

        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }
}
