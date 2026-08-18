import Foundation
import Testing
@testable import TronMobile

@Suite("Dashboard session pagination")
struct SessionListPaginationTests {
    @Test("shows only the latest ten sessions in each workspace by default")
    func defaultsToTenPerWorkspace() {
        let groups = SessionListWorkspaceGroup.groups(from: makeSessions(count: 24, workspace: "Workspace"))
        let expansion = SessionListSessionExpansion()

        #expect(groups.count == 1)
        #expect(expansion.visibleSessions(in: groups[0]).count == 10)
        #expect(expansion.visibleSessions(in: groups[0]).map(\.id) == (0..<10).map { "Workspace-\($0)" })
        #expect(expansion.canViewMore(groupID: groups[0].id, totalCount: 24))
        #expect(!expansion.canViewLess(groupID: groups[0].id, totalCount: 24))
    }

    @Test("show more advances by ten and show less returns to the latest ten")
    func advancesAndCollapses() {
        let group = SessionListWorkspaceGroup.groups(from: makeSessions(count: 25, workspace: "Workspace"))[0]
        var expansion = SessionListSessionExpansion()

        expansion.revealMore(groupID: group.id, totalCount: group.sessions.count)
        #expect(expansion.visibleSessions(in: group).count == 20)
        #expect(expansion.canViewMore(groupID: group.id, totalCount: 25))
        #expect(expansion.canViewLess(groupID: group.id, totalCount: 25))

        expansion.revealMore(groupID: group.id, totalCount: group.sessions.count)
        #expect(expansion.visibleSessions(in: group).count == 25)
        #expect(!expansion.canViewMore(groupID: group.id, totalCount: 25))
        #expect(expansion.canViewLess(groupID: group.id, totalCount: 25))

        expansion.showLess(groupID: group.id)
        #expect(expansion.visibleSessions(in: group).count == 10)
        #expect(expansion.canViewMore(groupID: group.id, totalCount: 25))
        #expect(!expansion.canViewLess(groupID: group.id, totalCount: 25))
    }

    @Test("stages new rows and rejects stale transition completions")
    func stagesAndRejectsStaleCompletions() {
        let groupID = "workspace"
        var expansion = SessionListSessionExpansion()
        let reveal = expansion.beginRevealMore(groupID: groupID, totalCount: 25)
        #expect(reveal != nil)
        guard let reveal else { return }

        #expect(reveal.stableCount == 10)
        #expect(reveal.renderedCount == 20)
        #expect(reveal.affectedCount == 10)
        #expect(!expansion.isRowVisible(groupID: groupID, index: 10))
        #expect(expansion.isTransitioning(groupID: groupID))
        let beganRows = expansion.beginRevealRows(reveal)
        #expect(beganRows)
        #expect(expansion.isRowVisible(groupID: groupID, index: 19))
        let finished = expansion.finish(reveal)
        #expect(finished)
        #expect(!expansion.isTransitioning(groupID: groupID))
        let finishedAgain = expansion.finish(reveal)
        #expect(!finishedAgain)

        let refreshedReveal = expansion.beginRevealMore(groupID: groupID, totalCount: 25)
        #expect(refreshedReveal != nil)
        guard let refreshedReveal else { return }
        expansion.reconcile(groupCounts: [groupID: 25])
        let finishedAfterRefresh = expansion.finish(refreshedReveal)
        #expect(!finishedAfterRefresh)
    }

    @Test("hides only excess rows before committing the smaller page")
    func stagesShowLess() {
        let groupID = "workspace"
        var expansion = SessionListSessionExpansion()
        expansion.revealMore(groupID: groupID, totalCount: 25)
        let hide = expansion.beginShowLess(groupID: groupID, totalCount: 25)
        #expect(hide != nil)
        guard let hide else { return }

        #expect(hide.stableCount == 10)
        #expect(expansion.visibleCount(for: groupID, totalCount: 25) == 20)
        #expect(expansion.isRowVisible(groupID: groupID, index: 9))
        #expect(!expansion.isRowVisible(groupID: groupID, index: 10))
        let finished = expansion.finish(hide)
        #expect(finished)
        #expect(expansion.visibleCount(for: groupID, totalCount: 25) == 10)
    }

    @Test("does not offer expansion controls at ten or fewer sessions")
    func omitsControlsAtPageSize() {
        let expansion = SessionListSessionExpansion()

        for count in [0, 1, 10] {
            #expect(!expansion.canViewMore(groupID: "workspace", totalCount: count))
            #expect(!expansion.canViewLess(groupID: "workspace", totalCount: count))
        }
    }

    @Test("rejects concurrent pagination transitions")
    func rejectsConcurrentTransitions() {
        var expansion = SessionListSessionExpansion()
        let first = expansion.beginRevealMore(groupID: "workspace", totalCount: 25)
        #expect(first != nil)
        let second = expansion.beginRevealMore(groupID: "workspace", totalCount: 25)
        #expect(second == nil)
        let hide = expansion.beginShowLess(groupID: "workspace", totalCount: 25)
        #expect(hide == nil)
    }

    @Test("keeps workspace expansion independent and reconciles refreshes")
    func isolatesWorkspacesAndRefreshes() {
        let groups = SessionListWorkspaceGroup.groups(
            from: makeSessions(count: 22, workspace: "Workspace")
                + makeSessions(count: 13, workspace: "Tron")
        )
        var expansion = SessionListSessionExpansion()
        expansion.revealMore(groupID: groups[0].id, totalCount: groups[0].sessions.count)

        #expect(expansion.visibleSessions(in: groups[0]).count == 20)
        #expect(expansion.visibleSessions(in: groups[1]).count == 10)
        #expect(expansion.canViewLess(groupID: groups[0].id, totalCount: 22))
        #expect(!expansion.canViewLess(groupID: groups[1].id, totalCount: 13))

        expansion.reconcile(groupCounts: [groups[0].id: 9, groups[1].id: 13])
        #expect(expansion.visibleCount(for: groups[0].id, totalCount: 9) == 9)
        #expect(!expansion.canViewLess(groupID: groups[0].id, totalCount: 9))
        #expect(expansion.visibleCount(for: groups[1].id, totalCount: 13) == 10)
    }

    @Test("workspace disclosure ignores stale delayed completions")
    func rejectsStaleWorkspaceCompletions() {
        var disclosure = SessionListWorkspaceDisclosure()
        let collapse = disclosure.beginToggle("workspace")
        let expand = disclosure.beginToggle("workspace")

        let completedCollapse = disclosure.complete(collapse)
        #expect(!completedCollapse)
        #expect(disclosure.isExpanded("workspace"))
        #expect(disclosure.shouldRenderRows("workspace"))
        let completedExpand = disclosure.complete(expand)
        #expect(completedExpand)
        #expect(disclosure.areRowsVisible("workspace"))
    }

    private func makeSessions(count: Int, workspace: String) -> [SessionSummary] {
        (0..<count).map { index in
            SessionSummary(
                id: "\(workspace)-\(index)",
                name: "Session \(index)",
                cwd: "/tmp/\(workspace)",
                parentSessionId: nil,
                createdAt: "2026-01-01T00:00:00Z",
                updatedAt: "2026-01-01T00:00:\(String(format: "%02d", index % 60))Z",
                messageCount: 1,
                firstMessage: "Session \(index)",
                phase: .idle
            )
        }
    }
}
