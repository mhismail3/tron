import SwiftUI

// MARK: - Conflict Resolver Sub-Sheet

/// Handles the two-stage conflict-resolution flow:
/// 1. **Pending**: surface conflicts, ask the user to tap "Let Resolver Run".
/// 2. **Running**: spawn the conflict-resolver subagent and show live status
///    until it commits the resolution (or fails, triggering auto-abort).
@available(iOS 26.0, *)
struct ConflictResolverSubSheet: View {
    let rpcClient: RPCClient
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
        GitSubSheetContainer(title: "Conflict Resolver", accent: accent) {
            switch stage {
            case .pending: pendingContent
            case .running: runningContent
            case .failed: failedContent
            }
        }
        .tronErrorAlert(message: $errorMessage)
        .task { await loadConflicts() }
        // Server-side transitions (subagent commits, peer aborts, crash
        // recovery auto-abort) clear `conflictBanner`. Mirror that by
        // dismissing so the user isn't stuck on a stale sheet.
        .onChange(of: gitWorkflowState?.conflictBanner == nil) { _, isCleared in
            guard isCleared, stage == .running else { return }
            onCompleted?()
            dismiss()
        }
    }

    // MARK: - Pending Stage

    private var pendingContent: some View {
        VStack(spacing: 18) {
            GitHeroCard(
                icon: "exclamationmark.triangle",
                title: conflictTitle,
                description: "A merge is in progress and needs manual edits. Tap \"Let Resolver Run\" to spawn a subagent that will read each file, choose ours/theirs or hand-edit, and commit the resolution.",
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

            GitActionButton(
                title: isSpawning ? "Spawning Subagent…" : "Let Resolver Run",
                icon: "wand.and.stars",
                accent: accent,
                isBusy: isSpawning,
                isEnabled: !isSpawning && !conflicts.isEmpty
            ) { spawnSubagent() }

            Button {
                Task { await performAbort(kind: .manual) }
            } label: {
                HStack {
                    Image(systemName: "xmark.circle")
                    Text(isAborting ? "Aborting…" : "Abort Merge")
                        .font(TronTypography.sans(size: TronTypography.sizeBody, weight: .medium))
                }
                .foregroundStyle(.tronError)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color.tronError.opacity(0.10))
                }
            }
            .buttonStyle(.plain)
            .disabled(isAborting || isSpawning)
        }
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

    // MARK: - Running Stage

    private var runningContent: some View {
        VStack(spacing: 18) {
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

            Button {
                Task { await performAbort(kind: .cancel) }
            } label: {
                HStack {
                    Image(systemName: "stop.circle")
                    Text(isAborting ? "Canceling…" : "Cancel Resolution")
                        .font(TronTypography.sans(size: TronTypography.sizeBody, weight: .medium))
                }
                .foregroundStyle(.tronError)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color.tronError.opacity(0.10))
                }
            }
            .buttonStyle(.plain)
            .disabled(isAborting)
        }
    }

    // MARK: - Failed Stage

    private var failedContent: some View {
        VStack(spacing: 18) {
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

            Button {
                dismiss()
            } label: {
                Text("Close")
                    .font(TronTypography.sans(size: TronTypography.sizeBody, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(accent)
                    }
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - Actions

    private func loadConflicts() async {
        isLoading = true
        defer { isLoading = false }
        do {
            conflicts = try await rpcClient.worktree.listConflicts(sessionId: sessionId)
        } catch {
            errorMessage = "Failed to load conflicts: \(error.localizedDescription)"
        }
    }

    private func spawnSubagent() {
        Task {
            isSpawning = true
            defer { isSpawning = false }
            do {
                let result = try await rpcClient.worktree.resolveConflictsWithSubagent(sessionId: sessionId)
                if result.spawned, let subId = result.subagentSessionId {
                    subagentSessionId = subId
                    stage = .running
                    onSubagentSpawned?(subId)
                } else {
                    errorMessage = result.reason ?? "Subagent could not be spawned"
                }
            } catch {
                errorMessage = "Spawn failed: \(error.localizedDescription)"
            }
        }
    }

    private enum AbortKind { case manual, cancel }

    private func performAbort(kind: AbortKind) async {
        isAborting = true
        defer { isAborting = false }
        do {
            _ = try await rpcClient.worktree.abortMerge(sessionId: sessionId)
            abortedMessage = (kind == .cancel)
                ? "Subagent canceled. Worktree restored to pre-merge state."
                : "Merge aborted. Worktree restored to pre-merge state."
            stage = .failed
            onCompleted?()
        } catch {
            errorMessage = "Abort failed: \(error.localizedDescription)"
        }
    }
}
