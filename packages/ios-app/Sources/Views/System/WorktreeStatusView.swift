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
            VStack(spacing: 6) {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.triangle.branch")
                        .foregroundStyle(.tronEmerald)
                        .font(TronTypography.caption)

                    Text(worktree.shortBranch)
                        .font(TronTypography.codeCaption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)

                    if worktree.hasUncommittedChanges == true {
                        Circle()
                            .fill(.orange)
                            .frame(width: 6, height: 6)
                    }

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

                    Text(commitLabel)
                        .font(TronTypography.caption)
                        .foregroundStyle(.tertiary)

                    if worktree.isMerged == true {
                        Text("Merged")
                            .font(TronTypography.caption2)
                            .fontWeight(.medium)
                            .foregroundStyle(.tronSuccess)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(.ultraThinMaterial)
                            .clipShape(Capsule())
                    }

                    if isLoading {
                        ProgressView()
                            .controlSize(.mini)
                    }

                    Spacer()
                }

                if onCommit != nil || onMerge != nil {
                    HStack(spacing: 8) {
                        if let onCommit {
                            Button(action: onCommit) {
                                Label("Commit", systemImage: "checkmark.circle")
                                    .font(TronTypography.caption)
                                    .lineLimit(1)
                                    .foregroundStyle(.white)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 3)
                                    .background(Color.accentColor)
                                    .clipShape(Capsule())
                                    .opacity(canCommit ? 1 : 0.4)
                            }
                            .buttonStyle(.plain)
                            .disabled(!canCommit)
                        }

                        if let onMerge {
                            Button(action: onMerge) {
                                Label("Merge", systemImage: "arrow.triangle.merge")
                                    .font(TronTypography.caption)
                                    .lineLimit(1)
                                    .foregroundStyle(.white)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 3)
                                    .background(Color.tronEmerald)
                                    .clipShape(Capsule())
                                    .opacity(canMerge ? 1 : 0.4)
                            }
                            .buttonStyle(.plain)
                            .disabled(!canMerge)
                        }

                        Spacer()
                    }
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
        !isLoading && commitCount > 0 && status.worktree?.isMerged != true
    }
}

/// Compact inline worktree indicator for sidebar/list items
struct WorktreeBadge: View {
    let worktree: WorktreeInfo

    var body: some View {
        HStack(spacing: 4) {
            Image("IconGit")
                .renderingMode(.template)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 10, height: 10)

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
                    baseBranch: "main",
                    repoRoot: "/path/to/repo",
                    hasUncommittedChanges: true,
                    commitCount: 3,
                    isMerged: false
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
                    baseBranch: "main",
                    repoRoot: "/path/to/repo",
                    hasUncommittedChanges: false,
                    commitCount: 0,
                    isMerged: false
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
            baseBranch: "main",
            repoRoot: "/path/to/repo",
            hasUncommittedChanges: true,
            commitCount: 2,
            isMerged: false
        )
    )
    .padding()
}
