import Foundation
import Testing
@testable import Translator_Everywhere

/// The Languages-tab "Last used" formatter (slice 8): renders the read-only
/// `From → To` line, mapping a nil From (Auto-detect) to "Auto".
@Suite("LanguagesTabModel — last-used summary")
struct LanguagesTabModelTests {

    private let zh = LanguageCatalog.language(forCode: "zh-CN")!
    private let en = LanguageCatalog.language(forCode: "en")!

    @Test("A nil From renders as Auto → endonym")
    func autoFrom() {
        let summary = LanguagesTabModel.lastUsedSummary(LanguagePair(from: nil, to: zh))
        #expect(summary == "Auto → \(zh.endonym)")
    }

    @Test("An explicit From renders both endonyms")
    func explicitFrom() {
        let summary = LanguagesTabModel.lastUsedSummary(LanguagePair(from: en, to: zh))
        #expect(summary == "\(en.endonym) → \(zh.endonym)")
    }
}
