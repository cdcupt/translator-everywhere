import Testing
@testable import Translator_Everywhere

@Suite("LaunchAtLogin — enabled/disabled mapping")
struct LaunchAtLoginTests {

    /// In-memory fake login-item service so tests never register a real login
    /// item or depend on the app bundle's registration state.
    private final class FakeLoginItem: LoginItemService {
        var enabled: Bool
        private(set) var registerCount = 0
        private(set) var unregisterCount = 0
        var registerError: Error?
        var unregisterError: Error?

        init(enabled: Bool) { self.enabled = enabled }

        var isEnabled: Bool { enabled }

        func register() throws {
            if let registerError { throw registerError }
            registerCount += 1
            enabled = true
        }

        func unregister() throws {
            if let unregisterError { throw unregisterError }
            unregisterCount += 1
            enabled = false
        }
    }

    struct FakeError: Error {}

    @Test("isEnabled reflects the service state")
    func reflectsState() {
        #expect(LaunchAtLogin(service: FakeLoginItem(enabled: true)).isEnabled)
        #expect(!LaunchAtLogin(service: FakeLoginItem(enabled: false)).isEnabled)
    }

    @Test("enabling from disabled registers once")
    func enableRegisters() throws {
        let fake = FakeLoginItem(enabled: false)
        try LaunchAtLogin(service: fake).setEnabled(true)
        #expect(fake.isEnabled)
        #expect(fake.registerCount == 1)
    }

    @Test("disabling from enabled unregisters once")
    func disableUnregisters() throws {
        let fake = FakeLoginItem(enabled: true)
        try LaunchAtLogin(service: fake).setEnabled(false)
        #expect(!fake.isEnabled)
        #expect(fake.unregisterCount == 1)
    }

    @Test("enabling when already enabled is a no-op")
    func enableIdempotent() throws {
        let fake = FakeLoginItem(enabled: true)
        try LaunchAtLogin(service: fake).setEnabled(true)
        #expect(fake.registerCount == 0)
    }

    @Test("disabling when already disabled is a no-op")
    func disableIdempotent() throws {
        let fake = FakeLoginItem(enabled: false)
        try LaunchAtLogin(service: fake).setEnabled(false)
        #expect(fake.unregisterCount == 0)
    }

    @Test("a register failure propagates and leaves state unchanged")
    func registerFailurePropagates() {
        let fake = FakeLoginItem(enabled: false)
        fake.registerError = FakeError()
        #expect(throws: FakeError.self) {
            try LaunchAtLogin(service: fake).setEnabled(true)
        }
        #expect(!fake.isEnabled)
    }
}
