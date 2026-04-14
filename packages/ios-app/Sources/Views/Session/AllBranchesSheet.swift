import SwiftUI

// MARK: - All Branches Sheet

@available(iOS 26.0, *)
struct AllBranchesSheet: View {
    let rpcClient: RPCClient
    let sessionId: String
    let onAskAgent: ((String) -> Void)?

    @Environment(\.dismiss) private var dismiss
    @State private var branches: [SessionBranchInfo]
    @State private var selectedBranch: SessionBranchInfo?
    @State private var isPruning = false
    @State private var showPruneConfirmation = false

    init(
        rpcClient: RPCClient,
        sessionId: String,
        initialBranches: [SessionBranchInfo],
        onAskAgent: ((String) -> Void)?
    ) {
        self.rpcClient = rpcClient
        self.sessionId = sessionId
        self.onAskAgent = onAskAgent
        self._branches = State(initialValue: initialBranches)
    }

    private var hasInactiveBranches: Bool {
        branches.contains { !$0.isActive }
    }

    var body: some View {
        NavigationStack {
            branchesContent
                .navigationBarTitleDisplayMode(.inline)
                .toolbarBackgroundVisibility(.hidden, for: .navigationBar)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        if hasInactiveBranches {
                            pruneButton
                        }
                    }
                    ToolbarItem(placement: .principal) {
                        Text("All Branches")
                            .font(TronTypography.mono(size: TronTypography.sizeTitle, weight: .semibold))
                            .foregroundStyle(.tronTeal)
                    }
                    ToolbarItemGroup(placement: .topBarTrailing) {
                        Button { Task { await loadBranches() } } label: {
                            Image(systemName: "arrow.clockwise")
                                .font(TronTypography.buttonSM)
                                .foregroundStyle(.tronTeal)
                        }
                        Button { dismiss() } label: {
                            Image(systemName: "checkmark")
                                .font(TronTypography.buttonSM)
                                .foregroundStyle(.tronTeal)
                        }
                    }
                }
        }
        .adaptivePresentationDetents([.medium, .large])
        .presentationDragIndicator(.hidden)
        .tint(.tronTeal)
        .sheet(item: $selectedBranch, onDismiss: {
            Task { await loadBranches() }
        }) { branch in
            BranchDetailView(
                branch: branch,
                rpcClient: rpcClient,
                currentSessionId: sessionId,
                onAskAgent: { message in
                    selectedBranch = nil
                    dismiss()
                    onAskAgent?(message)
                }
            )
            .presentationDragIndicator(.hidden)
            .adaptivePresentationDetents([.medium, .large])
        }
    }

    // MARK: - Content

    @ViewBuilder
    private var branchesContent: some View {
        if branches.isEmpty {
            VStack(spacing: 12) {
                Image(systemName: "info.circle")
                    .font(TronTypography.sans(size: TronTypography.sizeDisplay))
                    .foregroundStyle(.tronTextMuted)
                Text("No session branches found")
                    .font(TronTypography.mono(size: TronTypography.sizeBody, weight: .semibold))
                    .foregroundStyle(.tronTextPrimary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            let activeBranches = branches.filter { $0.isActive && $0.sessionId != sessionId }
            let preservedBranches = branches.filter { !$0.isActive }
            let currentBranches = branches.filter { $0.isActive && $0.sessionId == sessionId }

            ScrollView {
                LazyVStack(spacing: 0) {
                    if !currentBranches.isEmpty {
                        sectionHeader("Current Session")
                        ForEach(currentBranches) { branch in
                            currentBranchRow(branch)
                        }
                    }

                    if !activeBranches.isEmpty {
                        sectionHeader("Active Sessions")
                        ForEach(activeBranches) { branch in
                            branchRow(branch)
                        }
                    }

                    if !preservedBranches.isEmpty {
                        sectionHeader("Preserved Branches")
                        ForEach(preservedBranches) { branch in
                            branchRow(branch)
                        }
                    }
                }
                .padding(.vertical)
            }
        }
    }

    // MARK: - Components

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(TronTypography.mono(size: TronTypography.sizeCaption, weight: .semibold))
            .foregroundStyle(.tronTextMuted)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal)
            .padding(.top, 12)
            .padding(.bottom, 4)
    }

    private func currentBranchRow(_ branch: SessionBranchInfo) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(branch.shortBranch)
                    .font(TronTypography.mono(size: TronTypography.sizeBodySM, weight: .medium))
                    .foregroundStyle(.tronTeal)

                Text(branch.lastCommitMessage)
                    .font(TronTypography.mono(size: TronTypography.sizeCaption))
                    .foregroundStyle(.tronTextMuted)
                    .lineLimit(1)
            }

            Spacer()

            if branch.commitCount > 0 {
                Text("\(branch.commitCount)")
                    .font(TronTypography.mono(size: TronTypography.sizeCaption, weight: .semibold))
                    .foregroundStyle(.tronTeal)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(.ultraThinMaterial)
                    .clipShape(Capsule())
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
    }

    private func branchRow(_ branch: SessionBranchInfo) -> some View {
        Button { selectedBranch = branch } label: {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(branch.shortBranch)
                        .font(TronTypography.mono(size: TronTypography.sizeBodySM, weight: .medium))
                        .foregroundStyle(.tronTextPrimary)

                    Text(branch.lastCommitMessage)
                        .font(TronTypography.mono(size: TronTypography.sizeCaption))
                        .foregroundStyle(.tronTextMuted)
                        .lineLimit(1)
                }

                Spacer()

                if branch.commitCount > 0 {
                    Text("\(branch.commitCount)")
                        .font(TronTypography.mono(size: TronTypography.sizeCaption, weight: .semibold))
                        .foregroundStyle(.tronTeal)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.ultraThinMaterial)
                        .clipShape(Capsule())
                }

                if !branch.isActive {
                    Text("Ended")
                        .font(TronTypography.caption2)
                        .fontWeight(.medium)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.ultraThinMaterial)
                        .clipShape(Capsule())
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Prune

    @ViewBuilder
    private var pruneButton: some View {
        Button { showPruneConfirmation = true } label: {
            if isPruning {
                ProgressView()
                    .controlSize(.small)
            } else {
                Label("Prune", systemImage: "trash")
                    .font(TronTypography.mono(size: TronTypography.sizeBody, weight: .medium))
                    .foregroundStyle(.tronError)
            }
        }
        .disabled(isPruning)
        .popover(isPresented: $showPruneConfirmation, arrowEdge: .bottom) {
            GlassActionSheet(
                actions: [
                    GlassAction(
                        title: "Delete all \(branches.filter({ !$0.isActive }).count) branches",
                        icon: "trash",
                        color: .tronError,
                        role: .destructive
                    ) {
                        showPruneConfirmation = false
                        pruneAllBranches()
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

    // MARK: - Data

    private func loadBranches() async {
        branches = (try? await rpcClient.worktree.listSessionBranches(sessionId: sessionId)) ?? []
    }

    private func pruneAllBranches() {
        Task {
            isPruning = true
            defer { isPruning = false }
            do {
                _ = try await rpcClient.worktree.pruneBranches(sessionId: sessionId)
                await loadBranches()
            } catch {
                // Silently handle — prune failures are non-critical
            }
        }
    }
}
