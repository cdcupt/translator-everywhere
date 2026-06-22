import Foundation

/// Builds the inputs and fallback output for `TranslationEngine.summarize`.
///
/// The free engine has no AI, so it returns `plainList` directly. The AI engine
/// feeds `promptLines` to the chat model and shows the model's study list. Both
/// paths share this one place so the item formatting stays consistent.
enum StudyListFormatter {

    /// The free-engine output: a calm, grouped-by-nothing list of the captures.
    /// Deterministic and offline — what "free is simpler" means in practice.
    static func plainList(_ items: [VocabItem]) -> String {
        guard !items.isEmpty else { return emptyMessage }
        var lines = ["# Vocabulary list", ""]
        for item in items {
            let source = item.sourceText.trimmingCharacters(in: .whitespacesAndNewlines)
            let translation = item.translation.trimmingCharacters(in: .whitespacesAndNewlines)
            lines.append("- \(source) — \(translation)")
        }
        return lines.joined(separator: "\n")
    }

    /// The user-facing prompt block fed to the AI engine: one capture per line,
    /// numbered so the model can reference them.
    static func promptLines(_ items: [VocabItem]) -> String {
        items.enumerated().map { index, item in
            let source = item.sourceText.trimmingCharacters(in: .whitespacesAndNewlines)
            let translation = item.translation.trimmingCharacters(in: .whitespacesAndNewlines)
            return "\(index + 1). \(source) => \(translation)"
        }
        .joined(separator: "\n")
    }

    static let emptyMessage = "No captures to summarize yet."
}
