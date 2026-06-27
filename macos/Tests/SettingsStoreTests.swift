import Foundation
import Testing
@testable import Translator_Everywhere

@Suite("SettingsStore — persistence round-trips")
struct SettingsStoreTests {

    /// A `SettingsStore` over an isolated, in-memory `UserDefaults` suite so the
    /// test never touches the real defaults.
    private func makeStore() -> (SettingsStore, UserDefaults, String) {
        let suite = "SettingsStoreTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return (SettingsStore(defaults: defaults), defaults, suite)
    }

    @Test("enginePreference defaults to .free")
    func enginePreferenceDefault() {
        let (store, _, _) = makeStore()
        #expect(store.enginePreference == .free)
    }

    @Test("enginePreference round-trips through a fresh store")
    func enginePreferenceRoundTrip() {
        let (store, defaults, _) = makeStore()
        store.enginePreference = .openai
        #expect(store.enginePreference == .openai)
        // A new store over the same defaults sees the persisted value.
        #expect(SettingsStore(defaults: defaults).enginePreference == .openai)
    }

    @Test("didOnboard defaults to false")
    func didOnboardDefault() {
        let (store, _, _) = makeStore()
        #expect(store.didOnboard == false)
    }

    @Test("didOnboard round-trips through a fresh store")
    func didOnboardRoundTrip() {
        let (store, defaults, _) = makeStore()
        store.didOnboard = true
        #expect(store.didOnboard == true)
        #expect(SettingsStore(defaults: defaults).didOnboard == true)
    }

    // MARK: - Language pair (slice 5)

    @Test("First-read defaults reproduce Auto → 中文 + secondary English")
    func languageDefaults() {
        let (store, _, _) = makeStore()
        // Home target = Simplified Chinese, secondary = English.
        #expect(store.homeTarget.code == "zh-CN")
        #expect(store.secondaryLanguage.code == "en")
        // Last-used pair = Auto (from nil) → 中文.
        #expect(store.lastUsedPair.from == nil)
        #expect(store.lastUsedPair.to.code == "zh-CN")
        // No recents yet.
        #expect(store.recentTargets.isEmpty)
    }

    @Test("homeTarget / secondaryLanguage round-trip through a fresh store")
    func homeAndSecondaryRoundTrip() {
        let (store, defaults, _) = makeStore()
        let english = LanguageCatalog.language(forCode: "en")!
        let chinese = LanguageCatalog.language(forCode: "zh-CN")!
        store.homeTarget = english
        store.secondaryLanguage = chinese
        let reloaded = SettingsStore(defaults: defaults)
        #expect(reloaded.homeTarget.code == "en")
        #expect(reloaded.secondaryLanguage.code == "zh-CN")
    }

    @Test("lastUsedPair round-trips an explicit From through a fresh store")
    func lastUsedPairExplicitFromRoundTrip() {
        let (store, defaults, _) = makeStore()
        let english = LanguageCatalog.language(forCode: "en")!
        let chinese = LanguageCatalog.language(forCode: "zh-CN")!
        store.lastUsedPair = LanguagePair(from: english, to: chinese)
        let reloaded = SettingsStore(defaults: defaults)
        #expect(reloaded.lastUsedPair.from?.code == "en")
        #expect(reloaded.lastUsedPair.to.code == "zh-CN")
    }

    @Test("lastUsedPair persists the \"auto\" sentinel for a nil From")
    func lastUsedPairAutoSentinel() {
        let (store, defaults, _) = makeStore()
        let english = LanguageCatalog.language(forCode: "en")!
        // Set an explicit From first, then clear it back to Auto.
        store.lastUsedPair = LanguagePair(from: english, to: english)
        store.lastUsedPair = LanguagePair(from: nil, to: english)
        // The sentinel is on disk, and a fresh store reads it back as Auto.
        #expect(defaults.string(forKey: "lastFromCode") == "auto")
        #expect(SettingsStore(defaults: defaults).lastUsedPair.from == nil)
    }

    @Test("recordRecentTarget keeps most-recent-first order, de-duped")
    func recentTargetsOrderAndDedup() {
        let (store, _, _) = makeStore()
        let codes = ["en", "ar", "en"] // re-recording "en" moves it to front
        for code in codes {
            store.recordRecentTarget(LanguageCatalog.language(forCode: code)!)
        }
        #expect(store.recentTargets.map(\.code) == ["en", "ar"])
    }

    @Test("recordRecentTarget caps the list at five")
    func recentTargetsCapAtFive() {
        let (store, _, _) = makeStore()
        // Record six distinct targets; the oldest ("af") must be evicted.
        let codes = ["af", "sq", "am", "ar", "hy", "as"]
        for code in codes {
            store.recordRecentTarget(LanguageCatalog.language(forCode: code)!)
        }
        let recent = store.recentTargets.map(\.code)
        #expect(recent.count == 5)
        #expect(recent == ["as", "hy", "ar", "am", "sq"])
        #expect(!recent.contains("af"))
    }

    @Test("Unknown / removed codes fall back to defaults, never crash")
    func unknownCodeResilience() {
        let (store, defaults, _) = makeStore()
        // Simulate codes a future catalog no longer knows.
        defaults.set("nonexistent-home", forKey: "homeTargetCode")
        defaults.set("nonexistent-secondary", forKey: "secondaryCode")
        defaults.set("nonexistent-from", forKey: "lastFromCode")
        defaults.set("nonexistent-to", forKey: "lastToCode")
        defaults.set(["en", "nonexistent-recent", "ar"], forKey: "recentTargetCodes")

        #expect(store.homeTarget.code == "zh-CN")          // default
        #expect(store.secondaryLanguage.code == "en")      // default
        #expect(store.lastUsedPair.from == nil)            // unknown From → Auto
        #expect(store.lastUsedPair.to.code == "zh-CN")     // unknown To → default
        #expect(store.recentTargets.map(\.code) == ["en", "ar"]) // unknown dropped
    }
}
