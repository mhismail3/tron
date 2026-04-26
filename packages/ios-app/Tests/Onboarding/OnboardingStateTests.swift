import Foundation
import Testing
@testable import TronMobile

/// `OnboardingState` is the observable model behind the first-run
/// pairing sheet. It owns only the pairing form, the completion flag,
/// inline pairing errors, and the in-flight Connect lock.
@Suite("OnboardingState")
@MainActor
struct OnboardingStateTests {

    // MARK: - Defaults

    @Test("Fresh state defaults to empty pairing inputs")
    func defaultsAreSensible() {
        let state = OnboardingState(defaults: ephemeralDefaults())
        #expect(state.pairingHost.isEmpty)
        #expect(state.pairingPort == AppConstants.prodPort)
        #expect(state.pairingToken.isEmpty)
        #expect(state.pairingLabel == "My Mac")
        #expect(state.isConnecting == false)
        #expect(state.pairingError == nil)
    }

    @Test("complete() flips the AppStorage flag")
    func completeFlipsFlag() {
        let defaults = ephemeralDefaults()
        let state = OnboardingState(defaults: defaults)
        state.complete()
        #expect(defaults.bool(forKey: OnboardingState.completionStorageKey) == true)
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

    // MARK: - reset()

    @Test("reset() clears completion flag and pairing inputs")
    func resetReturnsToPairing() {
        let defaults = ephemeralDefaults()
        let state = OnboardingState(defaults: defaults)
        state.pairingHost = "h"
        state.pairingPort = "1"
        state.pairingToken = "t"
        state.pairingLabel = "L"
        defaults.set(true, forKey: OnboardingState.completionStorageKey)

        state.reset()

        #expect(state.pairingHost.isEmpty)
        #expect(state.pairingPort == AppConstants.prodPort)
        #expect(state.pairingToken.isEmpty)
        #expect(state.pairingLabel == "My Mac")
        #expect(defaults.bool(forKey: OnboardingState.completionStorageKey) == false)
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
