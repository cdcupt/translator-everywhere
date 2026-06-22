import AppKit
import Foundation

/// The capture state machine (TECH §8.2).
///
/// Sequences `PermissionService` → `RegionCapturer` → `OCRService` and shows the
/// result in `ResultPanel`. An `actor` so the capture/OCR path runs off the main
/// actor; only UI mutation hops to `@MainActor`. Translation + auto-save land in
/// slice 3 at the marked hand-off point.
actor CaptureCoordinator {

    private let permission: PermissionService
    private let capturer: RegionCapturer
    private let ocr: OCRService
    private let resultPanel: ResultPanel

    init(
        permission: PermissionService = PermissionService(),
        capturer: RegionCapturer = RegionCapturer(),
        ocr: OCRService = OCRService(),
        resultPanel: ResultPanel
    ) {
        self.permission = permission
        self.capturer = capturer
        self.ocr = ocr
        self.resultPanel = resultPanel
    }

    /// Runs one capture→OCR→show cycle. Safe to call repeatedly; the `actor`
    /// serializes overlapping hotkey presses.
    func captureAndTranslate() async {
        // 1. Permission gate — never invoke screencapture without access (§8.6b).
        guard permission.isGranted else {
            permission.requestAccess()
            await presentPermissionNeeded()
            return
        }

        // 2. Interactive region capture (off-main). nil = user cancelled (Esc).
        let imageURL: URL?
        do {
            imageURL = try await capturer.captureRegion()
        } catch {
            await present(title: "Capture failed", body: error.localizedDescription)
            return
        }
        guard let imageURL else {
            // Cancel: silently return to idle (DESIGN §1).
            return
        }
        // The PNG is transient — discard it whatever happens next.
        defer { try? FileManager.default.removeItem(at: imageURL) }

        // 3. On-device OCR.
        let recognized: String
        do {
            recognized = try await ocr.recognizeText(in: imageURL)
        } catch {
            await present(title: "Couldn’t read text", body: error.localizedDescription)
            return
        }

        let trimmed = recognized.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            await present(title: "No text found",
                          body: "Nothing recognizable was in the selection. Try again.")
            return
        }

        // SLICE 3 HAND-OFF: `trimmed` is the source text. Next slice routes it
        // through `Translator` (active engine) and auto-saves to `NotebookStore`
        // *after* the panel is up. For now the panel shows the recognized text.
        await present(title: "Recognized text", body: trimmed)
    }

    // MARK: - UI hops (main actor)

    @MainActor
    private func present(title: String, body: String) {
        // LSUIElement agents launch unfocused — grab focus before showing.
        NSApp.activate(ignoringOtherApps: true)
        resultPanel.show(title: title, body: body)
    }

    @MainActor
    private func presentPermissionNeeded() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Screen Recording permission needed"
        alert.informativeText = """
        Translator Everywhere needs Screen Recording access to capture a region. \
        Enable it in System Settings, then relaunch the app.
        """
        alert.addButton(withTitle: "Open Settings")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn {
            permission.openSettings()
        }
    }
}
