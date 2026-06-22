import Foundation

/// Runs `/usr/sbin/screencapture -i -x <tmp.png>` (TECH §8.1).
///
/// The user drags an interactive selection; macOS writes the PNG only on a
/// completed selection. Pressing Esc (cancel) leaves *no file on disk*, and
/// `screencapture` still exits `0` either way — so cancellation is detected by
/// **file absence**, never by exit code.
struct RegionCapturer {

    /// Path to the system interactive screen-capture tool.
    static let screencapturePath = "/usr/sbin/screencapture"

    /// Runs the capture process for a destination URL and returns when it exits.
    /// Injected so cancel-detection logic can be unit-tested without spawning a
    /// real interactive capture (which cannot run headlessly).
    private let runCapture: (URL) async throws -> Void

    /// Default initializer drives the real `screencapture` binary off-main.
    init() {
        self.runCapture = { destination in
            try await Self.runScreencapture(to: destination)
        }
    }

    /// Test seam: inject a runner that simulates capture (writes a file) or
    /// cancel (writes nothing).
    init(runCapture: @escaping (URL) async throws -> Void) {
        self.runCapture = runCapture
    }

    /// Presents the interactive region selector and returns the captured image.
    ///
    /// - Returns: the PNG `URL` on a completed capture, or `nil` if the user
    ///   cancelled (no file was written).
    func captureRegion() async throws -> URL? {
        let destination = Self.makeTempImageURL()
        // Defensive: never let a stale file masquerade as a fresh capture.
        try? FileManager.default.removeItem(at: destination)

        try await runCapture(destination)

        // Cancel = no file written. This is the only reliable signal.
        guard FileManager.default.fileExists(atPath: destination.path) else {
            return nil
        }
        return destination
    }

    /// A unique temp PNG path for one capture.
    static func makeTempImageURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("te-capture-\(UUID().uuidString).png")
    }

    /// Spawns `/usr/sbin/screencapture -i -x <dest>` off the main thread and
    /// resumes when the process terminates.
    private static func runScreencapture(to destination: URL) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: screencapturePath)
            // -i interactive selection, -x no capture sound.
            process.arguments = ["-i", "-x", destination.path]
            process.terminationHandler = { _ in
                continuation.resume()
            }
            do {
                try process.run()
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }
}
