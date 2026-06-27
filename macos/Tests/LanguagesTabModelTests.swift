import Foundation
import Testing
@testable import Translator_Everywhere

/// The Languages-tab "Last used" formatter (slice 8): renders the read-only
/// `From → To` line, mapping a nil From (Auto-detect) to "Auto".
@Suite("LanguagesTabModel — last-used summary")
struct LanguagesTabModelTests {

    private let zh = LanguageCatalog.language(forCode: "zh-CN")!
    private let en = LanguageCatalog.language(forCode: "en")!

    @Test("A nil From renders as Auto → endonym")
    func autoFrom() {
        let summary = LanguagesTabModel.lastUsedSummary(LanguagePair(from: nil, to: zh))
        #expect(summary == "Auto → \(zh.endonym)")
    }

    @Test("An explicit From renders both endonyms")
    func explicitFrom() {
        let summary = LanguagesTabModel.lastUsedSummary(LanguagePair(from: en, to: zh))
        #expect(summary == "\(en.endonym) → \(zh.endonym)")
    }
}

/// The Languages-tab binding/model layer (slice 8; beta B1/B2/B3). The SwiftUI
/// `View` body can't be unit-driven headlessly, so these test the pure helpers the
/// tab's bindings call: writing a chosen code through to `SettingsStore`, the
/// home==secondary warning condition, and the read-only "Last used" line.
@Suite("LanguagesTabModel — bindings, warning, last-used")
struct LanguagesTabBindingTests {

    private func makeSettings() -> SettingsStore {
        let suite = "LanguagesTabBindingTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return SettingsStore(defaults: defaults)
    }

    // B1 — choosing a home target writes the resolved language through to the store.
    @Test("apply(homeCode:) writes the resolved language to homeTarget")
    func applyHomeWritesThrough() {
        let settings = makeSettings()
        LanguagesTabModel.apply(homeCode: "ja", to: settings)
        #expect(settings.homeTarget.code == "ja")
    }

    // B1 — choosing a secondary writes the resolved language through to the store.
    @Test("apply(secondaryCode:) writes the resolved language to secondaryLanguage")
    func applySecondaryWritesThrough() {
        let settings = makeSettings()
        LanguagesTabModel.apply(secondaryCode: "ja", to: settings)
        #expect(settings.secondaryLanguage.code == "ja")
    }

    // B1 — an unresolvable code is ignored (no write, no crash).
    @Test("apply(homeCode:) ignores a code the catalog can't resolve")
    func applyHomeIgnoresUnknown() {
        let settings = makeSettings()
        LanguagesTabModel.apply(homeCode: "en", to: settings)
        LanguagesTabModel.apply(homeCode: "not-a-code", to: settings)
        #expect(settings.homeTarget.code == "en") // unchanged
    }

    // B2 — the warning fires only when home and secondary match.
    @Test("warnsHomeEqualsSecondary is true only when home == secondary")
    func warningCondition() {
        #expect(LanguagesTabModel.warnsHomeEqualsSecondary(home: "zh-CN", secondary: "zh-CN"))
        #expect(!LanguagesTabModel.warnsHomeEqualsSecondary(home: "zh-CN", secondary: "en"))
    }

    // B3 — the "Last used" line echoes the store's last-used pair.
    @Test("lastUsedSummary renders the store's last-used pair")
    func lastUsedFromStore() {
        let settings = makeSettings()
        let en = LanguageCatalog.language(forCode: "en")!
        let ja = LanguageCatalog.language(forCode: "ja")!
        settings.lastUsedPair = LanguagePair(from: en, to: ja)
        #expect(LanguagesTabModel.lastUsedSummary(settings.lastUsedPair)
                == "\(en.endonym) → \(ja.endonym)")
    }
}
