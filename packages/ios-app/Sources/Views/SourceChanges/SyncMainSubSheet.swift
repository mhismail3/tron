import SwiftUI

// MARK: - Pull Remote Sub-Sheet

/// Fetches all remote refs and fast-forwards local `main`. Read-only on the
/// session worktree — only touches the repo root's main branch under the
/// per-repo lock.
///
/// Two optional settings:
/// - **Prune stale remotes** (`fetch --prune`): deletes local
///   remote-tracking refs for branches removed upstream. Useful hygiene.
/// - **Dry run** (server runs the fetch but skips the FF): preview how far
///   ahead the remote is without moving local `main`.
///
/// No target-branch selector: pulling is always scoped to the repo's default
/// branch (auto-detected server-side). The action lives in the trailing
/// toolbar slot; the leading `xmark` dismisses the sheet.
@available(iOS 26.0, *)
struct SyncMainSubSheet: View {
    let rpcClient: RPCClient
    let sessionId: String

    @State private var prune: Bool = false
    @State private var dryRun: Bool = false
    @State private var isSyncing = false
    @State private var outcome: GitSyncOutcome?
    @State private var errorMessage: String?

    private let accent: Color = .tronEmerald

    var body: some View {
        GitSubSheetContainer(
            title: "Pull Remote",
            accent: accent,
            trailing: {
                SheetPrimaryActionButton(
                    icon: dryRun ? "eye" : "arrow.down",
                    accent: accent,
                    isBusy: isSyncing,
                    isEnabled: !isSyncing,
                    accessibilityLabel: dryRun ? "Dry Run Pull" : "Pull"
                ) { performSync() }
            },
            content: {
                GitHeroCard(
                    icon: "arrow.down.circle",
                    title: heroTitle,
                    description: heroDescription,
                    accent: accent
                )

                pruneCard
                dryRunCard

                if let outcome {
                    outcomeBanner(outcome)
                }
            }
        )
        .tronErrorAlert(message: $errorMessage)
    }

    // MARK: Dynamic Hero Summary

    private var heroTitle: String {
        dryRun ? "Dry-run pull" : "Pull all remote changes"
    }

    /// Real-time summary that reflects every toggle change.
    private var heroDescription: String {
        let action = dryRun
            ? "Fetches every branch from the remote and reports how far main would advance, without moving local main"
            : "Fetches every branch from the remote and fast-forwards the repo's default branch"

        let tail = dryRun
            ? ". Your session worktree stays on its own branch — no files are touched."
            : ". Your session worktree stays on its own branch — no files are touched."

        if prune {
            return action
                + ", and prunes local remote-tracking refs for branches deleted upstream"
                + tail
        }
        return action + tail
    }

    // MARK: Cards

    private var pruneCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsCard(accent: accent) {
                SettingsRow(icon: "scissors", label: "Prune stale remotes", accentColor: accent) {
                    Toggle("", isOn: $prune)
                        .labelsHidden()
                        .tint(accent)
                }
            }
            SettingsCaption(text: "Adds `--prune` to the fetch so local `origin/*` refs for branches deleted upstream get cleaned up.")
        }
    }

    private var dryRunCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsCard(accent: accent) {
                SettingsRow(icon: "eye", label: "Dry run", accentColor: accent) {
                    Toggle("", isOn: $dryRun)
                        .labelsHidden()
                        .tint(accent)
                }
            }
            SettingsCaption(text: "Runs the fetch (including prune if set) but skips the fast-forward. Reports how many commits main would advance.")
        }
    }

    // MARK: Outcome Banner

    @ViewBuilder
    private func outcomeBanner(_ o: GitSyncOutcome) -> some View {
        switch o {
        case .upToDate(let head):
            GitResultBanner(
                kind: .success,
                title: "Already up to date",
                detail: "HEAD at \(String(head.prefix(7)))"
            )
        case .fastForwarded(let oldHead, let newHead, let advancedBy):
            GitResultBanner(
                kind: .success,
                title: "Fast-forwarded \(advancedBy) commit\(advancedBy == 1 ? "" : "s")",
                detail: "\(String(oldHead.prefix(7))) → \(String(newHead.prefix(7)))"
            )
        case .dryRunPreview(let head, let remoteHead, let wouldAdvanceBy):
            GitResultBanner(
                kind: wouldAdvanceBy == 0 ? .success : .warning,
                title: wouldAdvanceBy == 0
                    ? "Dry run: already up to date"
                    : "Dry run: would advance \(wouldAdvanceBy) commit\(wouldAdvanceBy == 1 ? "" : "s")",
                detail: wouldAdvanceBy == 0
                    ? "HEAD at \(String(head.prefix(7)))"
                    : "\(String(head.prefix(7))) → \(String(remoteHead.prefix(7))). Local main was not moved."
            )
        case .blocked(let reason):
            GitResultBanner(
                kind: .warning,
                title: "Sync blocked",
                detail: blockedDetail(reason)
            )
        }
    }

    private func blockedDetail(_ reason: GitSyncBlockReason) -> String {
        switch reason {
        case .noRemote: "No remote configured. Add an origin to enable sync."
        case .dirtyWorkingTree: "The repo root has uncommitted changes. Commit or stash them first."
        case .localAhead: "Local main has commits the remote doesn't. Push or rebase manually."
        case .diverged: "Local and remote main have diverged. Resolve manually before syncing."
        case .emptyRepository: "Repository has no commits yet."
        case .detachedHead: "Repository is in a detached-HEAD state."
        case .noDefaultBranch: "Could not determine the default branch (tried main, master)."
        case .notOnDefaultBranch(let current, let expected):
            "HEAD is on \(current); switch to \(expected) before syncing."
        case .remoteError: "Remote operation failed. Check auth and connectivity."
        case .unknown: "Sync could not complete."
        }
    }

    // MARK: Actions

    private func performSync() {
        Task {
            isSyncing = true
            defer { isSyncing = false }
            outcome = nil
            do {
                // No targetBranch — server auto-detects the repo's default.
                outcome = try await rpcClient.git.syncMain(
                    sessionId: sessionId,
                    targetBranch: nil,
                    prune: prune ? true : nil,
                    dryRun: dryRun ? true : nil
                )
            } catch {
                errorMessage = "Sync failed: \(error.localizedDescription)"
            }
        }
    }
}
