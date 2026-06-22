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

    init(
        auth: AuthClient = AuthClient(),
        onSignedIn: @escaping @MainActor () async -> Date? = { nil },
        onSignedOut: @escaping @MainActor () -> Void = {}
    ) {
        self.auth = auth
        self.onSignedIn = onSignedIn
        self.onSignedOut = onSignedOut
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
            let session = try await flow()
            phase = .signedIn(session.user)
            lastSyncedAt = await onSignedIn()
        } catch AuthError.cancelled {
            // User backed out — quietly return to signed-out, no error banner.
            phase = .signedOut
        } catch {
            phase = .error(Self.message(for: error))
        }
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
