import Testing
@testable import TronMobile

@Suite("New session source control")
struct SessionSourceControlTests {
    private let repository = GitInspection(isRepository: true, branch: "main", isDirty: false)
    private let dirtyRepository = GitInspection(isRepository: true, branch: "main", isDirty: true)

    @Test("existing checkout is always admissible")
    func existingCheckout() {
        #expect(SessionSourceControlSelection.existing.isAdmissible(for: nil))
    }

    @Test("new worktrees require a repository and branch")
    func worktreeRequirements() {
        let missingBranch = SessionSourceControlSelection(
            mode: .newBranchWorktree,
            branch: nil,
            base: nil
        )
        #expect(!missingBranch.isAdmissible(for: repository))
        #expect(!missingBranch.isAdmissible(for: nil))

        let clean = SessionSourceControlSelection(
            mode: .newBranchWorktree,
            branch: "feature/tron",
            base: nil
        )
        #expect(clean.isAdmissible(for: repository))
        #expect(!clean.isAdmissible(for: dirtyRepository))
    }

    @Test("a committed base allows worktree creation from a dirty checkout")
    func explicitBase() {
        let selection = SessionSourceControlSelection(
            mode: .newBranchWorktree,
            branch: "feature/tron",
            base: "main"
        )
        #expect(selection.isAdmissible(for: dirtyRepository))
    }
}
