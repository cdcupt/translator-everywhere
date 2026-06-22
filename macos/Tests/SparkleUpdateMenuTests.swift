import AppKit
import Testing
@testable import Translator_Everywhere

/// Sanity coverage for the Sparkle auto-update wiring. The updater itself is
/// framework glue (verified by the build embedding Sparkle.framework), so we
/// only assert that the status menu actually surfaces a working "Check for
/// Updates…" entry — the user-facing contract of the integration.
@MainActor
@Suite("Sparkle update — menu wiring")
struct SparkleUpdateMenuTests {

    @Test("status menu contains a Check for Updates… item")
    func menuHasCheckForUpdates() {
        let delegate = AppDelegate()
        let menu = delegate.makeMenu()
        let titles = menu.items.map(\.title)
        #expect(titles.contains("Check for Updates…"))
    }

    @Test("the Check for Updates… item has an action and a target")
    func checkForUpdatesIsWired() {
        // Keep `delegate` alive for the assertions: NSMenuItem.target is weak, so
        // a transient AppDelegate would deallocate and the target would read nil.
        let delegate = AppDelegate()
        let menu = delegate.makeMenu()
        let item = menu.items.first { $0.title == "Check for Updates…" }
        #expect(item != nil)
        #expect(item?.action != nil)
        #expect(item?.target as? AppDelegate === delegate)
    }
}
