import Foundation
import KeyboardShortcuts

extension KeyboardShortcuts.Name {
    /// The global capture-translate shortcut. Default ⌃⌥Y; an in-app Recorder in
    /// Preferences lets the user rebind it (no Accessibility permission needed —
    /// KeyboardShortcuts uses a Carbon hot-key under the hood). TECH §8.1.
    static let captureTranslate = Self(
        "captureTranslate",
        default: .init(.y, modifiers: [.control, .option])
    )
}

/// Owns the global capture-translate shortcut (default ⌃⌥Y).
///
/// On key-down it invokes the supplied handler, which `AppDelegate` wires to the
/// `CaptureCoordinator`. The Recorder UI ships in the Preferences slice; here we
/// only register and fire.
final class HotkeyManager {

    /// Default capture-translate combo, surfaced for the menu label.
    static let defaultShortcutDescription = "⌃⌥Y"

    private let onCapture: () -> Void

    init(onCapture: @escaping () -> Void) {
        self.onCapture = onCapture
    }

    /// Registers the global key-down handler. Idempotent — re-registering
    /// replaces the previous handler for this name.
    func start() {
        KeyboardShortcuts.onKeyDown(for: .captureTranslate) { [onCapture] in
            onCapture()
        }
    }
}
