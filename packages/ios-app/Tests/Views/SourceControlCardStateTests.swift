import Testing
@testable import TronMobile

@Suite("SourceControlCardState")
struct SourceControlCardStateTests {

    @Test("No worktree disables source control and ignores stale diff")
    func noWorktreeDisablesSourceControlAndIgnoresStaleDiff() {
        let staleSummary = WorktreeGetDiffSummaryResult(
            isGitRepo: true,
            branch: "main",
            summary: DiffFileSummary(totalFiles: 1, totalAdditions: 12, totalDeletions: 3),
            truncated: false
        )

        let state = SourceControlCardState(
            worktreeStatus: .empty,
            diffSummaryResult: staleSummary,
            isLoading: false,
            workspacePath: "/tmp/testspace"
        )

        #expect(state.isVisible == false)
        #expect(state.branchLabel == "No Source Control")
        #expect(state.detailLabel == "No git checkout")
        #expect(state.isGitRepo == nil)
        #expect(state.totalFiles == 0)
        #expect(state.totalAdditions == 0)
        #expect(state.totalDeletions == 0)
    }

    @Test("Known worktree keeps source control enabled and uses server branch")
    func knownWorktreeUsesServerBranchAndDiffStats() {
        let status = WorktreeGetStatusResult.fixture(
            worktree: .fixture(
                branch: "session/feature-card",
                hasUncommittedChanges: true
            )
        )
        let summary = WorktreeGetDiffSummaryResult(
            isGitRepo: true,
            branch: "stale-local-branch",
            summary: DiffFileSummary(totalFiles: 2, totalAdditions: 12, totalDeletions: 1),
            truncated: false
        )

        let state = SourceControlCardState(
            worktreeStatus: status,
            diffSummaryResult: summary,
            isLoading: false,
            workspacePath: "/tmp/repo"
        )

        #expect(state.isVisible == true)
        #expect(state.branchLabel == "feature-card")
        #expect(state.detailLabel == "2 files")
        #expect(state.isGitRepo == true)
        #expect(state.totalFiles == 2)
        #expect(state.totalAdditions == 12)
        #expect(state.totalDeletions == 1)
    }

    @Test("Known dirty worktree renders branch before summary arrives")
    func knownDirtyWorktreeRendersBranchBeforeSummaryArrives() {
        let status = WorktreeGetStatusResult.fixture(
            worktree: .fixture(
                branch: "session/feature-card",
                hasUncommittedChanges: true
            )
        )

        let state = SourceControlCardState(
            worktreeStatus: status,
            diffSummaryResult: nil,
            isLoading: true,
            workspacePath: "/tmp/repo"
        )

        #expect(state.isVisible == true)
        #expect(state.branchLabel == "feature-card")
        #expect(state.detailLabel == "Loading...")
        #expect(state.totalFiles == 0)
    }

    @Test("Passthrough repo status enables direct-branch source control")
    func passthroughStatusEnablesDirectBranchSourceControl() {
        let status = WorktreeGetStatusResult.fixture(
            worktree: .fixture(
                isolated: false,
                branch: "main",
                baseBranch: nil,
                hasUncommittedChanges: true
            )
        )
        let staleDiff = WorktreeGetDiffSummaryResult(
            isGitRepo: true,
            branch: "main",
            summary: DiffFileSummary(totalFiles: 1, totalAdditions: 1, totalDeletions: 0),
            truncated: false
        )

        let state = SourceControlCardState(
            worktreeStatus: status,
            diffSummaryResult: staleDiff,
            isLoading: false,
            workspacePath: "/tmp/repo"
        )

        #expect(state.isVisible == true)
        #expect(state.branchLabel == "main")
        #expect(state.detailLabel == "1 file")
        #expect(state.totalFiles == 1)
        #expect(state.totalAdditions == 1)
        #expect(state.totalDeletions == 0)
    }

    @Test("Clean passthrough status shows direct branch without loading label")
    func cleanPassthroughStatusShowsDirectBranchWithoutLoading() {
        let status = WorktreeGetStatusResult.fixture(
            worktree: .fixture(
                isolated: false,
                branch: "main",
                baseBranch: nil,
                hasUncommittedChanges: false
            )
        )

        let state = SourceControlCardState(
            worktreeStatus: status,
            diffSummaryResult: nil,
            isLoading: false,
            workspacePath: "/tmp/repo"
        )

        #expect(state.isVisible == true)
        #expect(state.branchLabel == "main")
        #expect(state.detailLabel == "Direct branch")
        #expect(state.totalFiles == 0)
    }

    @Test("Unknown worktree status keeps the card inert while loading")
    func unknownWorktreeStatusStaysInert() {
        let state = SourceControlCardState(
            worktreeStatus: nil,
            diffSummaryResult: nil,
            isLoading: true,
            workspacePath: "/tmp/repo"
        )

        #expect(state.isVisible == false)
        #expect(state.branchLabel == "Loading...")
        #expect(state.detailLabel == "Loading...")
        #expect(state.isGitRepo == nil)
    }
}
