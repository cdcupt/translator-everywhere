import Foundation

/// Runs `/usr/sbin/screencapture -i -x <tmp.png>` (TECH §8.1).
///
/// Cancel is detected by file absence, not exit code. Stub for slice 1.
struct RegionCapturer {
    func captureRegion() async throws -> URL? {
        // TODO(slice: capture): run screencapture; return nil on cancel.
        return nil
    }
}
