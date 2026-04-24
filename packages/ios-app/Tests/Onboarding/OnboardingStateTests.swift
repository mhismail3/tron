import Foundation
import Testing
@testable import TronMobile

/// `OnboardingState` is the `@Observable` model behind `OnboardingFlowView`.
/// It owns:
///   - the current `step` (resume marker for kill-and-relaunch),
///   - pairing form inputs (host / port / token / label),
///   - telemetry-consent toggle,
///   - the active `pairingError` classification (surfaced inline by the
///     PairingStep view),
///   - `isConnecting` lock so the Connect button can show progress.
///
/// The tests below pin down the API surface that the View depends on AND
/// the persistence semantics (UserDefaults, NOT NSUbiquitousKeyValueStore
/// per Section N.18 of the plan — onboarding completion is per-device,
/// not iCloud-synced).
@Suite("OnboardingState")
@MainActor
struct OnboardingStateTests {

    // MARK: - Defaults

    @Test("Fresh state defaults to .welcome with empty pairing inputs")
    func defaultsAreSensible() {
        let state = OnboardingState(defaults: ephemeralDefaults())
        #expect(state.step == .welcome)
        #expect(state.pairingHost.isEmpty)
        #expect(state.pairingPort == AppConstants.prodPort)
        #expect(state.pairingToken.isEmpty)
        #expect(state.pairingLabel == "My Mac")
        #expect(state.telemetryConsent == false)
        #expect(state.isConnecting == false)
        #expect(state.pairingError == nil)
    }

    // MARK: - Navigation

    @Test("advance() walks step forward and persists position")
    func advancePersists() {
        let defaults = ephemeralDefaults()
        let state = OnboardingState(defaults: defaults)
        state.advance()
        #expect(state.step == .tailscale)
        #expect(defaults.string(forKey: OnboardingState.stepStorageKey) == "tailscale")
        state.advance()
        #expect(state.step == .macInstall)
        state.advance()
        #expect(state.step == .pairing)
    }

    @Test("goBack() walks step back and persists position")
    func goBackPersists() {
        let defaults = ephemeralDefaults()
        let state = OnboardingState(defaults: defaults)
        state.step = .pairing
        state.goBack()
        #expect(state.step == .macInstall)
        #expect(defaults.string(forKey: OnboardingState.stepStorageKey) == "macInstall")
    }

    @Test("skipToPairing() jumps from welcome to pairing in one shot")
    func skipFromWelcome() {
        let defaults = ephemeralDefaults()
        let state = OnboardingState(defaults: defaults)
        state.skipToPairing()
        #expect(state.step == .pairing)
        #expect(defaults.string(forKey: OnboardingState.stepStorageKey) == "pairing")
    }

    @Test("complete() flips the AppStorage flag AND lands on .done")
    func completeFlipsFlag() {
        let defaults = ephemeralDefaults()
        let state = OnboardingState(defaults: defaults)
        state.complete()
        #expect(state.step == .done)
        #expect(defaults.bool(forKey: OnboardingState.completionStorageKey) == true)
    }

    // MARK: - Re-entrancy

    @Test("Constructor restores step from persisted UserDefaults")
    func restoresPersistedStep() {
        let defaults = ephemeralDefaults()
        defaults.set("provider", forKey: OnboardingState.stepStorageKey)
        let state = OnboardingState(defaults: defaults)
        #expect(state.step == .provider)
    }

    @Test("Garbage in persisted step falls back to .welcome (defensive)")
    func corruptStepFallsBack() {
        let defaults = ephemeralDefaults()
        defaults.set("garbage-step-name", forKey: OnboardingState.stepStorageKey)
        let state = OnboardingState(defaults: defaults)
        #expect(state.step == .welcome)
    }

    @Test("Constructor restores telemetryConsent from persisted UserDefaults")
    func restoresTelemetryConsent() {
        let defaults = ephemeralDefaults()
        defaults.set(true, forKey: OnboardingState.telemetryConsentStorageKey)
        let state = OnboardingState(defaults: defaults)
        #expect(state.telemetryConsent == true)
    }

    @Test("setTelemetryConsent(_:) writes through to UserDefaults")
    func telemetryConsentPersists() {
        let defaults = ephemeralDefaults()
        let state = OnboardingState(defaults: defaults)
        state.setTelemetryConsent(true)
        #expect(state.telemetryConsent == true)
        #expect(defaults.bool(forKey: OnboardingState.telemetryConsentStorageKey) == true)
        state.setTelemetryConsent(false)
        #expect(defaults.bool(forKey: OnboardingState.telemetryConsentStorageKey) == false)
    }

    // MARK: - Pairing payload application

    @Test("acceptPairingPayload(_:) populates host/port/token from a parsed URL")
    func acceptPairingPayload() {
        let state = OnboardingState(defaults: ephemeralDefaults())
        let payload = PairingURLParser.PairingPayload(
            host: "100.64.0.7",
            port: 9847,
            token: "deadbeef",
            label: "Friend's Mac"
        )
        state.acceptPairingPayload(payload)
        #expect(state.pairingHost == "100.64.0.7")
        #expect(state.pairingPort == "9847")
        #expect(state.pairingToken == "deadbeef")
        // Optional label only overrides if user hasn't typed something.
        #expect(state.pairingLabel == "Friend's Mac")
    }

    @Test("acceptPairingPayload preserves user's label if already typed")
    func acceptPairingPayloadPreservesLabel() {
        let state = OnboardingState(defaults: ephemeralDefaults())
        state.pairingLabel = "Custom Name"
        let payload = PairingURLParser.PairingPayload(
            host: "h", port: 1, token: "t", label: "From QR"
        )
        state.acceptPairingPayload(payload)
        // The user's prior label wins.
        #expect(state.pairingLabel == "Custom Name")
    }

    @Test("acceptPairingPayload clears any inline pairing error")
    func acceptPayloadClearsError() {
        let state = OnboardingState(defaults: ephemeralDefaults())
        state.pairingError = .unauthorized
        state.acceptPairingPayload(.init(host: "h", port: 1, token: "t", label: nil))
        #expect(state.pairingError == nil)
    }

    // MARK: - reset() — for tests + diagnostics-page "rerun onboarding"

    @Test("reset() returns to .welcome and clears all flags + inputs")
    func resetReturnsToWelcome() {
        let defaults = ephemeralDefaults()
        let state = OnboardingState(defaults: defaults)
        state.pairingHost = "h"
        state.pairingPort = "1"
        state.pairingToken = "t"
        state.pairingLabel = "L"
        state.telemetryConsent = true
        state.advance() // move off welcome
        defaults.set(true, forKey: OnboardingState.completionStorageKey)

        state.reset()

        #expect(state.step == .welcome)
        #expect(state.pairingHost.isEmpty)
        #expect(state.pairingPort == AppConstants.prodPort)
        #expect(state.pairingToken.isEmpty)
        #expect(state.pairingLabel == "My Mac")
        #expect(state.telemetryConsent == false)
        #expect(defaults.bool(forKey: OnboardingState.completionStorageKey) == false)
        #expect(defaults.string(forKey: OnboardingState.stepStorageKey) == "welcome")
    }

    @Test("reset() clears cachedConnectionPresets so migration can't silently re-skip")
    func resetClearsCachedPresets() {
        // Migration contract (rules/onboarding.md → "Migration"): if
        // `cachedConnectionPresets` survives a reset, the next launch
        // re-flips `onboardingComplete=true` via
        // `OnboardingMigrationDecider.runMigrationIfNeeded()` and the user
        // never sees the wizard they explicitly asked to re-run.
        let defaults = ephemeralDefaults()
        let preset = ConnectionPreset(
            id: "p1", label: "Mac", host: "100.64.0.1", port: 9847
        )
        let data = try! JSONEncoder().encode([preset])
        defaults.set(data, forKey: OnboardingState.cachedPresetsKey)
        defaults.set(true, forKey: OnboardingState.completionStorageKey)

        let state = OnboardingState(defaults: defaults)
        state.reset()

        #expect(defaults.data(forKey: OnboardingState.cachedPresetsKey) == nil,
                "reset() must clear the cached-presets key — see rules/onboarding.md Migration contract")
        // Sanity: post-reset, the migration decider should NOT auto-mark
        // complete on the next launch.
        let presetCount = OnboardingMigrationDecider.cachedPresetCount(defaults: defaults)
        #expect(presetCount == 0)
        #expect(OnboardingMigrationDecider.shouldAutoMarkComplete(
            hasCompletedOnboarding: false,
            cachedPresetCount: presetCount
        ) == false)
    }

    // MARK: - Helpers

    /// Returns an isolated UserDefaults suite so tests don't leak state into
    /// the simulator's app domain or each other.
    private func ephemeralDefaults() -> UserDefaults {
        let suiteName = "test.onboarding.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }
}
