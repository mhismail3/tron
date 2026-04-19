import SwiftUI

// MARK: - Rebase on Main Sub-Sheet

/// Pulls main's commits forward into the session branch — the reverse of
/// `MergeChangesSubSheet`. The session stays on its current branch;
/// main just lands on top.
///
/// On conflicts, dismisses and calls `onConflicts` so the parent can
/// route to `ConflictResolverSubSheet` (same pattern as finalize).
/// Primary action lives in the trailing toolbar slot; leading `xmark`
/// dismisses.
@available(iOS 26.0, *)
struct RebaseOnMainSubSheet: View {
    let rpcClient: RPCClient
    let sessionId: String
    let suggestedMainBranch: String?
    /// Divergence info for the "main behind origin" warning banner.
    let divergence: RepoDivergence?
    var onConflicts: (() -> Void)?

    @Environment(\.dismiss) private var dismiss
    @State private var strategy: Strategy = .rebase
    @State private var isRunning = false
    @State private var result: WorktreeRebaseOnMainResult?
    @State private var errorMessage: String?
    /// True between a successful rebase and the auto-dismiss firing.
    /// `.conflicts` and `.noOp` outcomes don't flip this — conflicts need
    /// an explicit resolver tap; no-op carries info (ahead count) that
    /// the user should read before leaving.
    @State private var isDismissingAfterSuccess: Bool = false

    private let accent: Color = .tronPurple

    /// Two strategies — `squash` is intentionally absent (server rejects).
    enum Strategy: String, CaseIterable, Identifiable, StrategyDisplayable {
        case rebase, merge
        var id: String { rawValue }
        var label: String { rawValue.capitalized }
        var icon: String {
            switch self {
            case .rebase: "arrow.triangle.2.circlepath"
            case .merge: "arrow.triangle.merge"
            }
        }
        var description: String {
            switch self {
            case .rebase:
                "Replays your session's commits on top of main. Linear history, but your session commits get new identifiers."
            case .merge:
                "Creates a merge commit on your session branch that joins main's history. Preserves existing commit SHAs."
            }
        }
        var summaryVerb: String {
            switch self {
            case .rebase: "Replays your session's commits on top of"
            case .merge: "Creates a merge commit joining"
            }
        }
    }

    var body: some View {
        GitSubSheetContainer(
            title: "Rebase on Main",
            accent: accent,
            trailing: {
                SheetPrimaryActionButton(
                    icon: "arrow.triangle.2.circlepath",
                    accent: accent,
                    isBusy: isRunning,
                    isEnabled: !isRunning && result == nil && !isDismissingAfterSuccess,
                    accessibilityLabel: "Rebase"
                ) { performRebase() }
            },
            content: {
                GitHeroCard(
                    icon: "arrow.triangle.2.circlepath",
                    title: heroTitle,
                    description: heroDescription,
                    accent: accent
                )

                strategyCard

                if strategy == .rebase {
                    rewriteWarningCard
                }

                if let divergence, (divergence.behindOrigin ?? 0) > 0 {
                    mainStaleWarningCard(behind: divergence.behindOrigin ?? 0)
                }

                if let result {
                    resultBanner(result)
                }
            }
        )
        .tronErrorAlert(message: $errorMessage)
    }

    private var displayMain: String {
        suggestedMainBranch ?? "main"
    }

    private var heroTitle: String {
        "Rebase on \(displayMain)"
    }

    private var heroDescription: String {
        "\(strategy.summaryVerb) \(displayMain). Keeps your session up to date without finalizing."
    }

    // MARK: Cards

    private var strategyCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsSectionHeader(title: "Strategy")
            SettingsCard(accent: accent) {
                StrategyPicker(selection: $strategy, accent: accent)
            }
            SettingsCaption(text: strategy.description)
        }
    }

    private var rewriteWarningCard: some View {
        GitResultBanner(
            kind: .warning,
            title: "Commit identifiers will change",
            detail: "Rebase rewrites your session's commit SHAs. Any references to those commits (e.g. in chat history) will be stale after this completes."
        )
    }

    private func mainStaleWarningCard(behind: UInt64) -> some View {
        GitResultBanner(
            kind: .warning,
            title: "Main is \(behind) commit\(behind == 1 ? "" : "s") behind origin",
            detail: "Pull first to include the latest remote changes before rebasing."
        )
    }

    // MARK: Result

    @ViewBuilder
    private func resultBanner(_ r: WorktreeRebaseOnMainResult) -> some View {
        switch r {
        case .success(let s):
            GitResultBanner(
                kind: .success,
                title: "Rebased on \(displayMain)",
                detail: successDetail(s)
            )
        case .conflicts(let c):
            GitResultBanner(
                kind: .warning,
                title: "Conflicts detected",
                detail: "\(c.count) file\(c.count == 1 ? "" : "s") need manual resolution. Open the conflict resolver to continue."
            )
            OpenConflictResolverButton {
                dismiss()
                onConflicts?()
            }
        case .noOp(let n):
            GitResultBanner(
                kind: .success,
                title: "Already up to date",
                detail: n.ahead > 0
                    ? "Your session is \(n.ahead) commit\(n.ahead == 1 ? "" : "s") ahead of \(displayMain)."
                    : "Nothing to rebase."
            )
        }
    }

    private func successDetail(_ s: WorktreeRebaseOnMainResult.RebaseSuccess) -> String {
        var lines: [String] = []
        lines.append(
            "\(s.mainCommitsIncorporated) commit\(s.mainCommitsIncorporated == 1 ? "" : "s") incorporated"
        )
        if s.hadAutoStash {
            lines.append("Uncommitted changes auto-stashed and restored")
        }
        return lines.joined(separator: "\n")
    }

    // MARK: Actions

    private func performRebase() {
        Task {
            isRunning = true
            defer { isRunning = false }
            result = nil
            do {
                let r = try await rpcClient.worktree.rebaseOnMain(
                    sessionId: sessionId,
                    strategy: strategy.rawValue
                )
                result = r
                // Only clean `.success` auto-dismisses. `.conflicts` gives
                // the user an explicit resolver CTA to tap; `.noOp` shows
                // "already up to date" info worth reading.
                if case .success = r {
                    isDismissingAfterSuccess = true
                    try? await Task.sleep(for: .milliseconds(700))
                    dismiss()
                }
            } catch {
                errorMessage = friendlyGitError(error, action: .rebase)
            }
        }
    }
}
