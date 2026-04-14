import Testing
import Foundation
@testable import TronMobile

// MARK: - FileDetailData Tests

@Suite("FileDetailData")
struct FileDetailDataTests {

    @Test("Creates from DiffFileEntry with all fields")
    func testCreateFromDiffFileEntry() {
        let entry = DiffFileEntry(
            path: "src/main.swift",
            status: "modified",
            stagingArea: nil,
            diff: "@@ -1,3 +1,3 @@\n-old\n+new",
            additions: 1,
            deletions: 1
        )
        let data = FileDetailData(from: entry)
        #expect(data.id == "src/main.swift")
        #expect(data.path == "src/main.swift")
        #expect(data.fileName == "main.swift")
        #expect(data.fileExtension == "swift")
        #expect(data.changeStatus == .modified)
        #expect(data.diff == "@@ -1,3 +1,3 @@\n-old\n+new")
        #expect(data.additions == 1)
        #expect(data.deletions == 1)
    }

    @Test("Creates from CommittedFileEntry with all fields")
    func testCreateFromCommittedFileEntry() {
        let entry = CommittedFileEntry(
            path: "lib/utils.ts",
            status: "A",
            diff: "@@ -0,0 +1,5 @@\n+line1\n+line2",
            additions: 5,
            deletions: 0
        )
        let data = FileDetailData(from: entry)
        #expect(data.id == "lib/utils.ts")
        #expect(data.path == "lib/utils.ts")
        #expect(data.fileName == "utils.ts")
        #expect(data.fileExtension == "ts")
        #expect(data.changeStatus == .added)
        #expect(data.additions == 5)
        #expect(data.deletions == 0)
    }

    @Test("Identifiable by path — unique IDs for different files")
    func testIdentifiableByPath() {
        let a = FileDetailData(from: DiffFileEntry(path: "a.swift", status: "modified", stagingArea: nil, diff: nil, additions: 0, deletions: 0))
        let b = FileDetailData(from: DiffFileEntry(path: "b.swift", status: "modified", stagingArea: nil, diff: nil, additions: 0, deletions: 0))
        #expect(a.id != b.id)
        #expect(a.id == "a.swift")
        #expect(b.id == "b.swift")
    }

    @Test("Handles nil diff gracefully")
    func testNilDiff() {
        let entry = DiffFileEntry(path: "new-file.txt", status: "untracked", stagingArea: nil, diff: nil, additions: 0, deletions: 0)
        let data = FileDetailData(from: entry)
        #expect(data.diff == nil)
        #expect(data.changeStatus == .untracked)
    }

    @Test("Handles empty path")
    func testEmptyPath() {
        let entry = DiffFileEntry(path: "", status: "modified", stagingArea: nil, diff: nil, additions: 0, deletions: 0)
        let data = FileDetailData(from: entry)
        #expect(data.id == "")
        #expect(data.path == "")
    }

    @Test("All FileChangeStatus values map correctly from DiffFileEntry")
    func testAllStatusesDiffFileEntry() {
        let statuses: [(String, FileChangeStatus)] = [
            ("modified", .modified),
            ("added", .added),
            ("deleted", .deleted),
            ("renamed", .renamed),
            ("untracked", .untracked),
            ("unmerged", .unmerged),
            ("copied", .copied),
        ]
        for (raw, expected) in statuses {
            let entry = DiffFileEntry(path: "file.txt", status: raw, stagingArea: nil, diff: nil, additions: 0, deletions: 0)
            let data = FileDetailData(from: entry)
            #expect(data.changeStatus == expected, "Status '\(raw)' should map to \(expected)")
        }
    }

    @Test("All FileChangeStatus values map correctly from CommittedFileEntry")
    func testAllStatusesCommittedFileEntry() {
        let statuses: [(String, FileChangeStatus)] = [
            ("A", .added),
            ("M", .modified),
            ("D", .deleted),
            ("R", .renamed),
            ("C", .copied),
        ]
        for (raw, expected) in statuses {
            let entry = CommittedFileEntry(path: "file.txt", status: raw, diff: nil, additions: 0, deletions: 0)
            let data = FileDetailData(from: entry)
            #expect(data.changeStatus == expected, "Status '\(raw)' should map to \(expected)")
        }
    }

    @Test("Unknown CommittedFileEntry status defaults to modified")
    func testUnknownCommittedStatus() {
        let entry = CommittedFileEntry(path: "file.txt", status: "X", diff: nil, additions: 0, deletions: 0)
        let data = FileDetailData(from: entry)
        #expect(data.changeStatus == .modified)
    }

    @Test("Unknown DiffFileEntry status defaults to modified")
    func testUnknownDiffStatus() {
        let entry = DiffFileEntry(path: "file.txt", status: "unknown", stagingArea: nil, diff: nil, additions: 0, deletions: 0)
        let data = FileDetailData(from: entry)
        #expect(data.changeStatus == .modified)
    }

    @Test("File extension extracted correctly for dotfiles")
    func testDotfile() {
        let entry = DiffFileEntry(path: ".gitignore", status: "modified", stagingArea: nil, diff: nil, additions: 1, deletions: 0)
        let data = FileDetailData(from: entry)
        #expect(data.fileName == ".gitignore")
        // .gitignore has no extension
        #expect(data.fileExtension == "")
    }

    @Test("File extension extracted correctly for nested paths")
    func testNestedPath() {
        let entry = DiffFileEntry(path: "packages/ios-app/Sources/Views/MyView.swift", status: "modified", stagingArea: nil, diff: nil, additions: 5, deletions: 3)
        let data = FileDetailData(from: entry)
        #expect(data.fileName == "MyView.swift")
        #expect(data.fileExtension == "swift")
    }
}

// MARK: - Source Control Metadata Tests

@Suite("SourceControlMetadata")
struct SourceControlMetadataTests {

    // MARK: - canCommit

    @Test("canCommit true when worktree has uncommitted changes and not loading")
    func testCanCommitTrue() {
        let result = SourceControlMetadata.canCommit(
            worktreeStatus: statusWith(hasUncommittedChanges: true),
            isLoading: false
        )
        #expect(result == true)
    }

    @Test("canCommit false when loading")
    func testCanCommitFalseWhenLoading() {
        let result = SourceControlMetadata.canCommit(
            worktreeStatus: statusWith(hasUncommittedChanges: true),
            isLoading: true
        )
        #expect(result == false)
    }

    @Test("canCommit false when no uncommitted changes")
    func testCanCommitFalseNoChanges() {
        let result = SourceControlMetadata.canCommit(
            worktreeStatus: statusWith(hasUncommittedChanges: false),
            isLoading: false
        )
        #expect(result == false)
    }

    @Test("canCommit false when hasUncommittedChanges is nil")
    func testCanCommitFalseNilChanges() {
        let result = SourceControlMetadata.canCommit(
            worktreeStatus: statusWith(hasUncommittedChanges: nil),
            isLoading: false
        )
        #expect(result == false)
    }

    @Test("canCommit false when no worktree")
    func testCanCommitFalseNoWorktree() {
        let result = SourceControlMetadata.canCommit(
            worktreeStatus: WorktreeGetStatusResult(hasWorktree: false, worktree: nil),
            isLoading: false
        )
        #expect(result == false)
    }

    @Test("canCommit false when worktreeStatus is nil")
    func testCanCommitFalseNilStatus() {
        let result = SourceControlMetadata.canCommit(
            worktreeStatus: nil,
            isLoading: false
        )
        #expect(result == false)
    }

    // MARK: - canMerge

    @Test("canMerge true when commitCount > 0, not merged, not loading")
    func testCanMergeTrue() {
        let result = SourceControlMetadata.canMerge(
            worktreeStatus: statusWith(commitCount: 3, isMerged: false),
            isLoading: false
        )
        #expect(result == true)
    }

    @Test("canMerge false when loading")
    func testCanMergeFalseWhenLoading() {
        let result = SourceControlMetadata.canMerge(
            worktreeStatus: statusWith(commitCount: 3, isMerged: false),
            isLoading: true
        )
        #expect(result == false)
    }

    @Test("canMerge false when already merged")
    func testCanMergeFalseWhenMerged() {
        let result = SourceControlMetadata.canMerge(
            worktreeStatus: statusWith(commitCount: 3, isMerged: true),
            isLoading: false
        )
        #expect(result == false)
    }

    @Test("canMerge false when 0 commits")
    func testCanMergeFalseZeroCommits() {
        let result = SourceControlMetadata.canMerge(
            worktreeStatus: statusWith(commitCount: 0, isMerged: false),
            isLoading: false
        )
        #expect(result == false)
    }

    @Test("canMerge false when commitCount is nil")
    func testCanMergeFalseNilCommitCount() {
        let result = SourceControlMetadata.canMerge(
            worktreeStatus: statusWith(commitCount: nil, isMerged: false),
            isLoading: false
        )
        #expect(result == false)
    }

    @Test("canMerge false when no worktree")
    func testCanMergeFalseNoWorktree() {
        let result = SourceControlMetadata.canMerge(
            worktreeStatus: WorktreeGetStatusResult(hasWorktree: false, worktree: nil),
            isLoading: false
        )
        #expect(result == false)
    }

    @Test("canMerge true when isMerged is nil (treats as not merged)")
    func testCanMergeTrueNilMerged() {
        let result = SourceControlMetadata.canMerge(
            worktreeStatus: statusWith(commitCount: 2, isMerged: nil),
            isLoading: false
        )
        #expect(result == true)
    }

    // MARK: - commitLabel

    @Test("commitLabel singular for 1 commit")
    func testCommitLabelSingular() {
        let label = SourceControlMetadata.commitLabel(for: statusWith(commitCount: 1))
        #expect(label == "1 commit")
    }

    @Test("commitLabel plural for 0 commits")
    func testCommitLabelZero() {
        let label = SourceControlMetadata.commitLabel(for: statusWith(commitCount: 0))
        #expect(label == "0 commits")
    }

    @Test("commitLabel plural for 2+ commits")
    func testCommitLabelPlural() {
        let label = SourceControlMetadata.commitLabel(for: statusWith(commitCount: 5))
        #expect(label == "5 commits")
    }

    @Test("commitLabel for nil commitCount")
    func testCommitLabelNilCount() {
        let label = SourceControlMetadata.commitLabel(for: statusWith(commitCount: nil))
        #expect(label == "0 commits")
    }

    @Test("commitLabel for nil worktreeStatus")
    func testCommitLabelNilStatus() {
        let label = SourceControlMetadata.commitLabel(for: nil)
        #expect(label == "0 commits")
    }

    // MARK: - showTabs

    @Test("showTabs true when has worktree and is git repo")
    func testShowTabsWorktree() {
        let result = SourceControlMetadata.showTabs(
            diffResult: WorktreeGetDiffResult(isGitRepo: true, branch: "main", files: [], summary: nil, truncated: nil),
            worktreeStatus: statusWith(),
            branches: []
        )
        #expect(result == true)
    }

    @Test("showTabs true when has branches but no worktree")
    func testShowTabsBranches() {
        let branch = SessionBranchInfo(
            branch: "session/abc", isActive: false, sessionId: nil,
            commitCount: 1, lastCommitHash: "abc", lastCommitMessage: "msg",
            lastCommitDate: "2026-01-01", baseBranch: "main"
        )
        let result = SourceControlMetadata.showTabs(
            diffResult: WorktreeGetDiffResult(isGitRepo: true, branch: "main", files: [], summary: nil, truncated: nil),
            worktreeStatus: WorktreeGetStatusResult(hasWorktree: false, worktree: nil),
            branches: [branch]
        )
        #expect(result == true)
    }

    @Test("showTabs false when not a git repo")
    func testShowTabsNotGitRepo() {
        let result = SourceControlMetadata.showTabs(
            diffResult: WorktreeGetDiffResult(isGitRepo: false, branch: nil, files: nil, summary: nil, truncated: nil),
            worktreeStatus: nil,
            branches: []
        )
        #expect(result == false)
    }

    @Test("showTabs false when no worktree and no branches")
    func testShowTabsNoWorktreeNoBranches() {
        let result = SourceControlMetadata.showTabs(
            diffResult: WorktreeGetDiffResult(isGitRepo: true, branch: "main", files: [], summary: nil, truncated: nil),
            worktreeStatus: WorktreeGetStatusResult(hasWorktree: false, worktree: nil),
            branches: []
        )
        #expect(result == false)
    }

    @Test("showTabs false when diffResult is nil")
    func testShowTabsNilDiffResult() {
        let result = SourceControlMetadata.showTabs(
            diffResult: nil,
            worktreeStatus: statusWith(),
            branches: []
        )
        #expect(result == false)
    }

    // MARK: - noChangeLabel

    @Test("noChangeLabel for untracked files")
    func testNoChangeLabelUntracked() {
        #expect(SourceControlMetadata.noChangeLabel(for: .untracked) == "New file (untracked)")
    }

    @Test("noChangeLabel for deleted files")
    func testNoChangeLabelDeleted() {
        #expect(SourceControlMetadata.noChangeLabel(for: .deleted) == "File deleted")
    }

    @Test("noChangeLabel for added files")
    func testNoChangeLabelAdded() {
        #expect(SourceControlMetadata.noChangeLabel(for: .added) == "New file")
    }

    @Test("noChangeLabel for unmerged files")
    func testNoChangeLabelUnmerged() {
        #expect(SourceControlMetadata.noChangeLabel(for: .unmerged) == "Merge conflict")
    }

    @Test("noChangeLabel for other statuses")
    func testNoChangeLabelDefault() {
        #expect(SourceControlMetadata.noChangeLabel(for: .modified) == "No diff available")
        #expect(SourceControlMetadata.noChangeLabel(for: .renamed) == "No diff available")
        #expect(SourceControlMetadata.noChangeLabel(for: .copied) == "No diff available")
    }

    // MARK: - Helpers

    private func statusWith(
        hasUncommittedChanges: Bool? = false,
        commitCount: Int? = 0,
        isMerged: Bool? = false
    ) -> WorktreeGetStatusResult {
        WorktreeGetStatusResult(
            hasWorktree: true,
            worktree: WorktreeInfo(
                isolated: true,
                branch: "session/test",
                baseCommit: "abc123",
                path: "/tmp/worktree",
                baseBranch: "main",
                repoRoot: "/tmp/repo",
                hasUncommittedChanges: hasUncommittedChanges,
                commitCount: commitCount,
                isMerged: isMerged
            )
        )
    }
}

// MARK: - Diff Content Extraction Tests

@Suite("DiffContentExtraction")
struct DiffContentExtractionTests {

    @Test("Extracts raw content from additions-only diff")
    func testExtractAdditionsOnly() {
        let diff = "@@ -0,0 +1,3 @@\n+line one\n+line two\n+line three"
        let lines = SourceControlMetadata.extractFileContent(from: diff)
        #expect(lines?.count == 3)
        #expect(lines?[0] == "line one")
        #expect(lines?[1] == "line two")
        #expect(lines?[2] == "line three")
    }

    @Test("Extracts post-image from mixed diff (additions and deletions)")
    func testMixedDiffExtractsPostImage() {
        // extractFileContent reconstructs the "after" state: deletions are skipped,
        // additions and context lines are included.
        let diff = "@@ -1,3 +1,3 @@\n-old line\n+new line\n context"
        let lines = SourceControlMetadata.extractFileContent(from: diff)
        #expect(lines?.count == 2)
        #expect(lines?[0] == "new line")
        #expect(lines?[1] == "context")
    }

    @Test("Returns nil for nil diff")
    func testNilDiffReturnsNil() {
        let lines = SourceControlMetadata.extractFileContent(from: nil)
        #expect(lines == nil)
    }

    @Test("Returns nil for empty diff")
    func testEmptyDiffReturnsNil() {
        let lines = SourceControlMetadata.extractFileContent(from: "")
        #expect(lines == nil)
    }

    @Test("Handles diff with file headers (--- / +++)")
    func testDiffWithHeaders() {
        let diff = "--- /dev/null\n+++ b/newfile.txt\n@@ -0,0 +1,2 @@\n+hello\n+world"
        let lines = SourceControlMetadata.extractFileContent(from: diff)
        #expect(lines?.count == 2)
        #expect(lines?[0] == "hello")
        #expect(lines?[1] == "world")
    }

    @Test("Returns nil for deletions-only diff")
    func testDeletionsOnlyReturnsNil() {
        let diff = "@@ -1,2 +0,0 @@\n-deleted line 1\n-deleted line 2"
        let lines = SourceControlMetadata.extractFileContent(from: diff)
        #expect(lines == nil)
    }
}
