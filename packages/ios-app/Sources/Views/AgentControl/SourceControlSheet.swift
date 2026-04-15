import SwiftUI

// MARK: - Source Control Sheet

/// Drill-down sheet for source control details: staged/unstaged files, branches, commit/merge actions.
/// Presented from AgentControlView via the SourceControlCardView.
@available(iOS 26.0, *)
struct SourceControlSheet: View {
    let rpcClient: RPCClient
    let sessionId: String
    var initialDiffResult: WorktreeGetDiffResult?
    var initialWorktreeStatus: WorktreeGetStatusResult?
    var initialBranches: [SessionBranchInfo] = []
    var onAskAgent: ((String) -> Void)?

    @Environment(\.dismiss) private var dismiss

    // Self-managed data state
    @State private var diffResult: WorktreeGetDiffResult?
    @State private var worktreeStatus: WorktreeGetStatusResult?
    @State private var branches: [SessionBranchInfo] = []

    // Git actions
    @State private var isCommitting = false
    @State private var isMerging = false
    @State private var showCommitConfirmation = false
    @State private var showMergeConfirmation = false
    @State private var errorMessage: String?

    // Sub-sheets
    @State private var selectedFileDetail: FileDetailData?
    @State private var showAllBranches = false
    @State private var isReloading = false

    // MARK: - Computed Properties

    private var stagedFiles: [DiffFileEntry] {
        diffResult?.files?.filter { $0.fileStagingArea == .staged } ?? []
    }

    private var unstagedFiles: [DiffFileEntry] {
        diffResult?.files?.filter { $0.fileStagingArea == .unstaged } ?? []
    }

    private var canCommit: Bool {
        SourceControlMetadata.canCommit(
            worktreeStatus: worktreeStatus,
            isLoading: isCommitting
        )
    }

    private var canMerge: Bool {
        SourceControlMetadata.canMerge(
            worktreeStatus: worktreeStatus,
            isLoading: isMerging
        )
    }

    private var showBranchesButton: Bool {
        diffResult?.isGitRepo == true || diffResult == nil
    }

    // MARK: - Body

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Scrollable changes content
                GeometryReader { geometry in
                    ScrollView(.vertical, showsIndicators: true) {
                        VStack(spacing: 16) {
                            SessionChangesSection(
                                diffResult: diffResult,
                                worktreeStatus: worktreeStatus,
                                stagedFiles: stagedFiles,
                                unstagedFiles: unstagedFiles,
                                branches: branches,
                                onFileSelected: { selectedFileDetail = $0 },
                                onShowAllBranches: { showAllBranches = true },
                                hideBranchesRow: true,
                                availableHeight: geometry.size.height
                            )
                            .padding(.horizontal)
                        }
                        .padding(.vertical)
                        .frame(width: geometry.size.width)
                    }
                    .frame(width: geometry.size.width)
                }

                // Bottom-pinned branches button
                if showBranchesButton {
                    viewAllBranchesButton
                        .padding(.horizontal)
                        .padding(.bottom, 16)
                        .padding(.top, 8)
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackgroundVisibility(.hidden, for: .navigationBar)
            .toolbar {
                ToolbarItemGroup(placement: .topBarLeading) {
                    commitButton
                    mergeButton
                }
                ToolbarItem(placement: .principal) {
                    Text("Source Control")
                        .font(TronTypography.mono(size: TronTypography.sizeTitle, weight: .semibold))
                        .foregroundStyle(.tronTeal)
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button {
                        Task {
                            isReloading = true
                            await loadData()
                            isReloading = false
                        }
                    } label: {
                        Group {
                            if isReloading {
                                ProgressView()
                                    .scaleEffect(0.7)
                                    .tint(.tronTeal)
                            } else {
                                Image(systemName: "arrow.clockwise")
                                    .font(TronTypography.buttonSM)
                                    .foregroundStyle(.tronTeal)
                            }
                        }
                    }
                    .disabled(isReloading)
                    Button { dismiss() } label: {
                        Image(systemName: "checkmark")
                            .font(TronTypography.buttonSM)
                            .foregroundStyle(.tronTeal)
                    }
                }
            }
            .tronErrorAlert(message: $errorMessage)
            .task {
                // Pre-populate from parent's data, then refresh in background
                diffResult = initialDiffResult
                worktreeStatus = initialWorktreeStatus
                branches = initialBranches
                await loadData()
            }
        }
        .adaptivePresentationDetents([.medium, .large])
        .presentationDragIndicator(.hidden)
        .tint(.tronTeal)
        .sheet(item: $selectedFileDetail) { fileData in
            FileDetailSheet(
                file: fileData,
                stagingArea: fileData.stagingArea,
                rpcClient: rpcClient,
                sessionId: sessionId,
                onAction: {
                    Task { await loadData() }
                }
            )
            .presentationDragIndicator(.hidden)
            .adaptivePresentationDetents([.medium, .large])
        }
        .sheet(isPresented: $showAllBranches, onDismiss: {
            Task { await loadData() }
        }) {
            AllBranchesSheet(
                rpcClient: rpcClient,
                sessionId: sessionId,
                initialBranches: branches,
                onAskAgent: { message in
                    showAllBranches = false
                    dismiss()
                    onAskAgent?(message)
                }
            )
        }
    }

    // MARK: - View All Branches Button

    private var viewAllBranchesButton: some View {
        Button(action: { showAllBranches = true }) {
            HStack(spacing: 10) {
                Image(systemName: "arrow.triangle.branch")
                    .font(TronTypography.sans(size: TronTypography.sizeBody))
                    .foregroundStyle(.tronTeal)

                Text("View All Branches")
                    .font(TronTypography.mono(size: TronTypography.sizeBody, weight: .medium))
                    .foregroundStyle(.tronTextPrimary)

                if !branches.isEmpty {
                    Text("\(branches.count)")
                        .font(TronTypography.pillValue)
                        .countBadge(.tronTeal)
                }

                Spacer()

                Image(systemName: "chevron.right")
                    .font(TronTypography.sans(size: TronTypography.sizeCaption, weight: .medium))
                    .foregroundStyle(.tronTextMuted)
            }
            .padding(12)
            .sectionFill(.tronTeal)
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    // MARK: - Toolbar Buttons

    @ViewBuilder
    private var commitButton: some View {
        Button { showCommitConfirmation = true } label: {
            if isCommitting {
                ProgressView().controlSize(.small)
            } else {
                Image(systemName: "checkmark.circle")
                    .font(TronTypography.sans(size: TronTypography.sizeBody))
                    .foregroundStyle(canCommit ? .tronTeal : .tronTextMuted.opacity(0.5))
            }
        }
        .disabled(!canCommit || isCommitting)
        .accessibilityLabel("Commit")
        .popover(isPresented: $showCommitConfirmation, arrowEdge: .top) {
            GlassActionSheet(
                actions: [
                    GlassAction(title: "Commit Changes", icon: "checkmark.circle", color: .tronTeal, role: .default) {
                        showCommitConfirmation = false
                        commitChanges()
                    },
                    GlassAction(title: "Cancel", icon: nil, color: .tronTextMuted, role: .cancel) {
                        showCommitConfirmation = false
                    }
                ]
            )
            .presentationCompactAdaptation(.popover)
        }
    }

    @ViewBuilder
    private var mergeButton: some View {
        Button { showMergeConfirmation = true } label: {
            if isMerging {
                ProgressView().controlSize(.small)
            } else {
                Image(systemName: "arrow.triangle.merge")
                    .font(TronTypography.sans(size: TronTypography.sizeBody))
                    .foregroundStyle(canMerge ? .tronTeal : .tronTextMuted.opacity(0.5))
            }
        }
        .disabled(!canMerge || isMerging)
        .accessibilityLabel("Merge")
        .popover(isPresented: $showMergeConfirmation, arrowEdge: .top) {
            GlassActionSheet(
                actions: [
                    GlassAction(
                        title: "Merge to \(worktreeStatus?.worktree?.baseBranch ?? "main")",
                        icon: "arrow.triangle.merge",
                        color: .tronTeal,
                        role: .default
                    ) {
                        showMergeConfirmation = false
                        mergeChanges()
                    },
                    GlassAction(title: "Cancel", icon: nil, color: .tronTextMuted, role: .cancel) {
                        showMergeConfirmation = false
                    }
                ]
            )
            .presentationCompactAdaptation(.popover)
        }
    }

    // MARK: - Data Loading

    private func loadData() async {
        do {
            async let diff = rpcClient.worktree.getWorkingDirectoryDiff(sessionId: sessionId)
            async let status: WorktreeGetStatusResult? = { try? await rpcClient.worktree.getStatus(sessionId: sessionId) }()
            async let branchList = { (try? await rpcClient.worktree.listSessionBranches(sessionId: sessionId)) ?? [] }()
            diffResult = try await diff
            worktreeStatus = await status
            branches = await branchList
        } catch {
            errorMessage = "Failed to load changes: \(error.localizedDescription)"
        }
    }

    // MARK: - Git Actions

    private func commitChanges() {
        Task {
            isCommitting = true
            defer { isCommitting = false }

            do {
                let result = try await rpcClient.worktree.commit(
                    sessionId: sessionId,
                    message: "Manual commit from iOS"
                )
                if result.success {
                    await loadData()
                } else if let error = result.error {
                    errorMessage = "Commit failed: \(error)"
                }
            } catch {
                errorMessage = "Commit failed: \(error.localizedDescription)"
            }
        }
    }

    private func mergeChanges() {
        Task {
            isMerging = true
            defer { isMerging = false }

            do {
                let targetBranch = worktreeStatus?.worktree?.baseBranch ?? "main"
                let mergeResult = try await rpcClient.worktree.merge(
                    sessionId: sessionId,
                    targetBranch: targetBranch
                )
                if !mergeResult.success {
                    if let conflicts = mergeResult.conflicts, !conflicts.isEmpty {
                        errorMessage = "Merge conflicts in: \(conflicts.joined(separator: ", "))"
                    } else if let error = mergeResult.error {
                        errorMessage = error
                    }
                }
                await loadData()
            } catch {
                errorMessage = "Merge failed: \(error.localizedDescription)"
            }
        }
    }
}
