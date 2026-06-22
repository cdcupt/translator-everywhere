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
    private let resolver: EngineResolver

    init(
        permission: PermissionService = PermissionService(),
        capturer: RegionCapturer = RegionCapturer(),
        ocr: OCRService = OCRService(),
        resolver: EngineResolver = EngineResolver(),
        resultPanel: ResultPanel
    ) {
        self.permission = permission
        self.capturer = capturer
        self.ocr = ocr
        self.resolver = resolver
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

        // 4. Translate via the resolved engine (OpenAI only when preferred AND a
        //    key exists, else free Google). Direct to the provider, never our
        //    server.
        let engine = resolver.resolve()
        let translation: String
        do {
            translation = try await engine.translate(trimmed)
        } catch {
            await presentError(title: "Translation failed", message: error.localizedDescription)
            return
        }

        // 5. Copy the translation to the clipboard, then show the result panel
        //    with the "Copied ✓" affordance.
        let copied = await copyToPasteboard(translation)

        // SLICE 4 HAND-OFF: `trimmed` (source) + `translation` + `engine.kind`
        // are the vocabulary entry. The notebook slice auto-saves them to
        // `NotebookStore` here — *after* the panel is up — and later enriches
        // with `summarize`. Slice 3 stops at the on-screen result + clipboard.
        await presentResult(translation: translation,
                            source: trimmed,
                            badge: engine.kind.badge,
                            copied: copied)
    }

    // MARK: - UI hops (main actor)

    /// Writes `text` to the general pasteboard. Returns whether the write
    /// succeeded so the panel only claims "Copied ✓" when it really did.
    @MainActor
    private func copyToPasteboard(_ text: String) -> Bool {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        return pasteboard.setString(text, forType: .string)
    }

    @MainActor
    private func presentResult(translation: String, source: String, badge: String, copied: Bool) {
        // LSUIElement agents launch unfocused — grab focus before showing.
        NSApp.activate(ignoringOtherApps: true)
        resultPanel.showResult(translation: translation, source: source, badge: badge, copied: copied)
    }

    @MainActor
    private func presentError(title: String, message: String) {
        NSApp.activate(ignoringOtherApps: true)
        resultPanel.showError(title: title, message: message)
    }

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
