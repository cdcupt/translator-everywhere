import Foundation
import Testing
@testable import Translator_Everywhere

/// The browser-redirect router that replaced `ASWebAuthenticationSession`:
/// it suspends a sign-in until the OS delivers a redirect whose `state` matches.
/// Driven via `awaitRedirect` (the registration seam) + `handle` so the routing
/// is exercised without opening a real browser.
@MainActor
@Suite("WebAuthRouter — matches a redirect to the awaiting sign-in by state")
struct WebAuthRouterTests {

    @Test("resumes the waiter whose state matches the redirect")
    func resumesMatchingState() async throws {
        let router = WebAuthRouter()
        let waiting = Task { try await router.awaitRedirect(matchingState: "S1") }
        try await Task.sleep(for: .milliseconds(20)) // let the continuation register

        // A mismatched state is ignored (not handled, waiter stays pending).
        #expect(router.handle(URL(string: "scheme://cb?code=C&state=OTHER")!) == false)
        // The matching state resumes the awaiter with the full callback URL.
        #expect(router.handle(URL(string: "scheme://cb?code=C&state=S1")!) == true)

        let callback = try await waiting.value
        #expect(callback.query?.contains("code=C") == true)
    }

    @Test("a redirect with no matching waiter is not handled")
    func ignoresUnknownState() {
        let router = WebAuthRouter()
        #expect(router.handle(URL(string: "scheme://cb?code=C&state=nobody")!) == false)
        // A redirect with no state at all is also ignored, not crashed on.
        #expect(router.handle(URL(string: "scheme://cb?code=C")!) == false)
    }
}
