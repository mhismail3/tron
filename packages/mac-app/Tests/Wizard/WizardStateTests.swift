import Foundation
import Testing
@testable import TronMac

/// Tests `WizardState` step persistence + advance/back/skip/complete
/// transitions. Each test gets its own UserDefaults suite so they
/// don't bleed across runs.
@Suite("WizardState")
@MainActor
struct WizardStateTests {
    /// Returns a fresh isolated `UserDefaults` for the test, plus a
    /// cleanup closure to call when done.
    static func isolatedDefaults() -> (UserDefaults, () -> Void) {
        let suiteName = "tron.mac.wizard.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        return (defaults, {
            UserDefaults().removePersistentDomain(forName: suiteName)
        })
    }

    @Test("fresh state starts at welcome")
    func freshStarts() {
        let (defaults, cleanup) = Self.isolatedDefaults()
        defer { cleanup() }
        let state = WizardState(defaults: defaults)
        #expect(state.step == .welcome)
        #expect(state.permissionStatuses.isEmpty)
        #expect(state.installOutcome == nil)
        #expect(state.installRequestID == 0)
        #expect(state.handledInstallRequestID == 0)
        #expect(state.hasUnhandledInstallRequest == false)
        #expect(state.installIsRunning == false)
        #expect(state.pairingPayload == nil)
        #expect(state.tailscaleStatus == nil)
        #expect(state.existingInstallStatus == .none)
    }

    @Test("advance walks the canonical sequence")
    func advanceWalks() {
        let (defaults, cleanup) = Self.isolatedDefaults()
        defer { cleanup() }
        let state = WizardState(defaults: defaults)
        let expected: [WizardStep] = [.tailscale, .install, .permissions, .transcription, .iosBeta, .pairingInfo, .done]
        for step in expected {
            state.advance()
            #expect(state.step == step, "after advance, expected \(step) got \(state.step)")
        }
    }

    @Test("advance is bounded at the last step")
    func advanceBounded() {
        let (defaults, cleanup) = Self.isolatedDefaults()
        defer { cleanup() }
        let state = WizardState(defaults: defaults)
        for _ in 0..<20 { state.advance() }
        #expect(state.step == .done)
    }

    @Test("goBack steps backward")
    func goBackWorks() {
        let (defaults, cleanup) = Self.isolatedDefaults()
        defer { cleanup() }
        let state = WizardState(defaults: defaults)
        state.advance(); state.advance() // welcome → tailscale → install
        #expect(state.step == .install)
        state.goBack()
        #expect(state.step == .tailscale)
    }

    @Test("goBack is bounded at the first step")
    func goBackBounded() {
        let (defaults, cleanup) = Self.isolatedDefaults()
        defer { cleanup() }
        let state = WizardState(defaults: defaults)
        for _ in 0..<5 { state.goBack() }
        #expect(state.step == .welcome)
    }

    @Test("skipToPairing jumps directly to pairing")
    func skipToPairing() {
        let (defaults, cleanup) = Self.isolatedDefaults()
        defer { cleanup() }
        let state = WizardState(defaults: defaults)
        state.skipToPairing()
        #expect(state.step == .pairingInfo)
    }

    @Test("complete sets the done step + persists onboardingComplete=true")
    func completeFlips() async {
        let (defaults, cleanup) = Self.isolatedDefaults()
        defer { cleanup() }
        let state = WizardState(defaults: defaults)
        state.complete()
        #expect(state.step == .done)
        #expect(defaults.bool(forKey: WizardState.onboardingCompleteKey) == true)
    }

    @Test("step changes persist to UserDefaults")
    func stepPersists() {
        let (defaults, cleanup) = Self.isolatedDefaults()
        defer { cleanup() }
        let state = WizardState(defaults: defaults)
        state.advance(); state.advance() // install
        #expect(defaults.string(forKey: WizardState.stepStorageKey) == WizardStep.install.rawValue)

        // Re-instantiating from the same defaults resumes there.
        let revived = WizardState(defaults: defaults)
        #expect(revived.step == .install)
    }

    @Test("reset wipes all transient state and persistent flags")
    func resetWipes() {
        let (defaults, cleanup) = Self.isolatedDefaults()
        defer { cleanup() }
        let state = WizardState(defaults: defaults)
        state.advance(); state.advance()
        state.installOutcome = .success
        state.requestInstall()
        state.installIsRunning = true
        state.pairingPayload = PairingPayload(host: "1.2.3.4", port: 9847, token: "x", label: nil)
        state.tailscaleStatus = .signedIn(ipv4: "100.1.2.3")
        state.permissionStatuses[.fullDiskAccess] = .granted
        state.transcriptionEnabledSelection = true
        state.transcriptionOutcome = .enabled
        state.transcriptionIsApplying = true
        state.existingInstallStatus = .registered(version: "0.5.0")
        state.complete()

        state.reset()
        #expect(state.step == .welcome)
        #expect(state.installOutcome == nil)
        #expect(state.installRequestID == 0)
        #expect(state.handledInstallRequestID == 0)
        #expect(state.hasUnhandledInstallRequest == false)
        #expect(state.installIsRunning == false)
        #expect(state.pairingPayload == nil)
        #expect(state.tailscaleStatus == nil)
        #expect(state.permissionStatuses.isEmpty)
        #expect(state.transcriptionEnabledSelection == false)
        #expect(state.transcriptionOutcome == nil)
        #expect(state.transcriptionIsApplying == false)
        #expect(state.existingInstallStatus == .none)
        #expect(defaults.bool(forKey: WizardState.onboardingCompleteKey) == false)
        #expect(defaults.string(forKey: WizardState.stepStorageKey) == WizardStep.welcome.rawValue)
    }

    @Test("safe-to-resume persisted step rawValue is honored")
    func revivesFromRawValue() {
        let (defaults, cleanup) = Self.isolatedDefaults()
        defer { cleanup() }
        defaults.set(WizardStep.install.rawValue, forKey: WizardState.stepStorageKey)
        let state = WizardState(defaults: defaults)
        #expect(state.step == .install)
    }

    @Test("invalid stored step falls back to welcome")
    func invalidStoredStep() {
        let (defaults, cleanup) = Self.isolatedDefaults()
        defer { cleanup() }
        defaults.set("notAStep", forKey: WizardState.stepStorageKey)
        let state = WizardState(defaults: defaults)
        #expect(state.step == .welcome)
    }

    @Test("initialStep override wins over persisted step")
    func initialStepOverride() {
        let (defaults, cleanup) = Self.isolatedDefaults()
        defer { cleanup() }
        // Pre-seed defaults with a different step.
        defaults.set(WizardStep.tailscale.rawValue, forKey: WizardState.stepStorageKey)
        // Override should win.
        let state = WizardState(defaults: defaults, initialStep: .pairingInfo)
        #expect(state.step == .pairingInfo)
        // And it should also be persisted, so kill+relaunch lands here.
        #expect(defaults.string(forKey: WizardState.stepStorageKey) == WizardStep.pairingInfo.rawValue)
    }

    // MARK: - Cold-resume clamp
    //
    // State-dependent post-install steps depend on transient state (`installOutcome`,
    // `pairingPayload`, per-permission probes) that doesn't survive a
    // relaunch. If we honoured those on cold boot the user would land
    // mid-wizard behind a disabled Continue button with no way to recover.
    // The iOS beta handoff is static and safe to resume; these tests pin
    // both halves of that contract.

    @Test("persisted .permissions clamps back to welcome on cold start")
    func persistedPermissionsClamped() {
        let (defaults, cleanup) = Self.isolatedDefaults()
        defer { cleanup() }
        defaults.set(WizardStep.permissions.rawValue, forKey: WizardState.stepStorageKey)
        let state = WizardState(defaults: defaults)
        #expect(state.step == .welcome)
        // The clamp is written back so the next cold boot agrees.
        #expect(defaults.string(forKey: WizardState.stepStorageKey) == WizardStep.welcome.rawValue)
    }

    @Test("persisted .pairingInfo clamps back to welcome on cold start")
    func persistedPairingInfoClamped() {
        let (defaults, cleanup) = Self.isolatedDefaults()
        defer { cleanup() }
        defaults.set(WizardStep.pairingInfo.rawValue, forKey: WizardState.stepStorageKey)
        let state = WizardState(defaults: defaults)
        #expect(state.step == .welcome)
    }

    @Test("persisted .transcription clamps back to welcome on cold start")
    func persistedTranscriptionClamped() {
        let (defaults, cleanup) = Self.isolatedDefaults()
        defer { cleanup() }
        defaults.set(WizardStep.transcription.rawValue, forKey: WizardState.stepStorageKey)
        let state = WizardState(defaults: defaults)
        #expect(state.step == .welcome)
    }

    @Test("persisted .done clamps back to welcome on cold start")
    func persistedDoneClamped() {
        let (defaults, cleanup) = Self.isolatedDefaults()
        defer { cleanup() }
        defaults.set(WizardStep.done.rawValue, forKey: WizardState.stepStorageKey)
        let state = WizardState(defaults: defaults)
        #expect(state.step == .welcome)
    }

    @Test("safe-to-resume steps (welcome/tailscale/install/iOS beta) do NOT clamp")
    func safeToResumeNotClamped() {
        for step in [WizardStep.welcome, .tailscale, .install, .iosBeta] {
            let (defaults, cleanup) = Self.isolatedDefaults()
            defer { cleanup() }
            defaults.set(step.rawValue, forKey: WizardState.stepStorageKey)
            let state = WizardState(defaults: defaults)
            #expect(state.step == step, "expected \(step) to resume as-is")
        }
    }

    // MARK: - slideDirection invariants
    //
    // These pin the contract `WizardShell.slideTransition` depends on:
    // every navigation method sets `slideDirection` BEFORE mutating
    // `step`, and the value reflects the user's intent rather than
    // ordinal arithmetic. Future contributors who add new navigation
    // paths (e.g. an "Edit pairing" jump) must extend these tests so
    // the wizard's animation never goes the wrong way.

    @Test("advance sets slideDirection to forward")
    func advanceForwardDirection() {
        let (defaults, cleanup) = Self.isolatedDefaults()
        defer { cleanup() }
        let state = WizardState(defaults: defaults)
        state.advance()
        #expect(state.slideDirection == .forward)
    }

    @Test("goBack sets slideDirection to backward")
    func goBackBackwardDirection() {
        let (defaults, cleanup) = Self.isolatedDefaults()
        defer { cleanup() }
        let state = WizardState(defaults: defaults)
        state.advance() // step now tailscale
        state.goBack()
        #expect(state.slideDirection == .backward)
    }

    @Test("skipToPairing sets slideDirection to forward (long forward jump)")
    func skipToPairingForwardDirection() {
        let (defaults, cleanup) = Self.isolatedDefaults()
        defer { cleanup() }
        let state = WizardState(defaults: defaults)
        state.skipToPairing()
        #expect(state.slideDirection == .forward)
    }

    @Test("complete sets slideDirection to forward")
    func completeForwardDirection() async {
        let (defaults, cleanup) = Self.isolatedDefaults()
        defer { cleanup() }
        let state = WizardState(defaults: defaults)
        state.complete()
        #expect(state.slideDirection == .forward)
    }

    @Test("install does not start until explicitly requested")
    func installRequestIsExplicit() {
        let (defaults, cleanup) = Self.isolatedDefaults()
        defer { cleanup() }
        let state = WizardState(defaults: defaults)
        #expect(state.installRequestID == 0)
        state.advance(); state.advance() // install
        #expect(state.step == .install)
        #expect(state.installRequestID == 0)
        #expect(state.installOutcome == nil)

        state.requestInstall()
        #expect(state.installRequestID == 1)
        #expect(state.hasUnhandledInstallRequest == true)
        state.markInstallRequestHandled(state.installRequestID)
        #expect(state.handledInstallRequestID == 1)
        #expect(state.hasUnhandledInstallRequest == false)
        state.requestInstall()
        #expect(state.installRequestID == 2)
        #expect(state.hasUnhandledInstallRequest == true)
    }

    @Test("resetInstallRunState clears install request replay tracking")
    func resetInstallRunStateClearsReplayTracking() {
        let (defaults, cleanup) = Self.isolatedDefaults()
        defer { cleanup() }
        let state = WizardState(defaults: defaults)
        state.installOutcome = .success
        state.requestInstall()
        state.markInstallRequestHandled(state.installRequestID)
        state.installIsRunning = true

        state.resetInstallRunState()
        #expect(state.installOutcome == nil)
        #expect(state.installRequestID == 0)
        #expect(state.handledInstallRequestID == 0)
        #expect(state.hasUnhandledInstallRequest == false)
        #expect(state.installIsRunning == false)
    }

    @Test("reset returns slideDirection to forward (default)")
    func resetRestoresForward() {
        let (defaults, cleanup) = Self.isolatedDefaults()
        defer { cleanup() }
        let state = WizardState(defaults: defaults)
        state.advance()
        state.goBack() // direction now .backward
        #expect(state.slideDirection == .backward)
        state.reset()
        #expect(state.slideDirection == .forward)
    }

    @Test("interleaved advance/goBack flips direction each time")
    func interleavedDirection() {
        let (defaults, cleanup) = Self.isolatedDefaults()
        defer { cleanup() }
        let state = WizardState(defaults: defaults)
        state.advance(); #expect(state.slideDirection == .forward)
        state.advance(); #expect(state.slideDirection == .forward)
        state.goBack();  #expect(state.slideDirection == .backward)
        state.goBack();  #expect(state.slideDirection == .backward)
        state.advance(); #expect(state.slideDirection == .forward)
        state.goBack();  #expect(state.slideDirection == .backward)
    }

    @Test("bounded advance/goBack do NOT flip direction (no nav happened)")
    func boundedNavPreservesDirection() {
        let (defaults, cleanup) = Self.isolatedDefaults()
        defer { cleanup() }
        let state = WizardState(defaults: defaults)
        // At welcome, goBack is a no-op — direction must NOT flip.
        // (default is .forward; if a no-op flipped it, the next real
        // advance would animate as backward.)
        state.goBack()
        #expect(state.step == .welcome)
        #expect(state.slideDirection == .forward)

        // At done, advance is a no-op — direction must NOT flip.
        for _ in 0..<10 { state.advance() }
        #expect(state.step == .done)
        state.goBack() // direction → backward
        #expect(state.slideDirection == .backward)
        for _ in 0..<10 { state.goBack() }
        #expect(state.step == .welcome)
        // After repeatedly going back and bottoming out, direction
        // should still read .backward — last real nav was backward.
        #expect(state.slideDirection == .backward)
    }
}
