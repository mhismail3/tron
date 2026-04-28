import Foundation
import Observation

/// Observable model behind `OnboardingFlowView`. Owns the step selection,
/// pairing form, completion flag, and inline error surface for the
/// first-run sheet.
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
        case workspace
        case anthropic
        case openAI
        case providers
        case services
        case model

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
            case .workspace:
                return "Default workspace"
            case .anthropic:
                return "Anthropic"
            case .openAI:
                return "OpenAI"
            case .providers:
                return "Other providers"
            case .services:
                return "Search services"
            case .model:
                return "Default model"
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

    /// Unlocks the setup pages that follow the Mac connection page.
    ///
    /// The sheet is swipeable, but setup pages depend on a live paired
    /// server for settings/auth RPCs. Keep this transient: onboarding
    /// completion is only persisted after the final setup page.
    var hasPairedMac = false

    var pairingHost: String = ""
    var pairingPort: String = AppConstants.prodPort
    var pairingToken: String = ""
    var pairingLabel: String = "My Mac"

    /// Inline failure for the Connect button. `nil` clears the label.
    var pairingError: PairingStepValidator.Failure?

    /// True while a `system.ping` round-trip is in flight; the View disables
    /// the form and shows a progress indicator.
    var isConnecting: Bool = false

    /// Effective server settings and masked auth state loaded immediately
    /// after pairing. The setup pages read this so re-pairing a previously
    /// forgotten server shows its existing choices instead of blank defaults.
    var setupSnapshot = OnboardingSetupSnapshot()

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
    /// server name if they've typed something other than the default.
    ///
    /// Delegates the field-distribution rule (including the "treat 'My Mac'
    /// as placeholder" semantics) to `PairingPayload.distributing(...)`.
    func acceptPairingPayload(_ payload: PairingURLParser.PairingPayload) {
        beginPairingEntry()
        let distributed = payload.distributing(currentLabel: pairingLabel)
        currentStep = .connect
        pairingHost = distributed.host
        pairingPort = distributed.port
        pairingToken = distributed.token
        pairingLabel = distributed.label
        pairingError = nil
    }

    func hydrateSetup(
        serverId: String,
        settings: ServerSettings,
        authState: AuthState?,
        authLoadError: String? = nil
    ) {
        setupSnapshot.hydrate(
            serverId: serverId,
            settings: settings,
            authState: authState,
            authLoadError: authLoadError
        )
    }

    func refreshSetupAuth(_ authState: AuthState) {
        setupSnapshot.refreshAuth(authState)
    }

    /// Clears setup state before the user pairs or re-pairs a server.
    ///
    /// A completed onboarding run can leave `hasPairedMac` true in memory.
    /// Starting a new pairing must relock server-backed setup pages until the
    /// new active server connects and fresh `settings.get` values arrive.
    func beginPairingEntry() {
        hasPairedMac = false
        pairingError = nil
        isConnecting = false
        setupSnapshot.reset()
    }

    /// Reset the sheet to its initial state. Used by tests and any
    /// explicit "run onboarding again" debug path.
    func reset() {
        defaults.set(false, forKey: Self.completionStorageKey)
        currentStep = .welcome
        hasPairedMac = false
        pairingHost = ""
        pairingPort = AppConstants.prodPort
        pairingToken = ""
        pairingLabel = "My Mac"
        pairingError = nil
        isConnecting = false
        setupSnapshot.reset()
    }
}
