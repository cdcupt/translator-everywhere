import Foundation

/// Owns the global capture-translate shortcut (default ⌃⌥Y).
///
/// TECH §8.1: backed by the KeyboardShortcuts SPM package with an in-app
/// recorder in Preferences (no Accessibility permission). Stub for slice 1.
final class HotkeyManager {
    /// Default capture-translate combo, surfaced for the menu label later.
    static let defaultShortcutDescription = "⌃⌥Y"

    func start() {
        // TODO(slice: hotkey): register the global .captureTranslate shortcut.
    }
}
