import SwiftUI

// MARK: - Merge Changes Sub-Sheet

/// Merges the session branch into the configured target branch. Defaults to
/// the repo's base branch (typically `main`); the remote-branch picker is
/// still available for edge cases where a session needs to merge into a
/// non-default integration branch. By default also rebranches the worktree
/// onto a fresh session branch so new work stays isolated; that follow-up can
/// be disabled via the "Auto-create new session branch" toggle, which leaves
/// the worktree on the original source branch.
///
/// On conflicts, the sub-sheet swaps its payload to the `ConflictResolverSubSheet`
/// flow, keeping the user in the same sheet for the full resolution cycle.
///
/// Primary action lives in the trailing toolbar slot; leading `xmark` dismisses.
@available(iOS 26.0, *)
struct MergeChangesSubSheet: View {
    let rpcClient: RPCClient
    let sessionId: String
    let suggestedTargetBranch: String?
    let defaultStrategy: String
    let defaultSessionBranchPolicy: String
    var onConflicts: ((WorktreeFinalizeSessionResult) -> Void)?

    @Environment(\.dismiss) private var dismiss
    @State private var targetBranch: String = ""
    @State private var strategy: MergeStrategy = .merge
    @State private var deleteOldBranch: Bool = false
    @State private var rebranch: Bool = true
    @State private var isFinalizing = false
    @State private var result: WorktreeFinalizeSessionResult?
    @State private var errorMessage: String?
    /// True between a successful clean merge and the auto-dismiss firing.
    /// Conflict outcomes don't flip this — the user needs to tap
    /// "Open Conflict Resolver" explicitly.
    @State private var isDismissingAfterSuccess: Bool = false

    private let accent: Color = .tronCoral

    enum MergeStrategy: String, CaseIterable, Identifiable {
        case merge, rebase, squash
        var id: String { rawValue }
        var label: String { rawValue.capitalized }
        var icon: String {
            switch self {
            case .merge: "arrow.triangle.merge"
            case .rebase: "arrow.triangle.2.circlepath"
            case .squash: "square.stack.3d.down.forward"
            }
        }
        var description: String {
            switch self {
            case .merge:
                "Creates a merge commit that joins the two histories. Preserves both branches' commits verbatim."
            case .rebase:
                "Replays the session's commits on top of the target branch. Keeps history linear with no merge commit."
            case .squash:
                "Combines every session commit into a single new commit on the target branch."
            }
        }
        // Short verb phrase used by the dynamic hero summary.
        var summaryVerb: String {
            switch self {
            case .merge: "Creates a merge commit joining this session's work"
            case .rebase: "Replays this session's commits"
            case .squash: "Squashes this session's work into a single commit"
            }
        }
    }

    var body: some View {
        GitSubSheetContainer(
            title: "Merge Changes",
            accent: accent,
            trailing: {
                SheetPrimaryActionButton(
                    icon: "checkmark.seal",
                    accent: accent,
                    isBusy: isFinalizing,
                    isEnabled: !isFinalizing && result == nil && !isDismissingAfterSuccess,
                    accessibilityLabel: "Merge"
                ) { performFinalize() }
            },
            content: {
                GitHeroCard(
                    icon: "checkmark.seal",
                    title: heroTitle,
                    description: heroDescription,
                    accent: accent
                )

                targetBranchCard
                strategyCard
                rebranchCard
                if rebranch {
                    deleteOldCard
                }

                if let result {
                    if result.conflicts == true {
                        GitResultBanner(
                            kind: .warning,
                            title: "Conflicts detected",
                            detail: result.error ?? "Launch the Conflict Resolver to continue."
                        )
                        Button {
                            dismiss()
                            onConflicts?(result)
                        } label: {
                            HStack {
                                Image(systemName: "wand.and.stars")
                                Text("Open Conflict Resolver")
                                    .font(TronTypography.sans(size: TronTypography.sizeBody, weight: .semibold))
                            }
                            .foregroundStyle(.tronRose)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                            .background {
                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .fill(Color.tronRose.opacity(0.12))
                            }
                        }
                        .buttonStyle(.plain)
                    } else {
                        finalizeSuccessBanner(result)
                    }
                }
            }
        )
        .tronErrorAlert(message: $errorMessage)
        .task {
            targetBranch = suggestedTargetBranch ?? "main"
            strategy = MergeStrategy(rawValue: defaultStrategy) ?? .merge
            deleteOldBranch = (defaultSessionBranchPolicy == "deleteOnFinalize")
        }
    }

    private var displayTarget: String {
        let t = targetBranch.trimmingCharacters(in: .whitespaces)
        return t.isEmpty ? (suggestedTargetBranch ?? "main") : t
    }

    // MARK: Dynamic Hero Summary

    /// Short, action-oriented title that reflects the picked target.
    private var heroTitle: String {
        "Merge to \(displayTarget)"
    }

    /// Real-time summary of exactly what this sheet will do given the current
    /// settings. Rebuilt on every render, so flipping a toggle immediately
    /// updates the copy.
    private var heroDescription: String {
        var sentence = "\(strategy.summaryVerb) into \(displayTarget)"
        if rebranch {
            sentence += ", then creates a fresh session branch so new changes stay isolated"
            if deleteOldBranch {
                sentence += " and deletes the old session branch"
            }
        } else {
            sentence += ". The worktree stays on the current session branch afterwards"
            return sentence + "."
        }
        return sentence + "."
    }

    // MARK: Cards

    private var targetBranchCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsSectionHeader(title: "Target Branch")
            SettingsCard(accent: accent) {
                BranchPickerField(
                    rpcClient: rpcClient,
                    sessionId: sessionId,
                    accent: accent,
                    placeholder: "main",
                    selection: $targetBranch,
                    source: .remote()
                )
            }
            SettingsCaption(text: "Defaults to main. Only branches published on origin are valid merge targets.")
        }
    }

    private var strategyCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsSectionHeader(title: "Merge Strategy")
            SettingsCard(accent: accent) {
                HStack(spacing: 0) {
                    ForEach(MergeStrategy.allCases) { s in
                        Button {
                            strategy = s
                        } label: {
                            VStack(spacing: 4) {
                                Image(systemName: s.icon)
                                    .font(TronTypography.sans(size: TronTypography.sizeBody3))
                                Text(s.label)
                                    .font(TronTypography.sans(size: TronTypography.sizeCaption, weight: .medium))
                            }
                            .foregroundStyle(strategy == s ? accent : .tronTextMuted)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                            .background {
                                if strategy == s {
                                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                                        .fill(accent.opacity(0.15))
                                        .padding(4)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 4)
            }
            SettingsCaption(text: strategy.description)
        }
    }

    private var rebranchCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsCard(accent: accent) {
                SettingsRow(icon: "arrow.triangle.branch", label: "Auto-create new session branch", accentColor: accent) {
                    Toggle("", isOn: $rebranch)
                        .labelsHidden()
                        .tint(accent)
                }
            }
            SettingsCaption(text: rebranch
                ? "After merging, creates a fresh session branch and moves the worktree onto it so new changes stay isolated."
                : "Skips the follow-up branch. Worktree stays on the current session branch after the merge completes.")
        }
    }

    private var deleteOldCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsCard(accent: accent) {
                SettingsRow(icon: "trash", label: "Delete old session branch", accentColor: .tronAmber) {
                    Toggle("", isOn: $deleteOldBranch)
                        .labelsHidden()
                        .tint(.tronAmber)
                }
            }
            SettingsCaption(text: "Removes the session branch after the merge succeeds. The commits stay in history via the merge commit.")
        }
    }

    @ViewBuilder
    private func finalizeSuccessBanner(_ r: WorktreeFinalizeSessionResult) -> some View {
        let detail = successDetail(r)
        GitResultBanner(
            kind: .success,
            title: "Merged into \(displayTarget)",
            detail: detail.isEmpty ? nil : detail
        )
        if rebranch, deleteOldBranch, r.oldBranchDeleted == false {
            GitResultBanner(
                kind: .warning,
                title: "Old branch not deleted",
                detail: r.oldBranchDeleteError ?? "Git refused to delete the old session branch."
            )
        }
    }

    private func successDetail(_ r: WorktreeFinalizeSessionResult) -> String {
        var detail = ""
        if let newBranch = r.newBranch {
            detail += rebranch ? "New session branch: \(newBranch)" : "Worktree stays on: \(newBranch)"
        }
        if let commit = r.mergeCommit {
            if !detail.isEmpty { detail += "\n" }
            detail += "Merge commit: \(String(commit.prefix(7)))"
        }
        return detail
    }

    // MARK: Actions

    private func performFinalize() {
        Task {
            isFinalizing = true
            defer { isFinalizing = false }
            result = nil
            do {
                let trimmed = targetBranch.trimmingCharacters(in: .whitespaces)
                let r = try await rpcClient.worktree.finalizeSession(
                    sessionId: sessionId,
                    targetBranch: trimmed.isEmpty ? nil : trimmed,
                    strategy: strategy.rawValue,
                    preserveOld: !deleteOldBranch,
                    rebranch: rebranch
                )
                result = r
                // Clean merge → auto-dismiss after the success banner flashes.
                // Conflicts stay visible: the user taps "Open Conflict
                // Resolver" which swaps the active sheet via `onConflicts`.
                if r.conflicts != true {
                    isDismissingAfterSuccess = true
                    try? await Task.sleep(for: .milliseconds(700))
                    dismiss()
                }
            } catch {
                errorMessage = friendlyGitError(error, action: "Merge")
            }
        }
    }
}
