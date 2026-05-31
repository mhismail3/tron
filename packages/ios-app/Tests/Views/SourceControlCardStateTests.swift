import Testing
@testable import TronMobile

@Suite("SourceControlCardState")
struct SourceControlCardStateTests {

    @Test("No worktree disables source control and ignores stale diff")
    func noWorktreeDisablesSourceControlAndIgnoresStaleDiff() {
        let staleDiff = WorktreeGetDiffResult(
            isGitRepo: true,
            branch: "main",
            files: [
                DiffFileEntry(
                    path: "Sources/Stale.swift",
                    status: "modified",
                    stagingArea: "unstaged",
                    diff: nil,
                    additions: 12,
                    deletions: 3
                )
            ],
            summary: DiffFileSummary(totalFiles: 1, totalAdditions: 12, totalDeletions: 3),
            truncated: false
        )

        let state = SourceControlCardState(
            worktreeStatus: .empty,
            diffResult: staleDiff,
            isLoading: false,
            workspacePath: "/tmp/testspace"
        )

        #expect(state.isEnabled == false)
        #expect(state.shouldQueryDiff == false)
        #expect(state.branchLabel == "No Worktree")
        #expect(state.detailLabel == "No session worktree")
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
        let diff = WorktreeGetDiffResult(
            isGitRepo: true,
            branch: "stale-local-branch",
            files: [
                DiffFileEntry(
                    path: "Sources/One.swift",
                    status: "modified",
                    stagingArea: "unstaged",
                    diff: nil,
                    additions: 5,
                    deletions: 1
                ),
                DiffFileEntry(
                    path: "Sources/Two.swift",
                    status: "added",
                    stagingArea: "staged",
                    diff: nil,
                    additions: 7,
                    deletions: 0
                )
            ],
            summary: DiffFileSummary(totalFiles: 2, totalAdditions: 12, totalDeletions: 1),
            truncated: false
        )

        let state = SourceControlCardState(
            worktreeStatus: status,
            diffResult: diff,
            isLoading: false,
            workspacePath: "/tmp/repo"
        )

        #expect(state.isEnabled == true)
        #expect(state.shouldQueryDiff == true)
        #expect(state.branchLabel == "feature-card")
        #expect(state.detailLabel == "2 files")
        #expect(state.isGitRepo == true)
        #expect(state.totalFiles == 2)
        #expect(state.totalAdditions == 12)
        #expect(state.totalDeletions == 1)
    }

    @Test("Passthrough repo status is not an actionable source-control worktree")
    func passthroughStatusDisablesSourceControl() {
        let status = WorktreeGetStatusResult.fixture(
            worktree: .fixture(
                isolated: false,
                branch: "main",
                baseBranch: nil,
                hasUncommittedChanges: true
            )
        )
        let staleDiff = WorktreeGetDiffResult(
            isGitRepo: true,
            branch: "main",
            files: [
                DiffFileEntry(
                    path: "README.md",
                    status: "modified",
                    stagingArea: "unstaged",
                    diff: nil,
                    additions: 1,
                    deletions: 0
                )
            ],
            summary: DiffFileSummary(totalFiles: 1, totalAdditions: 1, totalDeletions: 0),
            truncated: false
        )

        let state = SourceControlCardState(
            worktreeStatus: status,
            diffResult: staleDiff,
            isLoading: false,
            workspacePath: "/tmp/repo"
        )

        #expect(state.isEnabled == false)
        #expect(state.shouldQueryDiff == false)
        #expect(state.branchLabel == "No Worktree")
        #expect(state.detailLabel == "No session worktree")
        #expect(state.totalFiles == 0)
    }

    @Test("Unknown worktree status keeps the card inert while loading")
    func unknownWorktreeStatusStaysInert() {
        let state = SourceControlCardState(
            worktreeStatus: nil,
            diffResult: nil,
            isLoading: true,
            workspacePath: "/tmp/repo"
        )

        #expect(state.isEnabled == false)
        #expect(state.shouldQueryDiff == false)
        #expect(state.branchLabel == "Loading...")
        #expect(state.detailLabel == "Loading...")
        #expect(state.isGitRepo == nil)
    }
}
