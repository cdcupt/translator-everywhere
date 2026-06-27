import AppKit
import Testing
@testable import Translator_Everywhere

/// The language-bar controller's pick → new-pair transforms (beta A2/A3/A6/A12).
/// Drives the From/To/⇄ intents directly — the `applyFrom`/`applyTo` the picker
/// callbacks invoke and the public swap delegate — and asserts the committed
/// `LanguagePair` via `onPick`, plus that the bar initializes from an injected
/// last-used pair. The searchable popover itself is validated on-device.
@MainActor
@Suite("LanguageBarController — pick → pair, swap, last-used init")
struct LanguageBarControllerTests {

    private let zh = LanguageCatalog.language(forCode: "zh-CN")!
    private let en = LanguageCatalog.language(forCode: "en")!
    private let ja = LanguageCatalog.language(forCode: "ja")!

    private func makeController(
        pair: LanguagePair, detected: DetectedSource = .unavailable
    ) -> LanguageBarController {
        LanguageBarController(pair: pair, detected: detected, recentProvider: { [] })
    }

    private func makeSettings() -> SettingsStore {
        let suite = "LanguageBarControllerTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return SettingsStore(defaults: defaults)
    }

    // A3 — picking a To language commits (From preserved, new To).
    @Test("Picking a To language produces the new pair with From preserved")
    func pickToProducesPair() {
        let controller = makeController(pair: LanguagePair(from: nil, to: zh))
        var picked: LanguagePair?
        controller.onPick = { picked = $0 }
        controller.applyTo(.language(ja))
        #expect(picked == LanguagePair(from: nil, to: ja))
    }

    // A2 — the From control accepts the Auto-detect choice (→ from nil).
    @Test("Picking Auto on From clears the explicit source; a language sets it")
    func pickAutoClearsFrom() {
        let controller = makeController(pair: LanguagePair(from: en, to: zh))
        var picked: LanguagePair?
        controller.onPick = { picked = $0 }
        controller.applyFrom(.auto)
        #expect(picked == LanguagePair(from: nil, to: zh))
        controller.applyFrom(.language(ja))
        #expect(picked == LanguagePair(from: ja, to: zh))
    }

    // A3 guard — re-picking the shown pair is a no-op (no needless retranslate).
    @Test("Re-picking the current To does not fire onPick")
    func noOpWhenUnchanged() {
        let controller = makeController(pair: LanguagePair(from: nil, to: zh))
        var calls = 0
        controller.onPick = { _ in calls += 1 }
        controller.applyTo(.language(zh))
        #expect(calls == 0)
    }

    // A6 — explicit From ↔ To swap.
    @Test("Swap exchanges an explicit From and To")
    func swapExplicit() {
        let controller = makeController(pair: LanguagePair(from: en, to: zh))
        var picked: LanguagePair?
        controller.onPick = { picked = $0 }
        controller.languageBarDidTapSwap(LanguageBarView())
        #expect(picked == LanguagePair(from: zh, to: en))
    }

    // A6 — Auto + detected: the concrete source (detected) becomes the new To and
    // the old target becomes From (controller's documented swap: source → To,
    // old To → From — i.e. "translate the other way").
    @Test("Swap under Auto promotes detected to To and the old target to From")
    func swapAutoDetected() {
        let controller = makeController(
            pair: LanguagePair(from: nil, to: zh),
            detected: .identified(ja, confidence: nil))
        var picked: LanguagePair?
        controller.onPick = { picked = $0 }
        controller.languageBarDidTapSwap(LanguageBarView())
        #expect(picked == LanguagePair(from: zh, to: ja))
    }

    // A6 — Auto with no detection has no concrete source: swap is a no-op.
    @Test("Swap is a no-op when From is Auto and nothing was detected")
    func swapAutoNoDetection() {
        let controller = makeController(
            pair: LanguagePair(from: nil, to: zh), detected: .unavailable)
        var calls = 0
        controller.onPick = { _ in calls += 1 }
        controller.languageBarDidTapSwap(LanguageBarView())
        #expect(calls == 0)
    }

    // A12 — the bar initializes its From/To from the injected last-used pair.
    @Test("Controller renders the injected last-used pair on init")
    func initFromLastUsedPair() {
        let settings = makeSettings()
        settings.lastUsedPair = LanguagePair(from: en, to: ja)
        let controller = makeController(pair: settings.lastUsedPair)
        let bar = controller.view as! LanguageBarView
        #expect(bar.fromButton.title == "From: \(en.endonym)  ▾")
        #expect(bar.toButton.title == "To: \(ja.endonym)  ▾")
    }
}
