import Foundation

/// The three onboarding steps (DESIGN §2f).
enum OnboardingStep: Int, CaseIterable, Sendable {
    case welcome
    case screenRecording
    case done

    /// The NSWindow title for this step. The in-content heading stays separate
    /// (it's longer / more descriptive); the title bar tracks the step so it
    /// doesn't sit stuck on "Welcome" as the user advances.
    var windowTitle: String {
        switch self {
        case .welcome: return "Welcome"
        case .screenRecording: return "Screen Recording"
        case .done: return "All Set"
        }
    }
}

/// Pure step-routing logic for first-run onboarding (DESIGN §2f).
///
/// Kept free of any UI / AppKit so the routing is unit-testable. The rule from
/// the spec: Welcome always opens first; advancing from Welcome jumps straight
/// to Done when Screen Recording is already granted, otherwise it lands on the
/// sticky Screen Recording step. The Screen Recording step only advances to Done
/// once permission is detected as granted (which, in practice, happens after a
/// relaunch).
struct OnboardingFlow {

    /// The current step.
    private(set) var step: OnboardingStep

    init(step: OnboardingStep = .welcome) {
        self.step = step
    }

    /// The first step to show on launch given the current permission state.
    /// Granted → still start at Welcome (a one-screen hello), but advancing
    /// skips the permission step. Not granted → Welcome too, then the user is
    /// routed into the permission step.
    static func initialStep(permissionGranted _: Bool) -> OnboardingStep {
        .welcome
    }

    /// Advances from the current step. `permissionGranted` decides the branch:
    /// - From `.welcome`: granted → `.done`; not granted → `.screenRecording`.
    /// - From `.screenRecording`: granted → `.done`; not granted → stays put
    ///   (the step is "sticky" until the user grants and relaunches).
    /// - From `.done`: terminal, no change.
    mutating func advance(permissionGranted: Bool) {
        switch step {
        case .welcome:
            step = permissionGranted ? .done : .screenRecording
        case .screenRecording:
            if permissionGranted { step = .done }
        case .done:
            break
        }
    }

    /// The step the flow should resume on after a relaunch, given the freshly
    /// re-checked permission. Granted → jump to Done; still not granted → stay
    /// on the (sticky) Screen Recording step with a softened hint.
    static func stepAfterRelaunch(permissionGranted: Bool) -> OnboardingStep {
        permissionGranted ? .done : .screenRecording
    }

    /// `true` once onboarding has reached its terminal step.
    var isComplete: Bool { step == .done }
}
