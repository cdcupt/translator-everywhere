import SwiftUI

/// The Preferences → Account tab (DESIGN §2e).
///
/// Signed-out: the reassuring "your notebook already works on this Mac — sign in
/// only to sync across Macs" panel, Apple-first then Google sign-in buttons.
/// Signed-in: email/provider, a "Last synced …" line, Sign out, and the
/// destructive "Delete account & cloud data" (with a confirm).
struct AccountTab: View {

    @State private var model: AccountViewModel
    /// Surfaces the "Restored your OpenAI key" confirmation on the signed-in view
    /// (R5 — the restore fires on this surface, at sign-in).
    let keySync: KeySyncService

    init(model: AccountViewModel, keySync: KeySyncService) {
        _model = State(initialValue: model)
        self.keySync = keySync
    }

    var body: some View {
        VStack(spacing: 16) {
            switch model.phase {
            case .signedIn(let user):
                signedIn(user)
            default:
                signedOut
            }
        }
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity)
        .confirmationDialog(
            "Delete account & cloud data?",
            isPresented: $model.isConfirmingDelete,
            titleVisibility: .visible
        ) {
            Button("Delete everything in the cloud", role: .destructive) {
                Task { await model.deleteAccount() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This permanently deletes your cloud account and all synced rows. "
                 + "Your notebook on this Mac is kept.")
        }
    }

    // MARK: - Signed out

    @ViewBuilder
    private var signedOut: some View {
        // The green reassurance panel — local-first, sync is optional.
        VStack(spacing: 8) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 34))
                .foregroundStyle(.green)
            Text("Your notebook already works on this Mac")
                .font(.headline)
            Text("Sign in only to sync your vocabulary across your Macs.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Text(KeySyncCopy.accountPrivacy)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(14)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.green.opacity(0.10))
        )

        if case let .error(message) = model.phase {
            Text(message)
                .font(.caption)
                .foregroundStyle(.red)
                .multilineTextAlignment(.center)
        }

        // Apple first (Apple's HIG ordering), then Google.
        VStack(spacing: 8) {
            Button {
                Task { await model.signInWithApple() }
            } label: {
                Label("Sign in with Apple", systemImage: "applelogo")
                    .frame(maxWidth: .infinity)
            }
            .controlSize(.large)

            Button {
                Task { await model.signInWithGoogle() }
            } label: {
                Label("Sign in with Google", systemImage: "globe")
                    .frame(maxWidth: .infinity)
            }
            .controlSize(.large)
        }
        .disabled(model.phase == .signingIn)

        if model.phase == .signingIn {
            ProgressView().controlSize(.small)
        }
    }

    // MARK: - Signed in

    @ViewBuilder
    private func signedIn(_ user: AuthUser) -> some View {
        VStack(spacing: 6) {
            Image(systemName: "person.crop.circle.fill.badge.checkmark")
                .font(.system(size: 34))
                .foregroundStyle(.green)
            Text(user.email ?? "Signed in")
                .font(.headline)
            Text("via \(user.provider.rawValue.capitalized)")
                .font(.callout)
                .foregroundStyle(.secondary)
            Text(syncStatusText)
                .font(.caption)
                .foregroundStyle(.secondary)
            if keySync.showRestoredToast {
                Label(KeySyncCopy.restoredToast, systemImage: "checkmark.icloud.fill")
                    .font(.caption)
                    .foregroundStyle(.green)
            }
        }

        if case let .error(message) = model.phase {
            Text(message)
                .font(.caption)
                .foregroundStyle(.red)
                .multilineTextAlignment(.center)
        }

        VStack(spacing: 8) {
            Button("Sign out") {
                Task { await model.signOut() }
            }
            .controlSize(.large)
            .frame(maxWidth: .infinity)

            Button("Delete account & cloud data", role: .destructive) {
                model.isConfirmingDelete = true
            }
            .controlSize(.large)
            .frame(maxWidth: .infinity)
        }
    }

    private var syncStatusText: String {
        guard let date = model.lastSyncedAt else { return "Syncing…" }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return "Last synced \(formatter.localizedString(for: date, relativeTo: Date()))"
    }
}
