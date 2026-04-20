import SwiftUI

/// Small metadata icons shown immediately before a session's title:
/// purple `tuningfork` for a forked session, amber `arrow.triangle.branch`
/// when the worktree is off its base branch, with an amber dot when the
/// worktree has uncommitted changes.
///
/// Shared by the chat toolbar and the sidebar row so both read from the same
/// composition and remain visually identical.
struct SessionTitleIcons: View {
    let isFork: Bool
    let worktree: WorktreeInfo?

    enum Icon: Hashable { case fork, branch, dot }

    /// Pure, view-free computation of which icons should render. Used by the
    /// view body below and by unit tests to verify presentation rules.
    static func iconsShown(isFork: Bool, worktree: WorktreeInfo?) -> Set<Icon> {
        var icons: Set<Icon> = []
        if isFork { icons.insert(.fork) }
        if let w = worktree, !w.isOnBaseBranch {
            icons.insert(.branch)
            if w.hasUncommittedChanges == true {
                icons.insert(.dot)
            }
        }
        return icons
    }

    var body: some View {
        HStack(alignment: .center, spacing: 6) {
            if isFork {
                Image(systemName: "tuningfork")
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 11, height: 11)
                    .foregroundStyle(.tronPurple)
                    .transition(.opacity)
            }
            if let w = worktree, !w.isOnBaseBranch {
                HStack(spacing: 2) {
                    Image(systemName: "arrow.triangle.branch")
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 11, height: 11)
                        .foregroundStyle(.tronAmber)
                    if w.hasUncommittedChanges == true {
                        Circle()
                            .fill(.tronAmber)
                            .frame(width: 5, height: 5)
                    }
                }
                .transition(.opacity)
            }
        }
    }
}
