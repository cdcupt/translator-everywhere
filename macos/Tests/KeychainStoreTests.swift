import Foundation
import Testing
@testable import Translator_Everywhere

@Suite("KeychainStore — set / read / clear")
struct KeychainStoreTests {

    /// A test-scoped service so we never collide with the real app's items.
    private func makeStore() -> (KeychainStore, String) {
        let service = "com.cdcupt.translator-everywhere.tests-\(UUID().uuidString)"
        return (KeychainStore(service: service), "test-account")
    }

    @Test("set then read returns the stored value")
    func setThenRead() throws {
        let (store, account) = makeStore()
        defer { try? store.delete(account) }

        try store.set("sk-secret-123", for: account)
        #expect(store.string(for: account) == "sk-secret-123")
    }

    @Test("set overwrites a previous value")
    func setOverwrites() throws {
        let (store, account) = makeStore()
        defer { try? store.delete(account) }

        try store.set("first", for: account)
        try store.set("second", for: account)
        #expect(store.string(for: account) == "second")
    }

    @Test("setting empty/whitespace clears the item")
    func emptyClears() throws {
        let (store, account) = makeStore()
        defer { try? store.delete(account) }

        try store.set("present", for: account)
        try store.set("   ", for: account)
        #expect(store.string(for: account) == nil)
    }

    @Test("delete removes the value; reading a missing key returns nil")
    func deleteClears() throws {
        let (store, account) = makeStore()

        try store.set("to-be-removed", for: account)
        try store.delete(account)
        #expect(store.string(for: account) == nil)
    }

    @Test("delete on a missing key succeeds")
    func deleteMissingSucceeds() throws {
        let (store, account) = makeStore()
        // No throw even though nothing was stored.
        try store.delete(account)
        #expect(store.string(for: account) == nil)
    }
}
