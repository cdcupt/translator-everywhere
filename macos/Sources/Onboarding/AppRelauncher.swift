import AppKit

/// Cleanly quits and relaunches the app (DESIGN §2f — the relaunch problem).
///
/// macOS only honours a *newly* granted Screen Recording permission after the
/// app restarts. The standard trick: detach a tiny shell process that waits for
/// our PID to exit, then re-opens the app bundle, and immediately terminate
/// ourselves. `/usr/bin/open` re-launches the bundle as a fresh process so the
/// new permission takes effect.
@MainActor
enum AppRelauncher {

    /// Schedules a relaunch and terminates the current instance.
    ///
    /// Uses a detached `/bin/sh` that polls for this process to disappear before
    /// re-opening the bundle, avoiding a race where `open` no-ops because the
    /// app is still considered running.
    static func relaunch() {
        let bundlePath = Bundle.main.bundlePath
        let pid = ProcessInfo.processInfo.processIdentifier

        let task = Process()
        task.launchPath = "/bin/sh"
        task.arguments = [
            "-c",
            // Wait until our PID is gone, then re-open the bundle.
            "while /bin/kill -0 \(pid) 2>/dev/null; do /bin/sleep 0.1; done; "
                + "/usr/bin/open \"\(bundlePath)\"",
        ]
        do {
            try task.run()
        } catch {
            NSLog("[TE] Relaunch failed to spawn helper: \(error.localizedDescription)")
        }

        NSApp.terminate(nil)
    }
}
