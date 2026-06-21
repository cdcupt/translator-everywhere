import Foundation

/// The capture state machine (TECH §8.2).
///
/// Sequences `RegionCapturer` → `OCRService` → `Translator`, then auto-saves to
/// `NotebookStore`. An `actor` so the whole capture path runs off the main
/// actor; only UI mutation touches main. Stub for slice 1.
actor CaptureCoordinator {
    func captureAndTranslate() async {
        // TODO(slice: capture): RegionCapturer → OCRService → Translator → save.
    }
}
