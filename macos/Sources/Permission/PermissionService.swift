import Foundation

/// Screen-recording permission gate (TECH §8.1, §8.6b).
///
/// Wraps `CGPreflightScreenCaptureAccess()` / `CGRequestScreenCaptureAccess()`;
/// deep-links to Settings and drives the relaunch flow. Stub for slice 1.
struct PermissionService {
    func hasScreenCaptureAccess() -> Bool {
        // TODO(slice: permission): CGPreflightScreenCaptureAccess().
        return false
    }
}
