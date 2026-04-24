import Foundation
import Observation

/// Persistent + transient state for the wizard. `step` survives kill +
/// relaunch via `UserDefaults` so a user who quits in the middle of
/// onboarding resumes at the same step.
///
/// Mirrors the iOS `OnboardingState` so reading them side-by-side is
/// straightforward: same key naming, same `advance()` / `goBack()`
/// idioms, same `complete()` semantics.
@MainActor
@Observable
final class WizardState {
    nonisolated static let stepStorageKey = "tron.mac.wizardStep"
    nonisolated static let onboardingCompleteKey = "tron.mac.wizardComplete"

    private let defaults: UserDefaults

    var step: WizardStep {
        didSet {
            defaults.set(step.rawValue, forKey: Self.stepStorageKey)
        }
    }

    /// Direction of the most recent navigation, set BEFORE `step` is
    /// mutated by every navigation method (`advance`, `goBack`,
    /// `skipToPairing`, `complete`). `WizardShell.slideTransition`
    /// reads this single source of truth to pick the asymmetric
    /// move-edge pair, instead of inferring direction from ordinal
    /// comparisons against a separate `previousStep` field.
    ///
    /// Why this matters: `previousStep`-based ordinal comparison was
    /// fragile around `skipToPairing` (a long forward jump that
    /// looked structurally identical to a regular advance), and around
    /// any future "fork" navigations that don't follow the canonical
    /// step ordering. An explicit, navigation-method-set field can't
    /// get out of sync with intent — back is back, forward is forward,
    /// regardless of how far either one moves.
    var slideDirection: WizardSlideDirection = .forward

    // Transient form state surfaced by individual step views.

    /// Result of the most recent Tailscale probe. Nil before the
    /// Tailscale step has run.
    var tailscaleStatus: TailscaleStatus?

    /// Per-permission grant snapshot. Updated by the Permissions step
    /// every time the view becomes active.
    var permissionStatuses: [Permission: PermissionStatus] = [:]

    /// Existing-install detection result. Set on entry to the Welcome
    /// step so we can decide whether to skip the Install step.
    var existingInstallStatus: ExistingInstallStatus = .none

    /// Outcome of the install pipeline. Set when the install step
    /// completes (or fails). The Pairing step blocks until non-nil.
    var installOutcome: InstallOutcome?

    /// Pairing payload assembled at the Pairing-info step. Populated
    /// after `system.ping` succeeds AND we read the bearer token off
    /// disk.
    var pairingPayload: PairingPayload?

    init(defaults: UserDefaults = .standard, initialStep: WizardStep? = nil) {
        self.defaults = defaults
        if let initialStep {
            // Caller (e.g. RootView re-mounting WizardView in response
            // to "Show pairing info…" from the menu bar) wins over the
            // persisted last-visited step. We still WRITE the override
            // back to defaults so kill+relaunch lands the user where
            // they were when the override was applied.
            self.step = initialStep
            defaults.set(initialStep.rawValue, forKey: Self.stepStorageKey)
        } else {
            let raw = defaults.string(forKey: Self.stepStorageKey)
            self.step = raw.flatMap(WizardStep.init(rawValue:)) ?? .welcome
        }
    }

    /// Advances to the next step in the canonical sequence. Skips
    /// install/permissions when an existing install satisfies them.
    func advance() {
        let candidates = WizardStep.allCases
        guard let currentIndex = candidates.firstIndex(of: step),
              currentIndex + 1 < candidates.count else {
            return
        }
        let next = candidates[currentIndex + 1]
        // Auto-skip install when an existing install is fully present
        // is handled by InstallStep itself — it short-circuits to
        // `installOutcome = .alreadyInstalled` and lets the user click
        // Continue, which keeps this function pure navigation.
        navigate(to: next, direction: .forward)
    }

    /// Steps backwards in the canonical sequence. Bounded at the first
    /// step.
    func goBack() {
        let candidates = WizardStep.allCases
        guard let currentIndex = candidates.firstIndex(of: step), currentIndex > 0 else { return }
        navigate(to: candidates[currentIndex - 1], direction: .backward)
    }

    /// Power-user shortcut: from Welcome, skip directly to the Pairing
    /// step on the assumption the server is already installed.
    func skipToPairing() {
        navigate(to: .pairingInfo, direction: .forward)
    }

    /// Marks the wizard complete and notifies AppDelegate to swap to
    /// menu-bar mode.
    func complete() {
        defaults.set(true, forKey: Self.onboardingCompleteKey)
        navigate(to: .done, direction: .forward)
        NotificationCenter.default.post(name: .tronWizardDidComplete, object: nil)
    }

    /// Used by tests + the diagnostics page to wipe persistent state
    /// without touching the on-disk sentinel.
    func reset() {
        defaults.removeObject(forKey: Self.stepStorageKey)
        defaults.removeObject(forKey: Self.onboardingCompleteKey)
        step = .welcome
        slideDirection = .forward
        tailscaleStatus = nil
        permissionStatuses.removeAll()
        existingInstallStatus = .none
        installOutcome = nil
        pairingPayload = nil
    }

    /// Single mutation point for step + direction. Centralises the
    /// "set direction synchronously BEFORE step" ordering invariant
    /// that `WizardShell.slideTransition` depends on. Every navigation
    /// path goes through here so the transition direction can never
    /// race the step change.
    private func navigate(to next: WizardStep, direction: WizardSlideDirection) {
        slideDirection = direction
        step = next
    }
}

/// Direction of a wizard step transition, used by
/// `WizardShell.slideTransition` to pick the asymmetric move edges.
/// `.forward` slides the outgoing view off-left and the incoming view
/// in from the right; `.backward` reverses both.
enum WizardSlideDirection: Sendable, Equatable {
    case forward
    case backward
}

/// Outcome of the install pipeline. Surfaced by the Install step so
/// the Pairing step can render a precise failure message.
enum InstallOutcome: Equatable, Sendable {
    case success
    case alreadyInstalled
    case sourceBinaryMissing
    case copyFailed(String)
    case plistWriteFailed(String)
    case launchctlFailed(String)
    case awaitPingTimedOut
}
