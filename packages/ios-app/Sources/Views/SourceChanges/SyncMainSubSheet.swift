import SwiftUI

// MARK: - Pull Remote Sub-Sheet

/// Fetches all remote refs and fast-forwards local `main`. Read-only on the
/// session worktree — only touches the repo root's main branch under the
/// per-repo lock.
///
/// No target-branch selector: pulling is always scoped to the repo's default
/// branch (auto-detected server-side). The action lives in the trailing
/// toolbar slot; the leading `xmark` dismisses the sheet.
@available(iOS 26.0, *)
struct SyncMainSubSheet: View {
    let rpcClient: RPCClient
    let sessionId: String

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
                    icon: "arrow.down",
                    accent: accent,
                    isBusy: isSyncing,
                    isEnabled: !isSyncing,
                    accessibilityLabel: "Pull"
                ) { performSync() }
            },
            content: {
                GitHeroCard(
                    icon: "arrow.down.circle",
                    title: "Pull All Remote Changes",
                    description: "Fetches every branch from the remote and fast-forwards the repo's default branch. Your session worktree stays on its own branch — no files are touched.",
                    accent: accent
                )

                if let outcome {
                    outcomeBanner(outcome)
                }
            }
        )
        .tronErrorAlert(message: $errorMessage)
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
                    targetBranch: nil
                )
            } catch {
                errorMessage = "Sync failed: \(error.localizedDescription)"
            }
        }
    }
}
