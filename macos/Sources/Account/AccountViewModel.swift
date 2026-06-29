import Foundation
import Observation

/// Drives the Account tab's signed-out ↔ signed-in state machine (DESIGN §2e).
///
/// Wraps `AuthClient` (sign-in / sign-out / delete) and kicks a full sync on
/// sign-in via the injected `onSignedIn` hook. `@MainActor` + `@Observable` so
/// the SwiftUI tab re-renders on every transition. The local notebook is never
/// touched by any of these actions.
@MainActor
@Observable
final class AccountViewModel {

    /// Coarse UI state.
    enum Phase: Equatable {
        case signedOut
        case signingIn
        case signedIn(AuthUser)
        case error(String)
    }

    private(set) var phase: Phase
    /// "Last synced …" line; `nil` until a sync completes this session.
    private(set) var lastSyncedAt: Date?
    /// `true` while a destructive action confirmation is pending.
    var isConfirmingDelete = false

    private let auth: AuthClient
    /// Called after a successful sign-in (full push+pull). Returns the new
    /// cursor so the tab can show "Last synced …".
    private let onSignedIn: @MainActor () async -> Date?
    /// Called after sign-out / delete so the app can stop any sync.
    private let onSignedOut: @MainActor () -> Void
    /// Upper bound on a web sign-in before we give up and surface an error, so a
    /// flow that never calls back can't strand the UI in `.signingIn`. Generous
    /// by default to allow a real OAuth + 2FA round-trip; injectable for tests.
    private let signInTimeout: Duration

    init(
        auth: AuthClient = AuthClient(),
        onSignedIn: @escaping @MainActor () async -> Date? = { nil },
        onSignedOut: @escaping @MainActor () -> Void = {},
        signInTimeout: Duration = .seconds(180)
    ) {
        self.auth = auth
        self.onSignedIn = onSignedIn
        self.onSignedOut = onSignedOut
        self.signInTimeout = signInTimeout
        if let session = auth.currentSession {
            self.phase = .signedIn(session.user)
        } else {
            self.phase = .signedOut
        }
    }

    /// Convenience for the view.
    var isSignedIn: Bool {
        if case .signedIn = phase { return true }
        return false
    }

    var currentUser: AuthUser? {
        if case let .signedIn(user) = phase { return user }
        return nil
    }

    // MARK: - Actions

    func signInWithGoogle() async {
        await signIn { try await self.auth.signInWithGoogle() }
    }

    func signInWithApple() async {
        await signIn { try await self.auth.signInWithApple() }
    }

    private func signIn(_ flow: @escaping () async throws -> AuthSession) async {
        phase = .signingIn
        do {
            // Race the web-auth flow against a watchdog. If the flow never
            // returns — e.g. the user abandons the auth browser, or the redirect
            // back to our scheme is never delivered — this surfaces `.error`
            // instead of leaving the buttons disabled and the spinner turning
            // forever (the exact "stuck on Loading" symptom). On timeout the flow
            // task is abandoned, not awaited: `ASWebAuthenticationSession`'s
            // continuation isn't cancellation-aware, so a structured wait would
            // deadlock on the very hang we're guarding against.
            let session = try await Self.firstToComplete(within: signInTimeout) {
                try await flow()
            }
            phase = .signedIn(session.user)
            lastSyncedAt = await onSignedIn()
        } catch AuthError.cancelled {
            // User backed out — quietly return to signed-out, no error banner.
            phase = .signedOut
        } catch {
            phase = .error(Self.message(for: error))
        }
    }

    /// Returns `operation`'s result, or throws `AuthError.transport` if it has not
    /// completed within `timeout`. The operation runs in an unstructured task that
    /// is abandoned (not awaited) on timeout — required because the underlying
    /// web-auth continuation can't be cancelled, so a structured `TaskGroup` wait
    /// would hang on a stuck sign-in. The abandoned task is a bounded one-off
    /// leak; making the providers cancellation-aware is a tracked follow-up.
    static func firstToComplete<T>(
        within timeout: Duration,
        _ operation: @escaping () async throws -> T
    ) async throws -> T {
        let gate = ResumeGate<T>()
        Task {
            do { await gate.settle(.success(try await operation())) }
            catch { await gate.settle(.failure(error)) }
        }
        let timer = Task {
            try? await Task.sleep(for: timeout)
            await gate.settle(.failure(AuthError.transport))
        }
        defer { timer.cancel() }
        return try await gate.awaitResult()
    }

    func signOut() async {
        await auth.signOut()
        onSignedOut()
        lastSyncedAt = nil
        phase = .signedOut
    }

    func deleteAccount() async {
        do {
            try await auth.deleteAccount()
            onSignedOut()
            lastSyncedAt = nil
            isConfirmingDelete = false
            phase = .signedOut
        } catch {
            isConfirmingDelete = false
            phase = .error(Self.message(for: error))
        }
    }

    /// Records a fresh sync completion (e.g. a background pull). UI-only.
    func noteSynced(at date: Date) {
        lastSyncedAt = date
    }

    /// Maps an `AuthError` to user-facing DESIGN §4 copy.
    static func message(for error: Error) -> String {
        switch error {
        case AuthError.server(let status):
            return "Sign-in failed (server returned \(status)). Please try again."
        case AuthError.transport:
            return "Couldn't reach the sync server. Check your connection and retry."
        case AuthError.decoding, AuthError.providerResponseInvalid:
            return "Sign-in failed unexpectedly. Please try again."
        case AuthError.notSignedIn:
            return "You're not signed in."
        default:
            return "Something went wrong. Please try again."
        }
    }
}

/// A one-shot result gate used by `AccountViewModel.firstToComplete` to resolve
/// from whichever of two racing tasks (the sign-in flow, the timeout) finishes
/// first. The first `settle` wins; any later one is ignored, so the underlying
/// `CheckedContinuation` is never resumed twice. Actor-isolated so the two tasks
/// settle it without a data race.
private actor ResumeGate<T> {
    private var continuation: CheckedContinuation<T, Error>?
    private var settled: Result<T, Error>?

    func awaitResult() async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            if let settled {
                continuation.resume(with: settled)
            } else {
                self.continuation = continuation
            }
        }
    }

    func settle(_ result: Result<T, Error>) {
        guard settled == nil else { return }
        settled = result
        continuation?.resume(with: result)
        continuation = nil
    }
}
