import Foundation
import Observation

/// Observable model behind `OnboardingFlowView`. Owns the pairing form,
/// completion flag, and inline error surface for the first-run sheet.
///
/// **Persistence**: explicitly uses an injected `UserDefaults` (defaulted
/// to `.standard`). We deliberately do NOT route through
/// `NSUbiquitousKeyValueStore` — onboarding completion is per-device, not
/// per-iCloud-account. Otherwise "I paired on iPad" would falsely mark
/// the iPhone as paired too.
///
/// **Why `@Observable` + manual storage** (vs `@AppStorage`): SwiftUI's
/// `@AppStorage` doesn't compose with `@Observable` cleanly and isn't
/// injectable for tests. Hand-rolled UserDefaults reads/writes give us a
/// testable surface.
@Observable
@MainActor
final class OnboardingState {

    enum Step: Int, CaseIterable, Hashable {
        case welcome
        case installTailscale
        case installMac
        case connect

        var toolbarTitle: String {
            switch self {
            case .welcome:
                return "Welcome to Tron"
            case .installTailscale:
                return "Install Tailscale"
            case .installMac:
                return "Install Tron Server"
            case .connect:
                return "Connect your Mac"
            }
        }
    }

    // MARK: - Storage keys

    // `nonisolated` so tests and app bootstrap code can read this key
    // without crossing actor boundaries. The string is an immutable value
    // type — no isolation is needed for safety.
    nonisolated static let completionStorageKey = "onboardingComplete"

    // MARK: - Pairing inputs

    var currentStep: Step = .welcome

    var pairingHost: String = ""
    var pairingPort: String = AppConstants.prodPort
    var pairingToken: String = ""
    var pairingLabel: String = "My Mac"

    /// Inline failure for the Connect button. `nil` clears the label.
    var pairingError: PairingStepValidator.Failure?

    /// True while a `system.ping` round-trip is in flight; the View disables
    /// the form and shows a progress indicator.
    var isConnecting: Bool = false

    // MARK: - Storage

    @ObservationIgnored
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// Final commit — flips the AppStorage flag the first-run sheet observes
    /// and dismisses the flow.
    func complete() {
        defaults.set(true, forKey: Self.completionStorageKey)
    }

    /// Apply a parsed pairing payload to the form. Preserves the user's
    /// label if they've typed something other than the default.
    ///
    /// Delegates the field-distribution rule (including the "treat 'My Mac'
    /// as placeholder" semantics) to `PairingPayload.distributing(...)` so
    /// the same logic powers `AddOrEditServerSheet` (add mode).
    func acceptPairingPayload(_ payload: PairingURLParser.PairingPayload) {
        let distributed = payload.distributing(currentLabel: pairingLabel)
        currentStep = .connect
        pairingHost = distributed.host
        pairingPort = distributed.port
        pairingToken = distributed.token
        pairingLabel = distributed.label
        pairingError = nil
    }

    /// Reset the sheet to its initial state. Used by tests and any
    /// explicit "run onboarding again" debug path.
    func reset() {
        defaults.set(false, forKey: Self.completionStorageKey)
        currentStep = .welcome
        pairingHost = ""
        pairingPort = AppConstants.prodPort
        pairingToken = ""
        pairingLabel = "My Mac"
        pairingError = nil
        isConnecting = false
    }
}
