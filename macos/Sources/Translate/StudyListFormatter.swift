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

    /// A self-contained prompt the user can paste into *their own* AI assistant
    /// (ChatGPT, Claude, any agent) to get a study summary on their own account.
    /// It pairs the same coaching instruction the in-app AI engine uses with the
    /// numbered captures, as one ready-to-paste block — the hand-off counterpart
    /// to `summarize`, so the output matches regardless of which AI runs it.
    static func studyPrompt(_ items: [VocabItem]) -> String {
        """
        You are a language study coach. Below is a list of vocabulary I saved \
        while reading, each formatted as "source => translation". Produce a \
        concise, well-structured Markdown study list: group the items by theme \
        with a short heading per group, and for each item add one natural example \
        sentence using it. Keep it tight and practical.

        \(promptLines(items))
        """
    }

    static let emptyMessage = "No captures to summarize yet."
}
