import SwiftUI
import AppKit

/// The study-list sheet shown over the notebook after Summarize (DESIGN §2c).
///
/// Renders the engine's output (a grouped study list from AI, or a clean list
/// from the free engine) with Copy and Export. Text only — no editing.
struct SummarySheet: View {

    let text: String
    let store: NotebookStore
    let items: [VocabItem]

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Study list")
                    .font(.system(.title3, design: .serif))
                Spacer()
                Button("Copy") { copy() }
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }

            ScrollView {
                Text(text)
                    .font(.body)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
            }
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
        }
        .padding(18)
        .frame(width: 560, height: 460)
    }

    private func copy() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }
}
