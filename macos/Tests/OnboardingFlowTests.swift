import Testing
@testable import Translator_Everywhere

@Suite("OnboardingFlow — step routing")
struct OnboardingFlowTests {

    @Test("starts on Welcome regardless of permission")
    func startsOnWelcome() {
        #expect(OnboardingFlow.initialStep(permissionGranted: true) == .welcome)
        #expect(OnboardingFlow.initialStep(permissionGranted: false) == .welcome)
    }

    @Test("Welcome → Done when permission already granted")
    func welcomeToDoneWhenGranted() {
        var flow = OnboardingFlow(step: .welcome)
        flow.advance(permissionGranted: true)
        #expect(flow.step == .done)
        #expect(flow.isComplete)
    }

    @Test("Welcome → Screen Recording when not granted")
    func welcomeToScreenRecordingWhenNotGranted() {
        var flow = OnboardingFlow(step: .welcome)
        flow.advance(permissionGranted: false)
        #expect(flow.step == .screenRecording)
        #expect(!flow.isComplete)
    }

    @Test("Screen Recording is sticky until granted")
    func screenRecordingSticky() {
        var flow = OnboardingFlow(step: .screenRecording)
        flow.advance(permissionGranted: false)
        #expect(flow.step == .screenRecording)
        flow.advance(permissionGranted: true)
        #expect(flow.step == .done)
    }

    @Test("Done is terminal")
    func doneIsTerminal() {
        var flow = OnboardingFlow(step: .done)
        flow.advance(permissionGranted: false)
        #expect(flow.step == .done)
        flow.advance(permissionGranted: true)
        #expect(flow.step == .done)
    }

    @Test("after relaunch: granted jumps to Done, ungranted stays on Screen Recording")
    func stepAfterRelaunch() {
        #expect(OnboardingFlow.stepAfterRelaunch(permissionGranted: true) == .done)
        #expect(OnboardingFlow.stepAfterRelaunch(permissionGranted: false) == .screenRecording)
    }
}
