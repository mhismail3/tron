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
        #expect(state.pairingPayload == nil)
        #expect(state.tailscaleStatus == nil)
        #expect(state.existingInstallStatus == .none)
    }

    @Test("advance walks the canonical sequence")
    func advanceWalks() {
        let (defaults, cleanup) = Self.isolatedDefaults()
        defer { cleanup() }
        let state = WizardState(defaults: defaults)
        let expected: [WizardStep] = [.tailscale, .existingInstall, .permissions, .install, .pairingInfo, .done]
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
        state.advance(); state.advance() // welcome → tailscale → existingInstall
        #expect(state.step == .existingInstall)
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
        state.advance(); state.advance() // existingInstall
        #expect(defaults.string(forKey: WizardState.stepStorageKey) == WizardStep.existingInstall.rawValue)

        // Re-instantiating from the same defaults resumes there.
        let revived = WizardState(defaults: defaults)
        #expect(revived.step == .existingInstall)
    }

    @Test("reset wipes all transient state and persistent flags")
    func resetWipes() {
        let (defaults, cleanup) = Self.isolatedDefaults()
        defer { cleanup() }
        let state = WizardState(defaults: defaults)
        state.advance(); state.advance()
        state.installOutcome = .success
        state.pairingPayload = PairingPayload(host: "1.2.3.4", port: 9847, token: "x", label: nil)
        state.tailscaleStatus = .signedIn(ipv4: "100.1.2.3")
        state.permissionStatuses[.fullDiskAccess] = .granted
        state.existingInstallStatus = .installed(version: "0.5.0")
        state.complete()

        state.reset()
        #expect(state.step == .welcome)
        #expect(state.installOutcome == nil)
        #expect(state.pairingPayload == nil)
        #expect(state.tailscaleStatus == nil)
        #expect(state.permissionStatuses.isEmpty)
        #expect(state.existingInstallStatus == .none)
        #expect(defaults.bool(forKey: WizardState.onboardingCompleteKey) == false)
        #expect(defaults.string(forKey: WizardState.stepStorageKey) == WizardStep.welcome.rawValue)
    }

    @Test("legacy step rawValue from UserDefaults is honored")
    func revivesFromRawValue() {
        let (defaults, cleanup) = Self.isolatedDefaults()
        defer { cleanup() }
        defaults.set(WizardStep.permissions.rawValue, forKey: WizardState.stepStorageKey)
        let state = WizardState(defaults: defaults)
        #expect(state.step == .permissions)
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

    @Test("initialStep nil falls back to persisted step (no overwrite)")
    func initialStepNilHonorsPersisted() {
        let (defaults, cleanup) = Self.isolatedDefaults()
        defer { cleanup() }
        defaults.set(WizardStep.permissions.rawValue, forKey: WizardState.stepStorageKey)
        let state = WizardState(defaults: defaults, initialStep: nil)
        #expect(state.step == .permissions)
    }
}
