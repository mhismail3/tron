import SwiftUI

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

#if DEBUG
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
#endif
