import AppKit
import Sparkle

/// Owns the menu-bar presence and routes menu actions.
///
/// TECH §8.1: installs the `NSStatusItem`, builds the menu, and will later wire
/// the global hotkey (`HotkeyManager`) and route "Capture & Translate" into the
/// `CaptureCoordinator` actor. For slice 1 every action is a logging stub.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    /// Strong reference; an `NSStatusItem` is removed from the bar when released.
    private var statusItem: NSStatusItem?

    /// Sparkle's standard updater. Constructed once with `startingUpdater: true`
    /// so the daily background-check schedule (driven by the Info.plist keys
    /// `SUEnableAutomaticChecks` / `SUScheduledCheckInterval`) starts at launch.
    /// The appcast feed + EdDSA verification are configured via Info.plist; the
    /// release pipeline owns the signed appcast.
    private let updaterController = SPUStandardUpdaterController(
        startingUpdater: true,
        updaterDelegate: nil,
        userDriverDelegate: nil
    )

    /// The result UI (main-actor AppKit). Owned here for the app's lifetime.
    /// Lazy so it shares the single `settings` store (declared below) — the same
    /// one the coordinator uses — instead of allocating its own (keeps Recent and
    /// the home-target fallback consistent with the live preferences).
    private lazy var resultPanel = ResultPanel(settings: settings)

    /// The local vocabulary notebook (SwiftData). `nil` only if the store can't
    /// be opened — capture still works, the result panel just won't offer the
    /// "Save to Notebook" button.
    private lazy var notebook: NotebookStore? = {
        do { return try NotebookStore() }
        catch {
            NSLog("[TE] Notebook store failed to open: \(error.localizedDescription)")
            return nil
        }
    }()

    /// Lazily-created controller for the standalone Notebook window.
    private lazy var notebookWindow: NotebookWindowController? =
        notebook.map { NotebookWindowController(store: $0) }

    /// Non-secret preferences (engine choice + onboarding flag).
    private let settings = SettingsStore()

    /// Screen-recording permission gate, shared with onboarding.
    private let permission = PermissionService()

    /// Sign-in + token storage (Keychain). The app works fully signed-out.
    private let authClient = AuthClient()

    /// Background cloud-sync actor, built only when a notebook store exists.
    /// `nil` if the store couldn't open — capture still works locally.
    private lazy var syncClient: SyncClient? = notebook.map { store in
        SyncClient(
            store: store,
            auth: AuthClientSyncProvider(authClient),
            cursors: DefaultsCursorStore()
        )
    }

    /// Account-tab state machine; sign-in triggers a full push+pull.
    private lazy var accountModel = AccountViewModel(
        auth: authClient,
        onSignedIn: { [weak self] in
            // A fresh sign-in resets the cursor so the first pull is full.
            self?.settings.lastSyncedAt = nil
            return await self?.syncClient?.sync(trigger: .signIn) ?? nil
        },
        onSignedOut: { /* tokens already cleared; nothing local to undo */ }
    )

    /// The Preferences window (General / Engine / Account / About).
    private lazy var preferencesWindow =
        PreferencesWindowController(settings: settings, accountModel: accountModel)

    /// First-run onboarding window; also the ungranted-hotkey destination.
    private lazy var onboardingWindow =
        OnboardingWindowController(settings: settings, permission: permission)

    /// The off-main capture state machine.
    private lazy var coordinator = CaptureCoordinator(
        settings: settings, resultPanel: resultPanel, notebook: notebook
    )

    /// The global hotkey owner. Fires the same path as the menu item.
    private lazy var hotkeyManager = HotkeyManager { [weak self] in
        self?.runCapture()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        installStatusItem()
        hotkeyManager.start()
        // The unit-test bundle hosts this app; don't pop the onboarding window
        // (or any UI) during the test runner's launch, which has no display
        // session and would crash the host before tests connect.
        guard !Self.isRunningTests else { return }
        onboardingWindow.presentIfNeeded()
    }

    /// On app foreground, pull anything changed on another Mac, then push local
    /// dirty rows. A no-op when signed out. Best-effort: never blocks the UI.
    func applicationDidBecomeActive(_ notification: Notification) {
        guard !Self.isRunningTests else { return }
        Task { [weak self] in
            guard let synced = await self?.syncClient?.sync(trigger: .foreground) else { return }
            await self?.accountModel.noteSynced(at: synced)
        }
    }

    /// `true` when the process is hosting the XCTest bundle.
    private static var isRunningTests: Bool {
        NSClassFromString("XCTestCase") != nil
            || ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }

    /// Kicks one capture→OCR→show cycle — but if Screen Recording isn't granted
    /// yet, route to onboarding step 2 instead of capturing (DESIGN §2f). A
    /// fresh grant only takes effect after relaunch, so we never try to capture
    /// while ungranted.
    private func runCapture() {
        guard permission.isGranted else {
            onboardingWindow.present()
            return
        }
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

    /// Builds the status-bar menu. Non-private so the test bundle can assert the
    /// menu wiring (e.g. the "Check for Updates…" item) via `@testable import`.
    func makeMenu() -> NSMenu {
        let menu = NSMenu()

        menu.addItem(menuItem(title: "Capture & Translate",
                              action: #selector(captureAndTranslate),
                              key: "y",
                              modifiers: [.control, .option]))
        menu.addItem(.separator())
        menu.addItem(menuItem(title: "Open Notebook…",
                              action: #selector(openNotebook),
                              key: "n",
                              modifiers: [.control, .option]))
        menu.addItem(menuItem(title: "Preferences…",
                              action: #selector(openPreferences),
                              key: ","))
        menu.addItem(.separator())
        // Sparkle in-app update. We route through AppDelegate and forward to the
        // updater so the menu item keeps AppDelegate as its target like the rest
        // of the menu; the updater still validates availability via the forward.
        menu.addItem(menuItem(title: "Check for Updates…",
                              action: #selector(checkForUpdates)))
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
        guard let notebookWindow else {
            NSLog("[TE] Open Notebook — store unavailable")
            return
        }
        notebookWindow.show()
    }

    @objc private func openPreferences() {
        preferencesWindow.show()
    }

    @objc private func checkForUpdates() {
        updaterController.checkForUpdates(nil)
    }

    @objc private func showAbout() {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(nil)
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
