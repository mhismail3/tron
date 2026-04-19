import SwiftUI

// MARK: - Parallel Sessions Sub-Sheet

/// Lists every session branch in this repo, grouped as:
///   1. **This Session** — branch name + icon only, non-interactive.
///   2. **Active Sessions** — other live sessions in this repo. Tap to jump.
///   3. **Ended Sessions** — preserved branches from finalized/ended sessions.
///      Non-interactive; cleared as a group via the trailing Prune All toolbar
///      action (only surfaced when ended branches exist).
///
/// Refreshes live from `repo.*` and `worktree.*` events by observing
/// `gitWorkflowState.divergenceRefreshTick`.
@available(iOS 26.0, *)
struct RepoSessionsSubSheet: View {
    let rpcClient: RPCClient
    let sessionId: String
    var gitWorkflowState: GitWorkflowState?
    var onSelectSession: ((String) -> Void)?

    @State private var activeSessions: [RepoSessionSummary] = []
    @State private var endedBranches: [SessionBranchInfo] = []
    @State private var isLoading = false
    @State private var isPruning = false
    @State private var showPruneConfirmation = false
    @State private var errorMessage: String?

    private let accent: Color = .tronAmber

    private var otherActiveSessions: [RepoSessionSummary] {
        activeSessions.filter { $0.sessionId != sessionId }
    }

    private var currentSession: RepoSessionSummary? {
        activeSessions.first { $0.sessionId == sessionId }
    }

    /// True when every section has no rows to render — drives the empty state.
    private var hasNoSessions: Bool {
        currentSession == nil && otherActiveSessions.isEmpty && endedBranches.isEmpty
    }

    var body: some View {
        // Parallel Sessions has no primary "commit" action — it's a listing
        // sheet. We swap the usual chrome: the destructive Prune All button
        // lives on the leading edge (labeled for clarity since destructive
        // actions warrant text, not just a glyph), and the trailing edge
        // gets a checkmark dismiss so the user can close with a single tap
        // near their thumb.
        GitSubSheetContainer(
            title: "Parallel Sessions",
            accent: accent,
            leading: {
                if !endedBranches.isEmpty {
                    pruneToolbarButton
                } else {
                    EmptyView()
                }
            },
            trailing: {
                SheetDismissButton(color: accent)
            },
            content: {
                GitHeroCard(
                    icon: "rectangle.stack.person.crop",
                    title: "Sessions in this Repo",
                    description: "Every session has its own worktree and branch. Main mutations (sync, finalize) are serialized; all other ops run in parallel.",
                    accent: accent
                )

                if isLoading && activeSessions.isEmpty && endedBranches.isEmpty {
                    loadingState
                } else {
                    thisSessionSection
                    otherActiveSection
                    endedSection
                    if hasNoSessions {
                        emptyState
                    }
                }
            }
        )
        .tronErrorAlert(message: $errorMessage)
        .task { await loadAll() }
        .onChange(of: gitWorkflowState?.divergenceRefreshTick ?? 0) { _, _ in
            Task { await loadAll() }
        }
    }

    // MARK: Sections

    @ViewBuilder
    private var thisSessionSection: some View {
        if let current = currentSession {
            VStack(alignment: .leading, spacing: 0) {
                SettingsSectionHeader(title: "This Session")
                SettingsCard(accent: .tronEmerald) {
                    HStack(spacing: 10) {
                        Image(systemName: "dot.circle.fill")
                            .font(TronTypography.sans(size: TronTypography.sizeBody))
                            .foregroundStyle(.tronEmerald)
                            .frame(width: 18)
                        Text(current.branch)
                            .font(TronTypography.sans(size: TronTypography.sizeBody3, weight: .semibold))
                            .foregroundStyle(.tronTextPrimary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 12)
                }
            }
        }
    }

    @ViewBuilder
    private var otherActiveSection: some View {
        if !otherActiveSessions.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                SettingsSectionHeader(title: "Active Sessions")
                SettingsCard(accent: accent) {
                    VStack(spacing: 0) {
                        ForEach(Array(otherActiveSessions.enumerated()), id: \.element.sessionId) { index, session in
                            activeSessionRow(session)
                            if index < otherActiveSessions.count - 1 {
                                SettingsRowDivider()
                            }
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var endedSection: some View {
        if !endedBranches.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                SettingsSectionHeader(title: "Ended Sessions")
                SettingsCard(accent: .tronTextMuted) {
                    VStack(spacing: 0) {
                        ForEach(Array(endedBranches.enumerated()), id: \.element.branch) { index, branch in
                            endedBranchRow(branch)
                            if index < endedBranches.count - 1 {
                                SettingsRowDivider()
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: Rows

    private func activeSessionRow(_ session: RepoSessionSummary) -> some View {
        Button {
            onSelectSession?(session.sessionId)
        } label: {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "arrow.triangle.branch")
                    .font(TronTypography.sans(size: TronTypography.sizeBody))
                    .foregroundStyle(accent)
                    .frame(width: 18)
                    .padding(.top, 1)

                VStack(alignment: .leading, spacing: 4) {
                    Text(session.branch)
                        .font(TronTypography.sans(size: TronTypography.sizeBody3, weight: .semibold))
                        .foregroundStyle(.tronTextPrimary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    HStack(spacing: 6) {
                        countChip("\(session.commitCount)", label: "commit\(session.commitCount == 1 ? "" : "s")", tint: .tronSky)
                        if session.baseBehind > 0 {
                            countChip("↓\(session.baseBehind)", label: "behind \(session.baseBranch ?? "base")", tint: .tronAmber)
                        }
                        if session.hasConflicts {
                            conflictChip
                        }
                    }
                }

                Spacer(minLength: 0)

                Image(systemName: "chevron.right")
                    .font(TronTypography.sans(size: TronTypography.sizeCaption, weight: .medium))
                    .foregroundStyle(.tronTextMuted)
                    .padding(.top, 3)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func endedBranchRow(_ branch: SessionBranchInfo) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "archivebox")
                .font(TronTypography.sans(size: TronTypography.sizeBody))
                .foregroundStyle(.tronTextMuted)
                .frame(width: 18)
                .padding(.top, 1)

            VStack(alignment: .leading, spacing: 4) {
                Text(branch.branch)
                    .font(TronTypography.sans(size: TronTypography.sizeBody3, weight: .medium))
                    .foregroundStyle(.tronTextPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if branch.commitCount > 0 || !branch.lastCommitMessage.isEmpty {
                    HStack(spacing: 6) {
                        if branch.commitCount > 0 {
                            countChip("\(branch.commitCount)", label: "commit\(branch.commitCount == 1 ? "" : "s")", tint: .tronTextMuted)
                        }
                        if !branch.lastCommitMessage.isEmpty {
                            Text(branch.lastCommitMessage)
                                .font(TronTypography.sans(size: TronTypography.sizeCaption))
                                .foregroundStyle(.tronTextMuted)
                                .lineLimit(1)
                                .truncationMode(.tail)
                        }
                    }
                }
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 12)
    }

    // MARK: Chips

    private func countChip(_ count: String, label: String, tint: Color) -> some View {
        HStack(spacing: 3) {
            Text(count)
                .font(TronTypography.sans(size: TronTypography.sizeCaption, weight: .semibold))
            Text(label)
                .font(TronTypography.codeCaption)
                .foregroundStyle(.tronTextMuted)
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(Capsule().fill(tint.opacity(0.12)))
    }

    private var conflictChip: some View {
        HStack(spacing: 3) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 9, weight: .semibold))
            Text("conflicts")
                .font(TronTypography.sans(size: TronTypography.sizeCaption, weight: .semibold))
        }
        .foregroundStyle(.tronError)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(Capsule().fill(Color.tronError.opacity(0.12)))
    }

    // MARK: Prune

    @ViewBuilder
    private var pruneToolbarButton: some View {
        Button {
            showPruneConfirmation = true
        } label: {
            HStack(spacing: 4) {
                if isPruning {
                    ProgressView()
                        .scaleEffect(0.7)
                        .tint(.tronError)
                } else {
                    Image(systemName: "trash")
                        .font(TronTypography.buttonSM)
                }
                Text(isPruning ? "Pruning…" : "Prune")
                    .font(TronTypography.sans(size: TronTypography.sizeBody3, weight: .medium))
            }
            .foregroundStyle(.tronError)
        }
        .disabled(isPruning)
        .accessibilityLabel("Prune All Ended Branches")
        .popover(isPresented: $showPruneConfirmation, arrowEdge: .top) {
            GlassActionSheet(
                actions: [
                    GlassAction(
                        title: "Delete \(endedBranches.count) branch\(endedBranches.count == 1 ? "" : "es")",
                        icon: "trash",
                        color: .tronError,
                        role: .destructive
                    ) {
                        showPruneConfirmation = false
                        prune()
                    },
                    GlassAction(
                        title: "Cancel",
                        icon: nil,
                        color: .tronTextMuted,
                        role: .cancel
                    ) {
                        showPruneConfirmation = false
                    }
                ]
            )
            .presentationCompactAdaptation(.popover)
        }
    }

    private func prune() {
        Task {
            isPruning = true
            defer { isPruning = false }
            do {
                _ = try await rpcClient.worktree.pruneBranches(sessionId: sessionId)
                await loadAll()
            } catch {
                errorMessage = friendlyGitError(error, action: "Prune")
            }
        }
    }

    // MARK: States

    private var loadingState: some View {
        VStack(spacing: 10) {
            ProgressView().tint(accent)
            Text("Loading sessions…")
                .font(TronTypography.sans(size: TronTypography.sizeCaption))
                .foregroundStyle(.tronTextMuted)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "rectangle.stack")
                .font(.system(size: 28))
                .foregroundStyle(.tronTextMuted)
            Text("No sessions in this repo")
                .font(TronTypography.sans(size: TronTypography.sizeBody3))
                .foregroundStyle(.tronTextMuted)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
    }

    // MARK: Loader

    private func loadAll() async {
        isLoading = true
        defer { isLoading = false }
        async let active: [RepoSessionSummary] = {
            (try? await rpcClient.repo.listSessions(sessionId: sessionId)) ?? []
        }()
        async let all: [SessionBranchInfo] = {
            (try? await rpcClient.worktree.listSessionBranches(sessionId: sessionId)) ?? []
        }()
        let (activeResult, allBranches) = await (active, all)
        activeSessions = activeResult
        endedBranches = allBranches.filter { !$0.isActive }
    }
}
