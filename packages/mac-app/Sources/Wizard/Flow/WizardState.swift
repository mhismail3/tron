import Foundation
import Observation

/// Resume progress + transient state for the wizard. `step` survives
/// kill + relaunch via `UserDefaults` so a user who quits in the middle
/// of onboarding resumes at the same step. Durable completion belongs
/// exclusively to the on-disk `.onboarded` sentinel.
///
/// Shares the iOS `OnboardingState` navigation idioms (`advance()` and
/// `goBack()`), while keeping Mac completion under its sentinel owner.
@MainActor
@Observable
final class WizardState {
    nonisolated static let stepStorageKey = "tron.mac.wizardStep"

    private let defaults: UserDefaults

    var step: WizardStep {
        didSet {
            defaults.set(step.rawValue, forKey: Self.stepStorageKey)
        }
    }

    /// Direction of the most recent navigation, set BEFORE `step` is
    /// mutated by every navigation method (`advance`, `goBack`, and
    /// `skipToPairing`). `WizardShell.slideTransition`
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

    /// The helper is restarted once after Full Disk Access is enabled
    /// so grants that macOS applies on next launch are visible to the
    /// running server before pairing.
    var permissionsServerRestarted = false

    /// True while the Permissions Continue button is performing that
    /// one helper restart.
    var permissionsRestartInProgress = false

    /// Presentation-only entry snapshot for the registered-service hint.
    /// Readiness and current failures come from the explicit installation;
    /// even a registered service must be started and pinged before advancing.
    var existingInstallStatus: ExistingInstallStatus = .none

    /// Outcome of the install pipeline. Set when the install step
    /// completes (or fails). The Pairing step blocks until non-nil.
    var installOutcome: InstallOutcome?

    /// Accepted installation outlives the transient step view. This task
    /// retains its wizard owner through completion; navigation cannot cancel
    /// it or replay a consumed intent. Progress survives remounting too.
    private var installTask: Task<Void, Never>?
    var installStages: [InstallPipelineStage: InstallStageState] = [:]
    var installIsRunning: Bool { installTask != nil }

    /// Entry detection is only a presentation hint, never install authority.
    /// Once an explicit install starts, its result supersedes that observation.
    var needsInstallDetection: Bool { !installIsRunning && installOutcome == nil }

    func refreshExistingInstall(using probe: @Sendable () async -> ExistingInstallStatus) async {
        guard needsInstallDetection else { return }
        let status = await probe()
        guard !Task.isCancelled, needsInstallDetection else { return }
        existingInstallStatus = status
    }

    /// Pairing payload assembled at the Pairing-info step. Populated
    /// after `system::ping` succeeds AND we read the bearer token off
    /// disk.
    var pairingPayload: PairingPayload?

    init(defaults: UserDefaults = .standard, initialStep: WizardStep? = nil) {
        self.defaults = defaults
        if let initialStep {
            // Caller (e.g. RootView re-mounting WizardView in response
            // to "Show pairing info" from the menu bar) wins over the
            // persisted last-visited step. We still WRITE the override
            // back to defaults so kill+relaunch lands the user where
            // they were when the override was applied.
            self.step = initialStep
            defaults.set(initialStep.rawValue, forKey: Self.stepStorageKey)
        } else {
            let raw = defaults.string(forKey: Self.stepStorageKey)
            let persisted = raw.flatMap(WizardStep.init(rawValue:)) ?? .welcome
            // Only resume at steps that are safe to cold-start on.
            // State-dependent post-install steps (.permissions and
            // .pairingInfo) depend on transient state (installOutcome,
            // permissionStatuses, pairingPayload, …) that doesn't
            // survive a relaunch. The informational .iosBeta handoff
            // owns no transient runtime state and is safe to resume.
            // Done still clamps: without the sentinel, stale progress
            // must not bypass onboarding after an uninstall.
            // Clamp them back to welcome so onboarding always has a
            // coherent entry point.
            self.step = Self.isSafeToResume(persisted) ? persisted : .welcome
            if self.step != persisted {
                defaults.set(self.step.rawValue, forKey: Self.stepStorageKey)
            }
        }
    }

    /// Steps the wizard can cold-resume at without transient runtime
    /// state. Pre-permissions steps and the static iOS beta handoff are
    /// safe. Permissions/pairing require transient state, while Done is
    /// valid only within the current process until its sentinel write
    /// succeeds; relaunch without that sentinel restarts onboarding.
    private static func isSafeToResume(_ step: WizardStep) -> Bool {
        switch step {
        case .welcome, .tailscale, .install, .iosBeta:
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
    /// step on the assumption the server is already running.
    func skipToPairing() {
        navigate(to: .pairingInfo, direction: .forward)
    }

    /// Admit synchronously before another click or view task can interleave.
    /// A caller may await this task, but only this owner retires accepted work.
    @discardableResult
    func requestInstall(using setup: EnvironmentSetup) -> Task<Void, Never> {
        if let installTask { return installTask }
        installOutcome = nil
        installStages = Dictionary(uniqueKeysWithValues: InstallPipelineStage.allCases.map { ($0, .pending) })
        installStages[.validateApplication] = .running
        let task = Task {
            defer { installTask = nil }
            await performInstall(setup: setup)
        }
        installTask = task
        return task
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
    case invalidApplicationLocation(String)
    case helperValidationFailed(String)
    case serviceRequiresApproval
    case serviceRegistrationFailed(String)
    case awaitPingTimedOut
}
