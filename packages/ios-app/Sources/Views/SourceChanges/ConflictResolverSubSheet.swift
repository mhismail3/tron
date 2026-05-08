import SwiftUI

// MARK: - Conflict Resolver Sub-Sheet

/// Handles the two-stage conflict-resolution flow:
/// 1. **Pending**: surface conflicts, ask the user to tap "Let Resolver Run".
/// 2. **Running**: spawn the conflict-resolver subagent and show live status
///    until it commits the resolution (or fails, triggering auto-abort).
///
/// Primary action lives in the trailing toolbar slot (changes per stage);
/// leading `xmark` dismisses. Abort in the pending stage is surfaced as a
/// compact secondary link inline with the content — it's destructive but
/// infrequent, so doesn't earn the toolbar slot.
@available(iOS 26.0, *)
struct ConflictResolverSubSheet: View {
    let engineClient: EngineClient
    let sessionId: String
    /// Shared git workflow state — observed for `conflictBanner` clearing
    /// (fires on `worktree.merge_continued` / `merge_aborted`) so the sheet
    /// auto-dismisses once the subagent commits or the merge is aborted
    /// server-side by another client.
    var gitWorkflowState: GitWorkflowState?
    var onSubagentSpawned: ((String) -> Void)?
    var onCompleted: (() -> Void)?

    @Environment(\.dismiss) private var dismiss
    @State private var conflicts: [ConflictedFile] = []
    @State private var isLoading = false
    @State private var stage: Stage = .pending
    @State private var subagentSessionId: String?
    @State private var isSpawning = false
    @State private var isAborting = false
    @State private var errorMessage: String?
    @State private var abortedMessage: String?

    private let accent: Color = .tronRose

    enum Stage: Equatable {
        case pending
        case running
        case failed
    }

    var body: some View {
        GitSubSheetContainer(
            title: "Conflict Resolver",
            accent: accent,
            trailing: { trailingAction },
            content: {
                switch stage {
                case .pending: pendingContent
                case .running: runningContent
                case .failed: failedContent
                }
            }
        )
        .tronErrorAlert(message: $errorMessage)
        .task { await loadConflicts() }
        // Server-side transitions (subagent commits, peer aborts, crash
        // recovery auto-abort) clear `conflictBanner`. Mirror that by
        // dismissing so the user isn't stuck on a stale sheet — regardless
        // of which stage we're in, as long as it wasn't a local abort
        // (local abort transitions to `.failed` and surfaces the outcome
        // message in-sheet before the user dismisses).
        .onChange(of: gitWorkflowState?.conflictBanner == nil) { _, isCleared in
            guard isCleared, stage != .failed else { return }
            onCompleted?()
            dismiss()
        }
    }

    // MARK: - Toolbar Trailing

    @ViewBuilder
    private var trailingAction: some View {
        switch stage {
        case .pending:
            SheetPrimaryActionButton(
                icon: "wand.and.stars",
                accent: accent,
                isBusy: isSpawning,
                isEnabled: !isSpawning && !conflicts.isEmpty,
                accessibilityLabel: "Let Resolver Run"
            ) { spawnSubagent() }
        case .running:
            SheetPrimaryActionButton(
                icon: "stop.circle",
                accent: .tronError,
                isBusy: isAborting,
                isEnabled: !isAborting,
                accessibilityLabel: "Cancel Resolution"
            ) { Task { await performAbort(kind: .cancel) } }
        case .failed:
            EmptyView()
        }
    }

    // MARK: - Pending Stage

    private var pendingContent: some View {
        Group {
            GitHeroCard(
                icon: "exclamationmark.triangle",
                title: conflictTitle,
                description: heroDescription,
                accent: accent
            )

            if isLoading {
                ProgressView()
                    .tint(accent)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 20)
            } else if !conflicts.isEmpty {
                conflictsCard
            }

            abortInlineLink
        }
    }

    /// Hero copy adapts to the conflict origin so the user understands
    /// exactly what's in progress. Falls back to finalize-style copy when
    /// `gitWorkflowState` is absent (defensive; in practice it's always
    /// provided).
    private var heroDescription: String {
        let origin = gitWorkflowState?.conflictBanner?.origin ?? .finalize
        return origin.resolverDescription
    }

    private var conflictTitle: String {
        let n = conflicts.count
        return "\(n) conflict\(n == 1 ? "" : "s") pending"
    }

    private var conflictsCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsSectionHeader(title: "Conflicted Files")
            SettingsCard(accent: accent) {
                VStack(spacing: 0) {
                    ForEach(Array(conflicts.enumerated()), id: \.element.path) { index, conflict in
                        conflictRow(conflict)
                        if index < conflicts.count - 1 {
                            SettingsRowDivider()
                        }
                    }
                }
            }
        }
    }

    private func conflictRow(_ conflict: ConflictedFile) -> some View {
        HStack(spacing: 10) {
            Image(systemName: conflict.isBinary ? "doc.badge.gearshape" : "doc.text")
                .font(TronTypography.sans(size: TronTypography.sizeBody))
                .foregroundStyle(accent)
                .frame(width: 18)

            VStack(alignment: .leading, spacing: 2) {
                Text(conflict.path)
                    .font(TronTypography.sans(size: TronTypography.sizeBody3, weight: .medium))
                    .foregroundStyle(.tronTextPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                HStack(spacing: 6) {
                    if conflict.isBinary {
                        tag("binary", tint: .tronAmber)
                    }
                    tag(conflict.kind, tint: .tronPurple)
                }
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    private func tag(_ text: String, tint: Color) -> some View {
        Text(text)
            .font(TronTypography.codeCaption)
            .foregroundStyle(tint)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(tint.opacity(0.12)))
    }

    /// Secondary destructive action — rare enough that it doesn't warrant
    /// the toolbar slot, but surfaced prominently so the user has a clear
    /// escape hatch out of the merge.
    private var abortInlineLink: some View {
        Button {
            Task { await performAbort(kind: .manual) }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "xmark.circle")
                Text(isAborting ? "Aborting…" : "Abort Merge")
                    .font(TronTypography.sans(size: TronTypography.sizeCaption, weight: .medium))
            }
            .foregroundStyle(.tronError)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Capsule().fill(Color.tronError.opacity(0.10)))
        }
        .buttonStyle(.plain)
        .disabled(isAborting || isSpawning)
        .frame(maxWidth: .infinity, alignment: .center)
    }

    // MARK: - Running Stage

    private var runningContent: some View {
        Group {
            GitHeroCard(
                icon: "wand.and.stars",
                title: "Resolver Running",
                description: "A subagent is working on the conflicts. It will read each file, produce a resolution, and commit when done. You can follow its progress in the Subagents tab.",
                accent: accent
            )

            if let subagentId = subagentSessionId {
                VStack(alignment: .leading, spacing: 0) {
                    SettingsSectionHeader(title: "Subagent Session")
                    SettingsCard(accent: accent) {
                        HStack(spacing: 10) {
                            ProgressView().tint(accent).scaleEffect(0.8)
                            Text(String(subagentId.prefix(8)))
                                .font(TronTypography.sans(size: TronTypography.sizeBody3, weight: .medium))
                                .foregroundStyle(.tronTextPrimary)
                            Spacer()
                            Text("running")
                                .font(TronTypography.codeCaption)
                                .foregroundStyle(accent)
                        }
                        .padding(12)
                    }
                }
            }
        }
    }

    // MARK: - Failed Stage

    private var failedContent: some View {
        Group {
            GitHeroCard(
                icon: "xmark.octagon",
                title: "Resolution Aborted",
                description: abortedMessage ?? "The merge has been aborted. The worktree is back to its pre-merge state.",
                accent: accent
            )

            GitResultBanner(
                kind: .failure,
                title: "Merge aborted",
                detail: abortedMessage ?? "Any stashed work was preserved."
            )
        }
    }

    // MARK: - Actions

    private func loadConflicts() async {
        isLoading = true
        defer { isLoading = false }
        do {
            conflicts = try await engineClient.worktree.listConflicts(sessionId: sessionId)
        } catch {
            errorMessage = friendlyGitError(error, action: .load)
        }
    }

    private func spawnSubagent() {
        Task {
            isSpawning = true
            defer { isSpawning = false }
            do {
                let result = try await engineClient.worktree.resolveConflictsWithSubagent(
                    sessionId: sessionId,
                    idempotencyKey: .userAction("worktree.resolveConflictsWithSubagent")
                )
                if result.spawned, let subId = result.subagentSessionId {
                    subagentSessionId = subId
                    stage = .running
                    onSubagentSpawned?(subId)
                } else {
                    errorMessage = result.reason ?? "Subagent could not be spawned"
                }
            } catch {
                errorMessage = friendlyGitError(error, action: .spawn)
            }
        }
    }

    private enum AbortKind { case manual, cancel }

    private func performAbort(kind: AbortKind) async {
        isAborting = true
        defer { isAborting = false }
        do {
            _ = try await engineClient.worktree.abortMerge(sessionId: sessionId, idempotencyKey: .userAction("worktree.abortMerge"))
            abortedMessage = (kind == .cancel)
                ? "Subagent canceled. Worktree restored to pre-merge state."
                : "Merge aborted. Worktree restored to pre-merge state."
            stage = .failed
            onCompleted?()
        } catch {
            errorMessage = friendlyGitError(error, action: .abort)
        }
    }
}
