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

    @State private var preference: EnginePreference
    @State private var apiKey: String
    @State private var testState: EngineTestState = .idle

    /// Sample text for the live Test call.
    private static let testSample = "Hello"

    init(settings: SettingsStore, keychain: KeychainStore) {
        self.settings = settings
        self.keychain = keychain
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
                Section {
                    SecureField("OpenAI API key (sk-…)", text: $apiKey)
                        .onChange(of: apiKey) { _, _ in
                            persistKey()
                            testState = .idle
                        }
                    Label("Stored only in your macOS Keychain — never written to "
                          + "disk or sent anywhere but OpenAI.",
                          systemImage: "lock.fill")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    HStack {
                        Button("Test") { runTest() }
                            .disabled(trimmedKey.isEmpty || testState == .testing)
                        testStatusView
                    }
                }
            }
        }
        .formStyle(.grouped)
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
                _ = try await engine.translate(Self.testSample)
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
