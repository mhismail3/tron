import Foundation
import Observation

/// Steps of the iOS onboarding wizard, in canonical forward order.
///
/// **Persistence contract**: the `rawValue` strings double as
/// `@AppStorage("onboardingStep")` values AND as the `step` property in
/// PostHog `onboarding_step_completed` events. A rename without migration
/// would silently fragment both — `OnboardingStepTests` guards.
///
/// **Power-user shortcut**: `welcome → pairing` (skipping `tailscale` and
/// `macInstall`) is the "I already have Tron running" path. Once past
/// `pairing`, `skipToPairing()` is a no-op so users can't accidentally
/// rewind their progress.
enum OnboardingStep: String, CaseIterable, Codable, Equatable {
    case welcome
    case tailscale
    case macInstall
    case pairing
    case provider
    case telemetryConsent
    case notifications
    case done

    /// Default step for a fresh install.
    static let initial: OnboardingStep = .welcome

    /// Walk one step forward in the canonical sequence. `done` is terminal.
    func next() -> OnboardingStep {
        let all = Self.allCases
        guard let idx = all.firstIndex(of: self), idx < all.count - 1 else {
            return self
        }
        return all[idx + 1]
    }

    /// Walk one step back in the canonical sequence. `welcome` is the floor.
    func previous() -> OnboardingStep {
        let all = Self.allCases
        guard let idx = all.firstIndex(of: self), idx > 0 else {
            return self
        }
        return all[idx - 1]
    }

    /// Power-user shortcut: jump to `pairing` from any pre-pairing step.
    /// On or after pairing this is a no-op.
    func skipToPairing() -> OnboardingStep {
        switch self {
        case .welcome, .tailscale, .macInstall: return .pairing
        case .pairing, .provider, .telemetryConsent, .notifications, .done: return self
        }
    }

    /// True for steps that come after `.pairing`. Used by the migration
    /// helper to decide whether a user landing post-pairing should be
    /// treated as "already paired" for resume purposes.
    var isPostPairing: Bool {
        switch self {
        case .welcome, .tailscale, .macInstall, .pairing: return false
        case .provider, .telemetryConsent, .notifications, .done: return true
        }
    }
}

/// Observable model behind `OnboardingFlowView`. Owns the resume marker,
/// pairing-form inputs, telemetry-consent flag, and inline error surface.
///
/// **Persistence**: explicitly uses an injected `UserDefaults` (defaulted
/// to `.standard`). We deliberately do NOT route through
/// `NSUbiquitousKeyValueStore` — onboarding completion is per-device, not
/// per-iCloud-account, per Section N.18 of the onboarding plan. Otherwise
/// "I onboarded on iPad" would falsely flag the iPhone as onboarded.
///
/// **Why `@Observable` + manual storage** (vs `@AppStorage`): SwiftUI's
/// `@AppStorage` doesn't compose with `@Observable` cleanly and isn't
/// injectable for tests. Hand-rolled UserDefaults reads/writes give us a
/// testable seam.
@Observable
@MainActor
final class OnboardingState {

    // MARK: - Storage keys (public so tests + migration helpers reference one source)

    // `nonisolated` so non-main-actor helpers (like
    // `OnboardingMigrationDecider`, which is a plain enum) can read these
    // keys without crossing actor boundaries. The strings are immutable
    // value types — no isolation is needed for safety.
    nonisolated static let stepStorageKey = "onboardingStep"
    nonisolated static let completionStorageKey = "onboardingComplete"
    nonisolated static let telemetryConsentStorageKey = "telemetryEnabled"
    /// Mirrors `SettingsState.cachedPresetsKey` — onboarding-migration helper
    /// reads it. Kept identical via a canary test in
    /// `OnboardingMigrationTests.cachedPresetsKeyCanary`.
    nonisolated static let cachedPresetsKey = "cachedConnectionPresets"

    // MARK: - Step

    var step: OnboardingStep {
        didSet { defaults.set(step.rawValue, forKey: Self.stepStorageKey) }
    }

    // MARK: - Pairing inputs

    var pairingHost: String = ""
    var pairingPort: String = AppConstants.prodPort
    var pairingToken: String = ""
    var pairingLabel: String = "My Mac"

    /// Inline failure for the Connect button. `nil` clears the label.
    var pairingError: PairingStepValidator.Failure?

    /// True while a `system.ping` round-trip is in flight; the View disables
    /// the form and shows a progress indicator.
    var isConnecting: Bool = false

    // MARK: - Telemetry consent

    var telemetryConsent: Bool = false

    // MARK: - Storage

    @ObservationIgnored
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults

        // Resume position. Garbage in defaults falls back to `.welcome`.
        if let raw = defaults.string(forKey: Self.stepStorageKey),
           let restored = OnboardingStep(rawValue: raw) {
            self.step = restored
        } else {
            self.step = .initial
        }

        self.telemetryConsent = defaults.bool(forKey: Self.telemetryConsentStorageKey)
    }

    // MARK: - Navigation

    func advance() { step = step.next() }
    func goBack() { step = step.previous() }
    func skipToPairing() { step = step.skipToPairing() }

    /// Final commit — flips the AppStorage flag the first-run gate observes
    /// and marks the wizard as terminal.
    func complete() {
        defaults.set(true, forKey: Self.completionStorageKey)
        step = .done
    }

    /// Apply a parsed pairing payload to the form. Preserves the user's
    /// label if they've typed something other than the default.
    ///
    /// Delegates the field-distribution rule (including the "treat 'My Mac'
    /// as placeholder" semantics) to `PairingPayload.distributing(...)` so
    /// the same logic powers `AddOrEditServerSheet` (add mode).
    func acceptPairingPayload(_ payload: PairingURLParser.PairingPayload) {
        let distributed = payload.distributing(currentLabel: pairingLabel)
        pairingHost = distributed.host
        pairingPort = distributed.port
        pairingToken = distributed.token
        pairingLabel = distributed.label
        pairingError = nil
    }

    /// Toggle telemetry consent and persist immediately so a kill-and-relaunch
    /// preserves the user's intent.
    func setTelemetryConsent(_ enabled: Bool) {
        telemetryConsent = enabled
        defaults.set(enabled, forKey: Self.telemetryConsentStorageKey)
    }

    /// Reset the wizard to its initial state. Used by tests and the
    /// "Re-run onboarding" debug action in the diagnostics page.
    ///
    /// **Migration contract**: clears `cachedConnectionPresets` alongside
    /// the completion / step keys so that `OnboardingMigrationDecider`
    /// (which auto-completes onboarding when cached presets exist) does
    /// NOT silently re-skip the wizard on the next launch. See
    /// `packages/ios-app/.claude/rules/onboarding.md` ("Migration").
    func reset() {
        defaults.set(false, forKey: Self.completionStorageKey)
        defaults.set(false, forKey: Self.telemetryConsentStorageKey)
        defaults.set(OnboardingStep.initial.rawValue, forKey: Self.stepStorageKey)
        defaults.removeObject(forKey: Self.cachedPresetsKey)
        step = .initial
        pairingHost = ""
        pairingPort = AppConstants.prodPort
        pairingToken = ""
        pairingLabel = "My Mac"
        pairingError = nil
        telemetryConsent = false
        isConnecting = false
    }
}
