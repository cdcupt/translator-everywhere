import AppKit
import Testing
@testable import Translator_Everywhere

/// The result panel's engine badge + header chips (beta A9/A10). Drives the pure
/// badge-color helper and the real header-population path headlessly (no window)
/// and asserts FREE-vs-AI rendering plus the conditional "via Google" / "Copied ✓"
/// notes.
@MainActor
@Suite("ResultPanel — badge color + header chips")
struct ResultPanelHeaderTests {

    // A9 — the badge renders the AI engine in purple and FREE in blue.
    @Test("Badge color is purple for AI and blue for FREE")
    func badgeColor() {
        #expect(ResultPanel.badgeColor(for: "AI") == .systemPurple)
        #expect(ResultPanel.badgeColor(for: "FREE") == .systemBlue)
        #expect(ResultPanel.badgeColor(for: "AI") != ResultPanel.badgeColor(for: "FREE"))
    }

    // A10 — the "via Google" note renders only on an AI→Google fallback.
    @Test("\"via Google\" note appears only when viaGoogleFallback is true")
    func viaGoogleNote() {
        let panel = ResultPanel()
        #expect(headerLabels(panel, viaGoogleFallback: true).contains("via Google"))
        #expect(!headerLabels(panel, viaGoogleFallback: false).contains("via Google"))
    }

    // A10 (surface) — the "Copied ✓" affordance is conditional on a copy.
    @Test("\"Copied ✓\" appears only after a copy")
    func copiedChip() {
        let panel = ResultPanel()
        #expect(headerLabels(panel, copied: true).contains("Copied ✓"))
        #expect(!headerLabels(panel, copied: false).contains("Copied ✓"))
    }

    /// Populates a fresh header stack via the panel's real builder and returns its
    /// top-level text chips. The badge text lives inside a nested container, so the
    /// top-level `NSTextField`s are exactly the "via Google" / "Copied ✓" notes.
    private func headerLabels(
        _ panel: ResultPanel, badge: String = "AI",
        copied: Bool = false, viaGoogleFallback: Bool = false
    ) -> [String] {
        let header = NSStackView()
        panel.populateHeader(header, badge: badge, copied: copied,
                             viaGoogleFallback: viaGoogleFallback, onSave: nil)
        return header.arrangedSubviews.compactMap { ($0 as? NSTextField)?.stringValue }
    }
}
