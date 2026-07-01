import SwiftUI

/// The live state of an OpenAI key Test (DESIGN §2d, Fig 7).
enum EngineTestState: Equatable {
    case idle
    case testing
    case ok
    case failed(String)
}

/// Engine selection + OpenAI key field + Test (DESIGN §2d, Fig 7).
///
/// A segmented control defaults to Free (Vision + Google). Selecting OpenAI
/// reveals the key field, a Keychain note, and a Test button that runs one real
/// sample translation. Free stays selectable even with a key present (PRD §5).
struct EngineTab: View {

    let settings: SettingsStore
    let keychain: KeychainStore
    /// Drives the "Sync this key across my Macs" toggle + auto-restore (TECH §3).
    let keySync: KeySyncService

    @State private var preference: EnginePreference
    @State private var apiKey: String
    @State private var testState: EngineTestState = .idle

    /// Sample text for the live Test call.
    private static let testSample = "Hello"

    /// Target for the live Test call — any valid pair proves the key works; 中文
    /// is the seeded home target. Catalog fallback is purely defensive.
    private static let testTarget: Language =
        LanguageCatalog.language(forCode: "zh-CN")
        ?? Language(code: "zh-CN", englishName: "Chinese (Simplified)", endonym: "简体中文",
                    googleCode: "zh-CN", aiName: "Simplified Chinese", aliases: [])

    init(settings: SettingsStore, keychain: KeychainStore, keySync: KeySyncService) {
        self.settings = settings
        self.keychain = keychain
        self.keySync = keySync
        _preference = State(initialValue: settings.enginePreference)
        _apiKey = State(
            initialValue: keychain.string(for: KeychainStore.openAIKeyAccount) ?? ""
        )
    }

    var body: some View {
        Form {
            Section {
                Picker("Engine", selection: $preference) {
                    Text("Free (Vision + Google)").tag(EnginePreference.free)
                    Text("OpenAI").tag(EnginePreference.openai)
                }
                .pickerStyle(.segmented)
                .onChange(of: preference) { _, newValue in
                    settings.enginePreference = newValue
                }
            }

            if preference == .openai {
                Section("OpenAI API key") {
                    SecureField("Paste your key (sk-…)", text: $apiKey)
                        .textFieldStyle(.roundedBorder)
                        .onChange(of: apiKey) { _, newValue in
                            persistKey()
                            testState = .idle
                            // Re-upload on edit when sync is ON; a no-op otherwise.
                            Task { await keySync.uploadIfEnabled(key: newValue) }
                        }

                    // Empty-state hint: the field is BYOK, and OpenAI isn't active
                    // until a key is present (the engine falls back to Free).
                    if trimmedKey.isEmpty {
                        Label("Paste your own OpenAI API key above to turn on the "
                              + "OpenAI engine. Until then, translation uses "
                              + "Free (Vision + Google).",
                              systemImage: "info.circle")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    syncControls

                    HStack {
                        Button("Test") { runTest() }
                            .disabled(trimmedKey.isEmpty || testState == .testing)
                        testStatusView
                    }
                }
            }
        }
        .formStyle(.grouped)
        // Don't-clobber prompt: a restore found a *different* local key.
        .alert(
            "Use this Mac's key or the synced one?",
            isPresented: Binding(
                get: { keySync.pendingConflict != nil },
                set: { presenting in if !presenting { keySync.resolveConflictKeepingLocal() } }
            )
        ) {
            // First button is the default (⏎) — keep local, per DESIGN §3.
            Button("Keep this Mac's key") { keySync.resolveConflictKeepingLocal() }
            Button("Use synced key") {
                keySync.resolveConflictAdoptingSynced()
                apiKey = keychain.string(for: KeychainStore.openAIKeyAccount) ?? apiKey
            }
        } message: {
            Text("This Mac already has an OpenAI key saved. Keep it, or replace it "
                 + "with the key synced from your account?")
        }
    }

    /// The sync toggle, its disabled-reason, the context-sensitive privacy copy,
    /// the status line, and the restored-key confirmation (TECH §3.3, R5).
    @ViewBuilder
    private var syncControls: some View {
        Toggle("Sync this key across my Macs", isOn: Binding(
            get: { keySync.isEnabled },
            set: { turnOn in
                Task {
                    if turnOn { await keySync.enable(key: trimmedKey) }
                    else { await keySync.disable() }
                }
            }
        ))
        .disabled(syncDisabledReason != nil)

        if let reason = syncDisabledReason {
            Label(reason, systemImage: "info.circle")
                .font(.caption)
                .foregroundStyle(.secondary)
        }

        // Truth-in-UI: the copy flips with the sync state (DESIGN §5).
        Label(keySync.isEnabled ? KeySyncCopy.engineSyncOn : KeySyncCopy.engineSyncOff,
              systemImage: "lock.fill")
            .font(.caption)
            .foregroundStyle(.secondary)

        if keySync.isEnabled { syncStatusView }

        if keySync.showRestoredToast {
            Label(KeySyncCopy.restoredToast, systemImage: "checkmark.icloud.fill")
                .font(.caption)
                .foregroundStyle(.green)
        }
    }

    /// The reason the toggle is disabled (signed out / no key), or `nil`.
    private var syncDisabledReason: String? {
        keySync.syncDisabledReason(hasKey: !trimmedKey.isEmpty)
    }

    @ViewBuilder
    private var syncStatusView: some View {
        switch keySync.state {
        case .syncing:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Syncing…").font(.caption).foregroundStyle(.secondary)
            }
        case .synced, .off:
            Label("Synced", systemImage: "checkmark.icloud.fill")
                .font(.caption)
                .foregroundStyle(.green)
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.icloud")
                .font(.caption)
                .foregroundStyle(.orange)
        }
    }

    private var trimmedKey: String {
        apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    @ViewBuilder
    private var testStatusView: some View {
        switch testState {
        case .idle:
            EmptyView()
        case .testing:
            ProgressView().controlSize(.small)
        case .ok:
            Label("Key works", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .font(.caption)
        case .failed(let message):
            Label(message, systemImage: "xmark.circle.fill")
                .foregroundStyle(.red)
                .font(.caption)
        }
    }

    /// Writes the current key to the Keychain (empty input clears it).
    private func persistKey() {
        try? keychain.set(apiKey, for: KeychainStore.openAIKeyAccount)
    }

    /// Runs one sample translation via `OpenAIEngine` and reports OK / error.
    private func runTest() {
        persistKey()
        let key = trimmedKey
        guard !key.isEmpty else { return }
        testState = .testing
        Task {
            let engine = OpenAIEngine(apiKey: key)
            do {
                let request = TranslationRequest(text: Self.testSample, from: nil, to: Self.testTarget)
                _ = try await engine.translate(request)
                await MainActor.run { testState = .ok }
            } catch {
                await MainActor.run {
                    testState = .failed(Self.message(for: error))
                }
            }
        }
    }

    /// Human-readable reason for a failed Test.
    private static func message(for error: Error) -> String {
        if let translationError = error as? TranslationError {
            switch translationError {
            case .api(let message):
                return message
            case .network:
                return "Couldn't reach OpenAI. Check your connection."
            default:
                return translationError.localizedDescription
            }
        }
        return error.localizedDescription
    }
}
