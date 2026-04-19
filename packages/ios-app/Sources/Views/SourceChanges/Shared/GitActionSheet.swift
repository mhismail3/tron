import SwiftUI

/// Centralizes the timing constants the git sub-sheets share. Currently
/// holds only the auto-dismiss delay; lives next to `GitActionRunner`
/// so both can be tweaked together.
enum GitSheetTimings {
    /// Delay between a clean success and `dismiss()` so the user has a
    /// moment to register the green banner. Calibrated by feel — long
    /// enough to read, short enough not to feel sticky.
    static let autoDismissDelay: Duration = .milliseconds(700)
}

/// Marker protocol that a git RPC's result type conforms to. The single
/// `isCleanSuccess` property tells `GitActionRunner` whether to schedule
/// the auto-dismiss or to leave the sheet open so the user can read a
/// banner (dry-run preview, "nothing to commit", conflicts, …).
///
/// Anything that's NOT a clean success keeps the sheet open. The user
/// can dismiss manually when ready.
protocol GitActionResult {
    /// True when the result represents a "clean success" the user
    /// already understands and doesn't need to read further banners
    /// about. False for dry-runs, no-ops, conflicts, blocked outcomes,
    /// or any other state that surfaces information worth reading.
    var isCleanSuccess: Bool { get }
}

/// Centralized state machine for the 5 git sub-sheets (Commit, Push,
/// Pull, Rebase, Merge). Replaces the per-sheet quartet of
/// `isRunning` / `result` / `errorMessage` / `isDismissingAfterSuccess`
/// state vars + the duplicated 700ms auto-dismiss block.
///
/// Usage from a sub-sheet:
/// ```swift
/// @State private var runner = GitActionRunner<WorktreeCommitResult>()
/// @Environment(\.dismiss) private var dismiss
///
/// SheetPrimaryActionButton(... isEnabled: runner.isEnabled) {
///     Task {
///         await runner.run(action: .commit, dismiss: { dismiss() }) {
///             try await rpcClient.worktree.commit(...)
///         }
///     }
/// }
/// .tronErrorAlert(message: $runner.errorMessage)
/// ```
@MainActor
@Observable
final class GitActionRunner<R: GitActionResult> {

    /// Action in flight.
    var isRunning: Bool = false

    /// Last result (cleared at the start of every `run()` call). Sheets
    /// render their result banner from this.
    var result: R? = nil

    /// User-facing error message. Sub-sheets bind this to
    /// `tronErrorAlert(message:)`.
    var errorMessage: String? = nil

    /// True between a clean success and the auto-dismiss firing. Gates
    /// the primary action so a double-tap during the 700ms window can't
    /// fire the action a second time.
    var isDismissingAfterSuccess: Bool = false

    /// Convenience for the trailing primary-action button's `isEnabled`.
    /// False when work is in flight, when a result is already on screen
    /// (caller can clear `result` to retry), or when the auto-dismiss is
    /// scheduled.
    var isEnabled: Bool {
        !isRunning && result == nil && !isDismissingAfterSuccess
    }

    /// Run a git RPC, capturing its result and routing failures through
    /// `friendlyGitError`. On a `isCleanSuccess` result, schedules a
    /// `GitSheetTimings.autoDismissDelay` and then calls `dismiss`.
    ///
    /// Re-entrant calls (concurrent `run` invocations) are dropped — the
    /// `isRunning` guard prevents double-fires from a rapid double-tap.
    /// `dismiss` is a plain closure (not `DismissAction`) so tests can
    /// inject a counter without hosting a SwiftUI view hierarchy.
    func run(
        action: GitActionVerb,
        dismiss: @escaping () -> Void,
        perform: () async throws -> R
    ) async {
        guard !isRunning else { return }
        isRunning = true
        defer { isRunning = false }
        result = nil
        do {
            let r = try await perform()
            result = r
            if r.isCleanSuccess {
                isDismissingAfterSuccess = true
                try? await Task.sleep(for: GitSheetTimings.autoDismissDelay)
                dismiss()
            }
        } catch {
            errorMessage = friendlyGitError(error, action: action)
        }
    }
}

// MARK: - GitActionResult conformances

extension WorktreeCommitResult: GitActionResult {
    /// A real commit (`commitHash` set) is a clean success. A "nothing
    /// to commit" no-op (`commitHash == nil`) keeps the sheet open so
    /// the user reads the warning banner.
    var isCleanSuccess: Bool { commitHash != nil }
}

extension GitPushResult: GitActionResult {
    /// Real pushes auto-dismiss; dry-runs stay open so the user can
    /// review the preview and toggle off dry-run before pushing again.
    var isCleanSuccess: Bool { !dryRun }
}

extension GitSyncOutcome: GitActionResult {
    /// `upToDate` and `fastForwarded` are clean. Dry-run previews and
    /// blocked outcomes stay open — both carry information the user
    /// needs to read.
    var isCleanSuccess: Bool {
        switch self {
        case .upToDate, .fastForwarded: true
        case .dryRunPreview, .blocked: false
        }
    }
}

extension WorktreeRebaseOnMainResult: GitActionResult {
    /// Only `.success` auto-dismisses. `.conflicts` needs an explicit
    /// resolver tap; `.noOp` carries info (ahead count) worth reading.
    var isCleanSuccess: Bool {
        switch self {
        case .success: true
        case .conflicts, .noOp: false
        }
    }
}

extension WorktreeFinalizeSessionResult: GitActionResult {
    /// Clean merge auto-dismisses; conflicts stay visible so the user
    /// can tap "Open Conflict Resolver".
    var isCleanSuccess: Bool { conflicts != true }
}
