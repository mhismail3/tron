import SwiftUI
import XCTest
@testable import TronMobile

@MainActor
final class SessionTitleIconsTests: XCTestCase {

    // Guard: canonical fork tint is coral. Prevents regressions that silently
    // reintroduce purple.
    func test_forkColor_isCoral() {
        XCTAssertEqual(SessionTitleIcons.forkColor, Color.tronCoral)
    }

    func test_worktreeColor_isAmber() {
        XCTAssertEqual(SessionTitleIcons.worktreeColor, Color.tronAmber)
    }


    private func makeInfo(
        isolated: Bool = true,
        branch: String = "session/a",
        baseBranch: String? = "main",
        hasUncommittedChanges: Bool? = false
    ) -> WorktreeInfo {
        WorktreeInfo(
            isolated: isolated,
            branch: branch,
            baseCommit: "abc",
            path: "/tmp",
            baseBranch: baseBranch,
            repoRoot: nil,
            hasUncommittedChanges: hasUncommittedChanges,
            commitCount: 0,
            isMerged: false
        )
    }

    // T39 — no icons when nothing applies
    func test_icons_none_whenNeitherForkNorOffBase() {
        let icons = SessionTitleIcons.iconsShown(isFork: false, worktree: nil)
        XCTAssertEqual(icons, [])
    }

    // T40 — fork only
    func test_icons_forkOnly() {
        let icons = SessionTitleIcons.iconsShown(isFork: true, worktree: nil)
        XCTAssertEqual(icons, [.fork])
    }

    // T41 — worktree off base, no uncommitted dot
    func test_icons_worktreeOffBase_noDot() {
        let w = makeInfo(branch: "session/x", baseBranch: "main", hasUncommittedChanges: false)
        let icons = SessionTitleIcons.iconsShown(isFork: false, worktree: w)
        XCTAssertEqual(icons, [.branch])
    }

    // T42 — worktree off base + uncommitted
    func test_icons_worktreeOffBase_withDot() {
        let w = makeInfo(branch: "session/x", baseBranch: "main", hasUncommittedChanges: true)
        let icons = SessionTitleIcons.iconsShown(isFork: false, worktree: w)
        XCTAssertEqual(icons, [.branch, .dot])
    }

    // T43 — fork + worktree off base
    func test_icons_forkAndWorktreeOffBase() {
        let w = makeInfo(branch: "session/x", baseBranch: "main", hasUncommittedChanges: false)
        let icons = SessionTitleIcons.iconsShown(isFork: true, worktree: w)
        XCTAssertEqual(icons, [.fork, .branch])
    }

    // T44 — clean worktree on base (no icons from worktree)
    func test_icons_cleanWorktreeOnBase_suppressed() {
        let clean = makeInfo(branch: "main", baseBranch: "main", hasUncommittedChanges: false)
        let icons = SessionTitleIcons.iconsShown(isFork: false, worktree: clean)
        XCTAssertEqual(icons, [])
    }

    func test_icons_dirtyWorktreeOnBase_showsDot() {
        let w = makeInfo(branch: "main", baseBranch: "main", hasUncommittedChanges: true)
        let icons = SessionTitleIcons.iconsShown(isFork: false, worktree: w)
        XCTAssertEqual(icons, [.dot])
    }

    // Non-isolated (passthrough) → also suppressed
    func test_icons_nonIsolated_suppressed() {
        let w = makeInfo(isolated: false, branch: "main", baseBranch: nil, hasUncommittedChanges: false)
        let icons = SessionTitleIcons.iconsShown(isFork: false, worktree: w)
        XCTAssertEqual(icons, [])
    }

    func test_icons_dirtyNonIsolatedWorktree_suppressed() {
        let w = makeInfo(isolated: false, branch: "main", baseBranch: nil, hasUncommittedChanges: true)
        let icons = SessionTitleIcons.iconsShown(isFork: false, worktree: w)
        XCTAssertEqual(icons, [])
    }

    func test_accessibilityDescriptors_nonIsolatedWorktree_suppressed() {
        let w = makeInfo(isolated: false, branch: "main", baseBranch: nil, hasUncommittedChanges: true)
        XCTAssertEqual(
            SessionTitleIcons.accessibilityDescriptors(isFork: false, worktree: w),
            []
        )
    }

    func test_accessibilityDescriptors_matchVisibleMetadata() {
        let w = makeInfo(branch: "session/feature", baseBranch: "main", hasUncommittedChanges: true)
        XCTAssertEqual(
            SessionTitleIcons.accessibilityDescriptors(isFork: true, worktree: w),
            ["forked", "branch feature", "dirty worktree"]
        )
    }
}
