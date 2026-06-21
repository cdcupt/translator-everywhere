import Foundation

/// Thin wrapper over the Keychain (TECH §8.1).
///
/// Holds the OpenAI key + session/refresh JWTs. Nothing secret on disk or in
/// logs. Stub for slice 1.
struct KeychainStore {
    // TODO(slice: auth/keychain): Security framework get/set/delete helpers.
}
