import SwiftUI

/// Displays worktree status for a session with commit/merge actions
struct WorktreeStatusView: View {
    let status: WorktreeGetStatusResult
    let isLoading: Bool
    let onCommit: (() -> Void)?
    let onMerge: (() -> Void)?

    init(
        status: WorktreeGetStatusResult,
        isLoading: Bool = false,
        onCommit: (() -> Void)? = nil,
        onMerge: (() -> Void)? = nil
    ) {
        self.status = status
        self.isLoading = isLoading
        self.onCommit = onCommit
        self.onMerge = onMerge
    }

    var body: some View {
        if status.hasWorktree, let worktree = status.worktree {
            HStack(spacing: 12) {
                // Branch indicator
                HStack(spacing: 4) {
                    Image(systemName: "arrow.triangle.branch")
                        .foregroundStyle(.tronEmerald)
                        .font(TronTypography.caption)

                    Text(worktree.shortBranch)
                        .font(TronTypography.codeCaption)
                        .foregroundStyle(.secondary)

                    if worktree.hasUncommittedChanges == true {
                        Circle()
                            .fill(.orange)
                            .frame(width: 6, height: 6)
                    }
                }

                // Isolated badge
                if worktree.isolated {
                    Text("Isolated")
                        .font(TronTypography.caption2)
                        .fontWeight(.medium)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.ultraThinMaterial)
                        .clipShape(Capsule())
                }

                // Commit count
                Text(commitLabel)
                    .font(TronTypography.caption)
                    .foregroundStyle(.tertiary)

                // Loading indicator
                if isLoading {
                    ProgressView()
                        .controlSize(.mini)
                }

                Spacer()

                // Actions
                if let onCommit = onCommit {
                    Button(action: onCommit) {
                        Label("Commit", systemImage: "checkmark.circle")
                            .font(TronTypography.caption)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.mini)
                    .tint(.accentColor)
                    .disabled(!canCommit)
                }

                if let onMerge = onMerge {
                    Button(action: onMerge) {
                        Label("Merge", systemImage: "arrow.triangle.merge")
                            .font(TronTypography.caption)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.mini)
                    .tint(.green)
                    .disabled(!canMerge)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.ultraThinMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
    }

    private var commitCount: Int {
        status.worktree?.commitCount ?? 0
    }

    private var commitLabel: String {
        commitCount == 1 ? "1 commit" : "\(commitCount) commits"
    }

    private var canCommit: Bool {
        !isLoading && (status.worktree?.hasUncommittedChanges == true)
    }

    private var canMerge: Bool {
        !isLoading && commitCount > 0
    }
}

/// Compact inline worktree indicator for sidebar/list items
struct WorktreeBadge: View {
    let worktree: WorktreeInfo

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "arrow.triangle.branch")
                .font(TronTypography.caption2)

            Text(worktree.shortBranch)
                .font(TronTypography.mono(size: TronTypography.sizeCaption))

            if worktree.hasUncommittedChanges == true {
                Circle()
                    .fill(.orange)
                    .frame(width: 4, height: 4)
            }
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(.ultraThinMaterial)
        .clipShape(Capsule())
    }
}

#Preview("WorktreeStatusView - Active") {
    VStack(spacing: 20) {
        WorktreeStatusView(
            status: WorktreeGetStatusResult(
                hasWorktree: true,
                worktree: WorktreeInfo(
                    isolated: true,
                    branch: "session/abc123",
                    baseCommit: "def456",
                    path: "/path/to/worktree",
                    hasUncommittedChanges: true,
                    commitCount: 3
                )
            ),
            onCommit: {},
            onMerge: {}
        )

        WorktreeStatusView(
            status: WorktreeGetStatusResult(
                hasWorktree: true,
                worktree: WorktreeInfo(
                    isolated: true,
                    branch: "session/abc123",
                    baseCommit: "def456",
                    path: "/path/to/worktree",
                    hasUncommittedChanges: false,
                    commitCount: 0
                )
            ),
            onCommit: {},
            onMerge: {}
        )
    }
    .padding()
    .background(Color(.systemBackground))
}

#Preview("WorktreeBadge") {
    WorktreeBadge(
        worktree: WorktreeInfo(
            isolated: true,
            branch: "session/abc123",
            baseCommit: "def456",
            path: "/path",
            hasUncommittedChanges: true,
            commitCount: 2
        )
    )
    .padding()
}
