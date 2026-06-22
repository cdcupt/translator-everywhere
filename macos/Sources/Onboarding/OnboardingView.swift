import SwiftUI

/// Drives the onboarding window's step state and bridges to the permission /
/// relaunch side-effects (DESIGN §2f).
///
/// The pure routing lives in `OnboardingFlow`; this observable wrapper adds the
/// "returned without granting" hint and the AppKit side-effects (open Settings,
/// relaunch). Marked `@MainActor` because it touches `PermissionService` /
/// AppKit.
@MainActor
final class OnboardingModel: ObservableObject {

    @Published private(set) var step: OnboardingStep
    /// `true` once the user has come back from System Settings still ungranted,
    /// so the Screen Recording copy can soften (DESIGN §4).
    @Published private(set) var didReturnUngranted = false

    private var flow: OnboardingFlow
    private let permission: PermissionService
    private let onFinish: () -> Void

    init(
        permission: PermissionService = PermissionService(),
        onFinish: @escaping () -> Void
    ) {
        self.permission = permission
        self.onFinish = onFinish
        // If permission is already granted on relaunch, resume at Done.
        let initial = OnboardingFlow.initialStep(
            permissionGranted: permission.isGranted
        )
        self.flow = OnboardingFlow(step: initial)
        self.step = initial
    }

    /// Advances from the current step, re-checking permission live.
    func advance() {
        flow.advance(permissionGranted: permission.isGranted)
        step = flow.step
        if flow.isComplete { onFinish() }
    }

    /// Opens System Settings and remembers we've sent the user there, so a
    /// later re-check that's still ungranted softens the copy.
    func openSystemSettings() {
        permission.openSettings()
        didReturnUngranted = true
    }

    /// Re-checks permission (e.g. on window focus) and advances to Done if it's
    /// now granted. Otherwise marks that the user returned without granting.
    func recheck() {
        if permission.isGranted {
            flow.advance(permissionGranted: true)
            step = flow.step
            if flow.isComplete { onFinish() }
        } else if step == .screenRecording {
            didReturnUngranted = true
        }
    }

    /// Cleanly quits and relaunches so a fresh grant takes effect.
    func quitAndReopen() {
        AppRelauncher.relaunch()
    }
}

/// The three-step onboarding window (DESIGN §2f, Fig 9).
struct OnboardingView: View {

    @ObservedObject var model: OnboardingModel

    var body: some View {
        VStack(spacing: 20) {
            content
        }
        .frame(width: 440)
        .padding(32)
        .onAppear { model.recheck() }
    }

    @ViewBuilder
    private var content: some View {
        switch model.step {
        case .welcome:
            welcome
        case .screenRecording:
            screenRecording
        case .done:
            done
        }
    }

    // MARK: - Step 1: Welcome

    private var welcome: some View {
        VStack(spacing: 16) {
            Image(systemName: "character.bubble")
                .font(.system(size: 48))
                .foregroundStyle(.tint)
            Text("Welcome to Translator Everywhere")
                .font(.title2.weight(.semibold))
                .multilineTextAlignment(.center)
            Text("Draw a box around any text on screen and read it in your "
                 + "language. Press ⌃⌥Y anytime — that's the only step.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Get Started") { model.advance() }
                .keyboardShortcut(.defaultAction)
        }
    }

    // MARK: - Step 2: Screen Recording

    private var screenRecording: some View {
        VStack(spacing: 16) {
            Image(systemName: "rectangle.dashed.badge.record")
                .font(.system(size: 48))
                .foregroundStyle(.tint)
            Text("Allow Screen Recording")
                .font(.title2.weight(.semibold))
            Text(model.didReturnUngranted
                 ? "Still off — flip the switch next to “Translator Everywhere” "
                   + "in the list, then choose Quit & Reopen."
                 : "To capture a region of your screen, macOS needs Screen "
                   + "Recording permission. We only read the box you draw — "
                   + "nothing else leaves your Mac.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Text("macOS requires a relaunch after granting.")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                Button("Open System Settings") { model.openSystemSettings() }
                Button("Quit & Reopen") { model.quitAndReopen() }
                    .keyboardShortcut(.defaultAction)
            }
        }
    }

    // MARK: - Step 3: Done

    private var done: some View {
        VStack(spacing: 16) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 48))
                .foregroundStyle(.green)
            Text("You're all set")
                .font(.title2.weight(.semibold))
            Text("Press ⌃⌥Y to try it. You can change the hotkey, engine, and "
                 + "more in Preferences anytime.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Done") { model.advance() }
                .keyboardShortcut(.defaultAction)
        }
    }
}
