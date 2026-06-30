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

        // Deterministically wait for the awaiter to register by retrying `handle`
        // across scheduler turns (no wall-clock sleep): a mismatched state is
        // ignored, and the matching state resumes the awaiter once it's pending.
        let match = try #require(URL(string: "scheme://cb?code=C&state=S1"))
        let other = try #require(URL(string: "scheme://cb?code=C&state=OTHER"))
        #expect(router.handle(other) == false) // mismatch is never handled
        var handled = false
        for _ in 0..<1000 where !handled {
            await Task.yield()
            handled = router.handle(match)
        }
        #expect(handled)

        let callback = try await waiting.value
        #expect(callback.query?.contains("code=C") == true)
    }

    @Test("a redirect with no matching waiter is not handled")
    func ignoresUnknownState() throws {
        let router = WebAuthRouter()
        let unknown = try #require(URL(string: "scheme://cb?code=C&state=nobody"))
        #expect(router.handle(unknown) == false)
        // A redirect with no state at all is ignored, not crashed on.
        let noState = try #require(URL(string: "scheme://cb?code=C"))
        #expect(router.handle(noState) == false)
    }
}
