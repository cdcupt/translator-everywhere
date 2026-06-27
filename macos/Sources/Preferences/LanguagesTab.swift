import SwiftUI

/// The Preferences "Languages" tab (slice 8): choose the **home target** (the
/// preferred default To) and the **secondary** language (the one-tap alternate
/// the same-language guard flips to), and review the last-used pair.
///
/// Both menus list the full catalog and bind straight through to
/// `SettingsStore.homeTarget` / `secondaryLanguage`; the "Last used" line is a
/// read-only echo of `SettingsStore.lastUsedPair`. A menu `Picker` is used
/// (rather than embedding the slice-7 AppKit search popover) to stay consistent
/// with the other SwiftUI tabs (`EngineTab`, `GeneralTab`).
struct LanguagesTab: View {

    let settings: SettingsStore

    @State private var homeCode: String
    @State private var secondaryCode: String

    /// The whole catalog, in catalog (A–Z) order, for both menus.
    private static let options = LanguageCatalog.all

    init(settings: SettingsStore) {
        self.settings = settings
        _homeCode = State(initialValue: settings.homeTarget.code)
        _secondaryCode = State(initialValue: settings.secondaryLanguage.code)
    }

    var body: some View {
        Form {
            Section {
                languageMenu("Home target", selection: $homeCode)
                    .onChange(of: homeCode) { _, code in
                        if let language = LanguageCatalog.language(forCode: code) {
                            settings.homeTarget = language
                        }
                    }
                Text("Your preferred target. Captures translate here unless you "
                     + "pick another language on the result bar.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                languageMenu("Secondary", selection: $secondaryCode)
                    .onChange(of: secondaryCode) { _, code in
                        if let language = LanguageCatalog.language(forCode: code) {
                            settings.secondaryLanguage = language
                        }
                    }
                Text("The one-tap alternate. When you capture text that's already "
                     + "in your home language, the translation flips to your "
                     + "secondary instead — so a two-language workflow stays two-way.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if homeCode == secondaryCode {
                    Label("Home and secondary match — the auto-flip stays off "
                          + "until they differ.", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }

            Section {
                LabeledContent("Last used",
                               value: LanguagesTabModel.lastUsedSummary(settings.lastUsedPair))
            }
        }
        .formStyle(.grouped)
    }

    /// A menu `Picker` over the full catalog, tagged by canonical code.
    private func languageMenu(_ title: String, selection: Binding<String>) -> some View {
        Picker(title, selection: selection) {
            ForEach(Self.options) { language in
                Text("\(language.endonym) — \(language.englishName)").tag(language.code)
            }
        }
        .pickerStyle(.menu)
    }
}

/// Pure formatting for the tab's read-only "Last used" line — extracted so the
/// Auto-vs-explicit From rendering is unit-testable without SwiftUI.
enum LanguagesTabModel {

    /// "From → To" using endonyms; `from == nil` (Auto-detect) renders as "Auto".
    static func lastUsedSummary(_ pair: LanguagePair) -> String {
        let from = pair.from?.endonym ?? "Auto"
        return "\(from) → \(pair.to.endonym)"
    }
}
