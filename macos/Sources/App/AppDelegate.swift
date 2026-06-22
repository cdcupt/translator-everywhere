import AppKit

/// Owns the menu-bar presence and routes menu actions.
///
/// TECH §8.1: installs the `NSStatusItem`, builds the menu, and will later wire
/// the global hotkey (`HotkeyManager`) and route "Capture & Translate" into the
/// `CaptureCoordinator` actor. For slice 1 every action is a logging stub.
final class AppDelegate: NSObject, NSApplicationDelegate {

    /// Strong reference; an `NSStatusItem` is removed from the bar when released.
    private var statusItem: NSStatusItem?

    /// The result UI (main-actor AppKit). Owned here for the app's lifetime.
    private let resultPanel = ResultPanel()

    /// The off-main capture state machine.
    private lazy var coordinator = CaptureCoordinator(resultPanel: resultPanel)

    /// The global hotkey owner. Fires the same path as the menu item.
    private lazy var hotkeyManager = HotkeyManager { [weak self] in
        self?.runCapture()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        installStatusItem()
        hotkeyManager.start()
    }

    /// Kicks one capture→OCR→show cycle on the coordinator actor.
    private func runCapture() {
        Task { await coordinator.captureAndTranslate() }
    }

    // MARK: - Status item

    private func installStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        if let button = item.button {
            // The 译 glyph is the brand mark. We render it as a button title with
            // a monospaced-digit-friendly system font so it sits cleanly in the
            // bar; an SF Symbol / template image asset replaces this in a later
            // slice once icons.html assets are wired in.
            button.title = "译"
            button.font = .systemFont(ofSize: 14, weight: .semibold)
            button.toolTip = "Translator Everywhere"
        }

        item.menu = makeMenu()
        statusItem = item
    }

    private func makeMenu() -> NSMenu {
        let menu = NSMenu()

        menu.addItem(menuItem(title: "Capture & Translate",
                              action: #selector(captureAndTranslate),
                              key: "y",
                              modifiers: [.control, .option]))
        menu.addItem(.separator())
        menu.addItem(menuItem(title: "Open Notebook…",
                              action: #selector(openNotebook)))
        menu.addItem(menuItem(title: "Preferences…",
                              action: #selector(openPreferences),
                              key: ","))
        menu.addItem(.separator())
        menu.addItem(menuItem(title: "About Translator Everywhere",
                              action: #selector(showAbout)))
        menu.addItem(.separator())
        menu.addItem(menuItem(title: "Quit Translator Everywhere",
                              action: #selector(quit),
                              key: "q"))

        return menu
    }

    private func menuItem(title: String,
                          action: Selector,
                          key: String = "",
                          modifiers: NSEvent.ModifierFlags? = nil) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        if let modifiers {
            item.keyEquivalentModifierMask = modifiers
        }
        return item
    }

    // MARK: - Menu actions (slice-1 stubs)

    @objc private func captureAndTranslate() {
        runCapture()
    }

    @objc private func openNotebook() {
        // TODO(slice: notebook): present NotebookWindow (SwiftUI Table).
        NSLog("[TE] Open Notebook — not implemented yet")
    }

    @objc private func openPreferences() {
        // TODO(slice: prefs): present PreferencesWindow.
        NSLog("[TE] Preferences — not implemented yet")
    }

    @objc private func showAbout() {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(nil)
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
