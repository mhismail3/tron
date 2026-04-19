import SwiftUI

// MARK: - Commit Sub-Sheet

/// Full-featured commit UI with message editor, stage-all / amend / sign-off
/// toggles, and a live summary of what will land in the commit. Replaces the
/// old toolbar `checkmark.circle` + confirmation popover flow, which hard-
/// coded the commit message and hid all flags.
///
/// Structure mirrors `PushSubSheet`:
///   GitSubSheetContainer → GitHeroCard → Summary card → Message card →
///   toggle cards → GitResultBanner.
///
/// The primary action lives in the trailing toolbar slot. On a real commit
/// (hash assigned) the sheet auto-dismisses after a brief banner flash so
/// the user can confirm the action landed; on "nothing to commit" it stays
/// open because the warning banner is the actionable signal. Parent
/// `SourceControlSheet` reloads its data on dismiss.
@available(iOS 26.0, *)
struct CommitSubSheet: View {
    let rpcClient: RPCClient
    let sessionId: String
    let diffResult: WorktreeGetDiffResult?
    let worktreeStatus: WorktreeGetStatusResult?
    let stagedFiles: [DiffFileEntry]

    @State private var commitMessage: String = ""
    @State private var stageAll: Bool = true
    @State private var amendPrevious: Bool = false
    @State private var signOff: Bool = false
    @State private var runner = GitActionRunner<WorktreeCommitResult>()
    @FocusState private var messageFocused: Bool
    @Environment(\.dismiss) private var dismiss

    private let accent: Color = .tronTeal

    // MARK: - Derived state

    private var trimmedMessage: String {
        commitMessage.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var hasWorktree: Bool {
        worktreeStatus?.hasWorktree == true
    }

    private var hasChanges: Bool {
        worktreeStatus?.worktree?.hasUncommittedChanges == true
    }

    private var stagedAdditions: Int {
        stagedFiles.reduce(0) { $0 + $1.additions }
    }

    private var stagedDeletions: Int {
        stagedFiles.reduce(0) { $0 + $1.deletions }
    }

    private var totalAdditions: Int {
        (diffResult?.files ?? []).reduce(0) { $0 + $1.additions }
    }

    private var totalDeletions: Int {
        (diffResult?.files ?? []).reduce(0) { $0 + $1.deletions }
    }

    /// Number of unique files that will land in the commit under the current
    /// toggle state. When `stageAll` is on, every tracked + untracked change
    /// counts once (partially-staged files collapse back to a single entry).
    /// When off, only already-staged files commit.
    ///
    /// Note: `diffResult.files` can contain two entries for a partially-staged
    /// file (one "staged", one "unstaged"). `summary.totalFiles` is the
    /// server-authoritative unique count; fall back to a client-side unique
    /// by path when the summary is missing.
    private var effectiveFileCount: Int {
        if stageAll {
            if let total = diffResult?.summary?.totalFiles { return total }
            let unique = Set((diffResult?.files ?? []).map(\.path))
            return unique.count
        }
        return stagedFiles.count
    }

    /// Count of files that stage-all would pull in beyond the current index.
    /// Counted as unique paths with any unstaged component (which includes
    /// untracked files, since the server emits them with `stagingArea: "unstaged"`).
    private var extrasCoveredByStageAll: Int {
        let stagedPaths = Set(stagedFiles.map(\.path))
        let allPaths = Set((diffResult?.files ?? []).map(\.path))
        return allPaths.subtracting(stagedPaths).count
    }

    private var isActionable: Bool {
        guard runner.isEnabled else { return false }
        guard hasWorktree, !trimmedMessage.isEmpty else { return false }
        // Amend can succeed on a clean tree (rewrites HEAD).
        // Stage-all with no changes at all cannot.
        return hasChanges || amendPrevious
    }

    private var branchLabel: String {
        worktreeStatus?.worktree?.branch ?? "this branch"
    }

    // MARK: - Hero

    private var heroTitle: String {
        if !hasWorktree {
            return "No worktree"
        }
        if amendPrevious {
            return "Amend HEAD on \(branchLabel)"
        }
        return "Commit to \(branchLabel)"
    }

    private var heroDescription: String {
        if !hasWorktree {
            return "This session has no worktree — nothing to commit."
        }
        if amendPrevious {
            var s = "Rewrites the previous commit on \(branchLabel) in place."
            if signOff {
                s += " Adds a Signed-off-by trailer."
            }
            s += " Do not amend commits already pushed to a shared branch — it diverges history."
            return s
        }
        var base: String
        if stageAll {
            base = "Stages every tracked and untracked change (runs `git add -A`) and commits to \(branchLabel)."
        } else {
            base = "Commits only files you've already staged. Untracked and unstaged files are ignored."
        }
        if signOff {
            base += " Adds a Signed-off-by trailer."
        }
        return base
    }

    // MARK: - Body

    var body: some View {
        GitSubSheetContainer(
            title: "Commit",
            accent: accent,
            trailing: {
                SheetPrimaryActionButton(
                    icon: amendPrevious ? "pencil" : "checkmark",
                    accent: accent,
                    isBusy: runner.isRunning,
                    isEnabled: isActionable,
                    accessibilityLabel: amendPrevious ? "Amend Commit" : "Commit"
                ) { performCommit() }
            },
            content: {
                GitHeroCard(
                    icon: amendPrevious ? "arrow.triangle.2.circlepath" : "square.and.pencil",
                    title: heroTitle,
                    description: heroDescription,
                    accent: accent
                )

                summaryCard
                messageCard
                stageAllCard
                amendCard
                signOffCard

                if let result = runner.result {
                    resultBanner(result)
                }
            }
        )
        .tronErrorAlert(message: $runner.errorMessage)
        .scrollDismissesKeyboard(.interactively)
        .onAppear {
            // Focus the editor after the sheet slides up so the keyboard
            // doesn't race the presentation animation.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                messageFocused = true
            }
        }
    }

    // MARK: - Summary

    private var summaryCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsSectionHeader(title: "Summary")
            SettingsCard(accent: accent) {
                VStack(alignment: .leading, spacing: 8) {
                    if !hasWorktree {
                        Text("No worktree for this session")
                            .font(TronTypography.sans(size: TronTypography.sizeBody3))
                            .foregroundStyle(.tronTextMuted)
                    } else if !hasChanges && !amendPrevious {
                        Text("No uncommitted changes")
                            .font(TronTypography.sans(size: TronTypography.sizeBody3))
                            .foregroundStyle(.tronTextMuted)
                    } else {
                        primarySummaryLine
                        if stageAll && extrasCoveredByStageAll > 0 {
                            secondarySummaryLine
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .padding(.vertical, 12)
            }
        }
    }

    private var primarySummaryLine: some View {
        HStack(spacing: 8) {
            Text(fileCountLabel(effectiveFileCount))
                .font(TronTypography.sans(size: TronTypography.sizeBody3, weight: .medium))
                .foregroundStyle(.tronTextPrimary)
            Spacer(minLength: 0)
            statsPill(
                additions: stageAll ? totalAdditions : stagedAdditions,
                deletions: stageAll ? totalDeletions : stagedDeletions
            )
        }
    }

    @ViewBuilder
    private var secondarySummaryLine: some View {
        let extras = extrasCoveredByStageAll
        let s = extras == 1 ? "" : "s"
        Text("Stage all will include \(extras) additional file\(s) not yet staged.")
            .font(TronTypography.sans(size: TronTypography.sizeCaption))
            .foregroundStyle(.tronTextMuted)
    }

    private func statsPill(additions: Int, deletions: Int) -> some View {
        HStack(spacing: 6) {
            Text("+\(additions)")
                .font(TronTypography.code(size: TronTypography.sizeCaption, weight: .medium))
                .foregroundStyle(.tronEmerald)
            Text("-\(deletions)")
                .font(TronTypography.code(size: TronTypography.sizeCaption, weight: .medium))
                .foregroundStyle(.tronCoral)
        }
    }

    private func fileCountLabel(_ n: Int) -> String {
        n == 1 ? "1 file" : "\(n) files"
    }

    // MARK: - Message

    private var messageCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsSectionHeader(title: "Commit Message")
            SettingsCard(accent: accent) {
                ZStack(alignment: .topLeading) {
                    if commitMessage.isEmpty {
                        Text(messagePlaceholder)
                            .font(TronTypography.sans(size: TronTypography.sizeBody))
                            .foregroundStyle(.tronTextMuted.opacity(0.6))
                            .padding(.horizontal, 16)
                            .padding(.vertical, 14)
                            .allowsHitTesting(false)
                    }
                    TextEditor(text: $commitMessage)
                        .focused($messageFocused)
                        .font(TronTypography.sans(size: TronTypography.sizeBody))
                        .foregroundStyle(.tronTextPrimary)
                        .textInputAutocapitalization(.sentences)
                        .autocorrectionDisabled(false)
                        .scrollContentBackground(.hidden)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .frame(minHeight: 96, maxHeight: 180)
                }
            }
            SettingsCaption(text: "Newlines are allowed. First line is treated as the subject; a blank line separates subject from body.")
        }
    }

    private var messagePlaceholder: String {
        if let first = stagedFiles.first?.fileName {
            let more = max(0, stagedFiles.count - 1)
            if more == 0 {
                return "Update \(first)"
            }
            let s = more == 1 ? "" : "s"
            return "Update \(first) and \(more) more file\(s)"
        }
        return "Describe your change…"
    }

    // MARK: - Toggles

    private var stageAllCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsCard(accent: accent) {
                SettingsRow(icon: "tray.and.arrow.down", label: "Stage all", accentColor: accent) {
                    Toggle("", isOn: $stageAll)
                        .labelsHidden()
                        .tint(accent)
                        .disabled(amendPrevious && !hasChanges)
                }
            }
            SettingsCaption(text: "When on, runs `git add -A` so every tracked and untracked file is committed. When off, commits only files you've already staged.")
        }
    }

    private var amendCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsCard(accent: accent) {
                SettingsRow(icon: "arrow.triangle.2.circlepath", label: "Amend previous", accentColor: .tronAmber) {
                    Toggle("", isOn: $amendPrevious)
                        .labelsHidden()
                        .tint(.tronAmber)
                }
            }
            SettingsCaption(text: "Rewrites the previous HEAD commit in place. Do NOT amend commits already pushed to a shared branch — it diverges history.")
        }
    }

    private var signOffCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsCard(accent: accent) {
                SettingsRow(icon: "signature", label: "Sign off", accentColor: accent) {
                    Toggle("", isOn: $signOff)
                        .labelsHidden()
                        .tint(accent)
                }
            }
            SettingsCaption(text: "Appends a `Signed-off-by:` trailer required by some projects (DCO).")
        }
    }

    // MARK: - Result banner

    @ViewBuilder
    private func resultBanner(_ r: WorktreeCommitResult) -> some View {
        // Server-side failures throw typed RPC errors (rendered in the
        // alert via `friendlyGitError`). Reaching the banner path means
        // the commit ran — either as a real commit (`commitHash` set)
        // or as a no-op (`commitHash == nil`).
        if let hash = r.commitHash {
            let short = String(hash.prefix(7))
            let files = r.filesChanged?.count ?? 0
            let ins = r.insertions ?? 0
            let del = r.deletions ?? 0
            let detail: String? = {
                if files == 0 && ins == 0 && del == 0 { return nil }
                var parts: [String] = []
                if files > 0 {
                    parts.append(files == 1 ? "1 file" : "\(files) files")
                }
                if ins > 0 || del > 0 {
                    parts.append("+\(ins) -\(del)")
                }
                return parts.joined(separator: " · ")
            }()
            GitResultBanner(
                kind: .success,
                title: amendPrevious ? "Amended \(short)" : "Committed \(short)",
                detail: detail
            )
        } else {
            GitResultBanner(
                kind: .warning,
                title: "Nothing to commit",
                detail: "The working tree had no changes."
            )
        }
    }

    // MARK: - Actions

    private func performCommit() {
        guard isActionable else { return }
        // Auto-dismiss kicks in only when `commitHash != nil` —
        // WorktreeCommitResult.isCleanSuccess captures that contract.
        // "Nothing to commit" stays on screen because the warning banner
        // IS the feedback the user needs.
        Task {
            await runner.run(action: .commit, dismiss: { dismiss() }) {
                try await rpcClient.worktree.commit(
                    sessionId: sessionId,
                    message: trimmedMessage,
                    amend: amendPrevious ? true : nil,
                    signoff: signOff ? true : nil,
                    stageAll: stageAll ? nil : false
                )
            }
        }
    }
}
