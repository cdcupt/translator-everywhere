import AppKit
import UniformTypeIdentifiers

/// Presents an `NSSavePanel` for notebook exports and writes the chosen file.
enum SavePanelPresenter {

    @MainActor
    static func present(text: String, format: NotebookStore.ExportFormat) {
        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        switch format {
        case .csv:
            panel.allowedContentTypes = [.commaSeparatedText]
            panel.nameFieldStringValue = "vocabulary.csv"
        case .markdown:
            let md = UTType(filenameExtension: "md") ?? .plainText
            panel.allowedContentTypes = [md]
            panel.nameFieldStringValue = "vocabulary.md"
        }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            let alert = NSAlert()
            alert.messageText = "Export failed"
            alert.informativeText = error.localizedDescription
            alert.runModal()
        }
    }
}
