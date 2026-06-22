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
}
