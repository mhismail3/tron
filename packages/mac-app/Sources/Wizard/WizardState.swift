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

    /// Existing-install detection result. Set on entry so the combined
    /// Install step can either install, repair a partial install, or show
    /// the already-installed/reset state without a placeholder page.
    var existingInstallStatus: ExistingInstallStatus = .none

    /// Outcome of the install pipeline. Set when the install step
    /// completes (or fails). The Pairing step blocks until non-nil.
    var installOutcome: InstallOutcome?

    /// Monotonic user intent counter for the Install step. The wizard
    /// must never start copying binaries or writing launchd state just
    /// because the user landed on the page; pressing the Install CTA is
    /// what increments this value and lets `InstallStep` run.
    var installRequestID: Int = 0

    /// Highest install request ID the Install step has consumed. This
    /// keeps the pipeline idempotent across back/forward navigation:
    /// SwiftUI remounts `InstallStep` when the user returns to it,
    /// but a previously handled request must not run again unless the
    /// user presses Install/Retry and creates a new request ID.
    private(set) var handledInstallRequestID: Int = 0

    var hasUnhandledInstallRequest: Bool {
        installRequestID > handledInstallRequestID
    }

    /// True only while the Install step is actively mutating disk or
    /// launchd. `WizardShell` reads this to turn the primary CTA into a
    /// disabled "Installing…" affordance instead of letting a second
    /// click enqueue another pipeline.
    var installIsRunning = false

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
            let persisted = raw.flatMap(WizardStep.init(rawValue:)) ?? .welcome
            // Only resume at steps that are safe to cold-start on.
            // Post-install steps (.permissions, .pairingInfo, .done)
            // depend on transient state (installOutcome, pairingPayload,
            // …) that doesn't survive a relaunch; if we honour those on
            // cold boot the user lands mid-wizard with greyed-out
            // Continue buttons and nothing to click. Clamp them back to
            // welcome so onboarding always has a coherent entry point.
            self.step = Self.isSafeToResume(persisted) ? persisted : .welcome
            if self.step != persisted {
                defaults.set(self.step.rawValue, forKey: Self.stepStorageKey)
            }
        }
    }

    /// Steps the wizard can cold-resume at without transient runtime
    /// state. Pre-permissions steps are always safe; post-install steps
    /// assume `installOutcome` / `pairingPayload` / `permissionStatuses`
    /// from an earlier navigation, so cold-booting into them strands the
    /// user behind a disabled Continue button.
    private static func isSafeToResume(_ step: WizardStep) -> Bool {
        switch step {
        case .welcome, .tailscale, .install:
            return true
        case .permissions, .pairingInfo, .done:
            return false
        }
    }

    /// Advances to the next step in the canonical sequence.
    func advance() {
        let candidates = WizardStep.allCases
        guard let currentIndex = candidates.firstIndex(of: step),
              currentIndex + 1 < candidates.count else {
            return
        }
        let next = candidates[currentIndex + 1]
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
        installRequestID = 0
        handledInstallRequestID = 0
        installIsRunning = false
        pairingPayload = nil
    }

    /// Explicitly starts or retries the install pipeline. This is the
    /// only public entry point that may cause `InstallStep` to mutate
    /// disk/launchd state; view appearance is observational only.
    func requestInstall() {
        installRequestID += 1
    }

    func markInstallRequestHandled(_ requestID: Int) {
        handledInstallRequestID = max(handledInstallRequestID, requestID)
    }

    func resetInstallRunState() {
        installOutcome = nil
        installRequestID = 0
        handledInstallRequestID = 0
        installIsRunning = false
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
