import ApplicationServices
import Testing
@testable import TronMac

@Suite("Mac Operator actuator")
struct MacOperatorActuatorTests {
    @Test("emergency stop invalidates generations and only native code resumes it")
    func emergencyStopGeneration() {
        let state = MacOperatorSafetyState()
        let initial = state.snapshot()
        #expect(!initial.isStopped)

        state.stop()
        let stopped = state.snapshot()
        #expect(stopped.isStopped)
        #expect(stopped.generation == initial.generation + 1)

        state.resumeFromNativeUI()
        let resumed = state.snapshot()
        #expect(!resumed.isStopped)
        #expect(resumed.generation == stopped.generation + 1)
    }

    @Test("focused-window identity rejects a same-app window switch")
    func focusedWindowIdentity() {
        let observedWindow = AXUIElementCreateSystemWide()
        #expect(MacOperatorActuator.matchesFocusedWindow(
            observedWindow: observedWindow,
            observedWindowNumber: 41,
            observedProcessIdentifier: 700,
            focusedWindow: observedWindow,
            focusedWindowNumber: 41,
            focusedProcessIdentifier: 700
        ))
        #expect(!MacOperatorActuator.matchesFocusedWindow(
            observedWindow: observedWindow,
            observedWindowNumber: 41,
            observedProcessIdentifier: 700,
            focusedWindow: observedWindow,
            focusedWindowNumber: 42,
            focusedProcessIdentifier: 700
        ))
    }
}
