import Foundation

/// Engine abstraction (TECH §8.4).
///
/// Two interchangeable engines back this protocol: `GoogleEngine` (free,
/// default) and `OpenAIEngine` (user key). Translation goes DIRECT to the
/// engine — never through our server. Stub for slice 1.
protocol Translator {
    func translate(_ text: String, to targetLanguage: String) async throws -> String
}

/// Free Google endpoint, no key — the default engine. Stub for slice 1.
struct GoogleEngine: Translator {
    func translate(_ text: String, to targetLanguage: String) async throws -> String {
        // TODO(slice: translate): call the free Google endpoint directly.
        return ""
    }
}

/// OpenAI API using the user's own key (opt-in). Stub for slice 1.
struct OpenAIEngine: Translator {
    func translate(_ text: String, to targetLanguage: String) async throws -> String {
        // TODO(slice: translate): call OpenAI with the user's Keychain key.
        return ""
    }
}
