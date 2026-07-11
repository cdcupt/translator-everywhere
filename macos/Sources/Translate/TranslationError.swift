import Foundation

/// Errors surfaced by the translation engines, shaped for a user-facing panel.
enum TranslationError: Error, LocalizedError {
    /// Nothing meaningful to translate.
    case emptyInput
    /// The request could not be constructed (programmer error / bad input).
    case invalidRequest
    /// Network failure after retries.
    case network(engine: EngineKind, underlying: Error?)
    /// The selection deadline elapsed before the engine answered (TECH §03·2).
    case timedOut
    /// The provider returned an error envelope (e.g. OpenAI `error.message`).
    case api(message: String)
    /// The response parsed but did not contain a translation.
    case unexpectedResponse(engine: EngineKind)

    var errorDescription: String? {
        switch self {
        case .emptyInput:
            return "Nothing to translate."
        case .invalidRequest:
            return "Couldn’t build the translation request."
        case let .network(engine, _):
            return "Network error reaching the \(engine.badge) translator. Check your connection and try again."
        case .timedOut:
            return "The translation timed out. Check your connection and try again."
        case let .api(message):
            return message
        case let .unexpectedResponse(engine):
            return "The \(engine.badge) translator returned an unexpected response."
        }
    }
}
