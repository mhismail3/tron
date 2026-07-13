import XCTest
@testable import TronMobile

@MainActor
final class SessionListPresentationTests: XCTestCase {
    func testListGroupsSessionsByWorkspaceInExistingOrder() {
        let sessions = [
            makeSession(id: "a", workingDirectory: "/tmp/tron-fixtures/Workspace", title: "A"),
            makeSession(id: "b", workingDirectory: "/tmp/tron-fixtures/Tron", title: "B"),
            makeSession(id: "c", workingDirectory: "/tmp/tron-fixtures/Workspace", title: "C")
        ]

        let groups = SessionListWorkspaceGroup.groups(from: sessions)

        XCTAssertEqual(groups.map(\.name), ["Workspace", "Tron"])
        XCTAssertEqual(groups[0].sessions.map(\.id), ["a", "c"])
        XCTAssertEqual(groups[1].sessions.map(\.id), ["b"])
    }

    func testListTitlePrefersTitleThenPromptThenNewSession() {
        XCTAssertEqual(
            makeSession(id: "title", title: "Implement runtime changes").listTitle,
            "Implement runtime changes"
        )
        XCTAssertEqual(
            makeSession(id: "prompt", title: "Chat", lastUserPrompt: "Review chat composer and commit").listTitle,
            "Review chat composer and commit"
        )
        XCTAssertEqual(
            makeSession(id: "workspace", workingDirectory: "/tmp/tron-fixtures/Project", title: nil).listTitle,
            "New Session"
        )
        XCTAssertEqual(
            makeSession(id: "empty", workingDirectory: "", title: nil).listTitle,
            "New Session"
        )
    }

    func testListStatusPrioritizesDeletingProcessingForkIdle() {
        var deleting = makeSession(id: "deleting", isProcessing: true, isFork: true)
        deleting.isDeleting = true

        XCTAssertEqual(SessionListStatus(session: deleting), .deleting)
        XCTAssertEqual(SessionListStatus(session: makeSession(id: "processing", isProcessing: true, isFork: true)), .processing)
        XCTAssertEqual(SessionListStatus(session: makeSession(id: "fork", isFork: true)), .forked)
        XCTAssertEqual(SessionListStatus(session: makeSession(id: "idle")), .idle)
    }

    func testWorkspaceExpansionTogglesGroupsIndependently() {
        var disclosure = SessionListWorkspaceDisclosure()

        XCTAssertTrue(disclosure.isExpanded("workspace"))
        XCTAssertTrue(disclosure.isExpanded("tron"))

        let collapse = disclosure.beginToggle("workspace")

        XCTAssertEqual(collapse.direction, .collapse)
        XCTAssertFalse(disclosure.isExpanded("workspace"))
        XCTAssertTrue(disclosure.shouldRenderRows("workspace"))
        XCTAssertFalse(disclosure.areRowsVisible("workspace"))
        XCTAssertTrue(disclosure.isExpanded("tron"))

        XCTAssertTrue(disclosure.complete(collapse))
        XCTAssertFalse(disclosure.shouldRenderRows("workspace"))

        let expand = disclosure.beginToggle("workspace")

        XCTAssertEqual(expand.direction, .expand)
        XCTAssertTrue(disclosure.isExpanded("workspace"))
        XCTAssertTrue(disclosure.shouldRenderRows("workspace"))
        XCTAssertFalse(disclosure.areRowsVisible("workspace"))
        XCTAssertTrue(disclosure.complete(expand))
        XCTAssertTrue(disclosure.areRowsVisible("workspace"))
    }

    func testWorkspaceDisclosureIgnoresStaleCompletionAfterRapidReversal() {
        var disclosure = SessionListWorkspaceDisclosure()
        let collapse = disclosure.beginToggle("workspace")
        let expand = disclosure.beginToggle("workspace")

        XCTAssertFalse(disclosure.complete(collapse))
        XCTAssertTrue(disclosure.isExpanded("workspace"))
        XCTAssertTrue(disclosure.shouldRenderRows("workspace"))
        XCTAssertFalse(disclosure.areRowsVisible("workspace"))

        XCTAssertTrue(disclosure.complete(expand))
        XCTAssertTrue(disclosure.areRowsVisible("workspace"))
    }

    func testWorkspaceDisclosureReconcilesRemovedGroups() {
        var disclosure = SessionListWorkspaceDisclosure()
        let collapse = disclosure.beginToggle("workspace")
        XCTAssertTrue(disclosure.complete(collapse))
        XCTAssertFalse(disclosure.shouldRenderRows("workspace"))

        disclosure.reconcile(groupIds: ["tron"])

        XCTAssertTrue(disclosure.isExpanded("workspace"))
        XCTAssertTrue(disclosure.shouldRenderRows("workspace"))
        XCTAssertTrue(disclosure.areRowsVisible("workspace"))
    }

    func testDisclosureStaggerIsTopDownOnExpandAndBottomUpOnCollapse() {
        let itemCount = 10

        XCTAssertEqual(
            SessionListLayout.disclosureRowDelay(index: 0, itemCount: itemCount, isVisible: true),
            0,
            accuracy: 0.000_001
        )
        XCTAssertEqual(
            SessionListLayout.disclosureRowDelay(
                index: itemCount - 1,
                itemCount: itemCount,
                isVisible: true
            ),
            SessionListLayout.disclosureMaximumStaggerDuration,
            accuracy: 0.000_001
        )
        XCTAssertEqual(
            SessionListLayout.disclosureRowDelay(index: 0, itemCount: itemCount, isVisible: false),
            SessionListLayout.disclosureMaximumStaggerDuration,
            accuracy: 0.000_001
        )
        XCTAssertEqual(
            SessionListLayout.disclosureRowDelay(
                index: itemCount - 1,
                itemCount: itemCount,
                isVisible: false
            ),
            0,
            accuracy: 0.000_001
        )
        XCTAssertEqual(
            SessionListLayout.disclosureCollapseDelay(itemCount: itemCount),
            .milliseconds(190)
        )
        XCTAssertLessThanOrEqual(SessionListLayout.disclosureMaximumStaggerDuration, 0.06)
    }

    func testEachProjectShowsExactlyTenSessionsByDefault() {
        let groups = SessionListWorkspaceGroup.groups(from: makeSessions(count: 24, project: "Workspace"))
        let expansion = SessionListSessionExpansion()

        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(expansion.visibleSessions(in: groups[0]).count, 10)
        XCTAssertEqual(expansion.visibleSessions(in: groups[0]).map(\.id), (0..<10).map { "Workspace-\($0)" })
        XCTAssertTrue(expansion.canViewMore(groupId: groups[0].id, totalCount: 24))
        XCTAssertFalse(expansion.canViewLess(groupId: groups[0].id, totalCount: 24))
    }

    func testViewMoreProgressesByTenAndViewLessReturnsToLatestTen() {
        let group = SessionListWorkspaceGroup.groups(from: makeSessions(count: 25, project: "Workspace"))[0]
        var expansion = SessionListSessionExpansion()

        expansion.revealMore(groupId: group.id, totalCount: group.sessions.count)
        XCTAssertEqual(expansion.visibleSessions(in: group).count, 20)
        XCTAssertTrue(expansion.canViewMore(groupId: group.id, totalCount: 25))
        XCTAssertTrue(expansion.canViewLess(groupId: group.id, totalCount: 25))

        expansion.revealMore(groupId: group.id, totalCount: group.sessions.count)
        XCTAssertEqual(expansion.visibleSessions(in: group).count, 25)
        XCTAssertFalse(expansion.canViewMore(groupId: group.id, totalCount: 25))
        XCTAssertTrue(expansion.canViewLess(groupId: group.id, totalCount: 25))

        expansion.showLess(groupId: group.id)
        XCTAssertEqual(expansion.visibleSessions(in: group).count, 10)
        XCTAssertTrue(expansion.canViewMore(groupId: group.id, totalCount: 25))
        XCTAssertFalse(expansion.canViewLess(groupId: group.id, totalCount: 25))
    }

    func testPaginationStagesNewRowsThenHidesOnlyExcessRows() throws {
        let groupId = "workspace"
        var expansion = SessionListSessionExpansion()

        let reveal = try XCTUnwrap(expansion.beginRevealMore(groupId: groupId, totalCount: 25))
        XCTAssertEqual(reveal.direction, .reveal)
        XCTAssertEqual(reveal.stableCount, 10)
        XCTAssertEqual(reveal.renderedCount, 20)
        XCTAssertEqual(reveal.affectedCount, 10)
        XCTAssertEqual(expansion.visibleCount(for: groupId, totalCount: 25), 20)
        XCTAssertTrue(expansion.isRowVisible(groupId: groupId, index: 9))
        XCTAssertFalse(expansion.isRowVisible(groupId: groupId, index: 10))
        XCTAssertTrue(expansion.isTransitioning(groupId: groupId))

        XCTAssertTrue(expansion.beginRevealRows(reveal))
        XCTAssertTrue(expansion.isRowVisible(groupId: groupId, index: 10))
        XCTAssertTrue(expansion.isRowVisible(groupId: groupId, index: 19))
        XCTAssertTrue(expansion.finish(reveal))
        XCTAssertFalse(expansion.isTransitioning(groupId: groupId))

        let hide = try XCTUnwrap(expansion.beginShowLess(groupId: groupId, totalCount: 25))
        XCTAssertEqual(hide.direction, .hide)
        XCTAssertEqual(hide.stableCount, 10)
        XCTAssertTrue(expansion.isRowVisible(groupId: groupId, index: 9))
        XCTAssertFalse(expansion.isRowVisible(groupId: groupId, index: 10))
        XCTAssertFalse(expansion.isRowVisible(groupId: groupId, index: 19))
        XCTAssertEqual(expansion.visibleCount(for: groupId, totalCount: 25), 20)

        XCTAssertTrue(expansion.finish(hide))
        XCTAssertEqual(expansion.visibleCount(for: groupId, totalCount: 25), 10)
        XCTAssertFalse(expansion.isTransitioning(groupId: groupId))
    }

    func testPaginationRejectsConcurrentAndStaleTransitions() throws {
        let groupId = "workspace"
        var expansion = SessionListSessionExpansion()
        let reveal = try XCTUnwrap(expansion.beginRevealMore(groupId: groupId, totalCount: 25))

        XCTAssertNil(expansion.beginRevealMore(groupId: groupId, totalCount: 25))
        XCTAssertNil(expansion.beginShowLess(groupId: groupId, totalCount: 25))
        XCTAssertTrue(expansion.beginRevealRows(reveal))
        XCTAssertTrue(expansion.finish(reveal))
        XCTAssertFalse(expansion.beginRevealRows(reveal))
        XCTAssertFalse(expansion.finish(reveal))
    }

    func testNoExpansionControlAtTenOrFewerSessions() {
        let expansion = SessionListSessionExpansion()

        for count in [0, 1, 10] {
            XCTAssertFalse(expansion.canViewMore(groupId: "workspace", totalCount: count))
            XCTAssertFalse(expansion.canViewLess(groupId: "workspace", totalCount: count))
        }
    }

    func testSessionExpansionIsIndependentAcrossProjects() {
        let groups = SessionListWorkspaceGroup.groups(
            from: makeSessions(count: 22, project: "Workspace") + makeSessions(count: 13, project: "Tron")
        )
        var expansion = SessionListSessionExpansion()

        expansion.revealMore(groupId: groups[0].id, totalCount: groups[0].sessions.count)

        XCTAssertEqual(expansion.visibleSessions(in: groups[0]).count, 20)
        XCTAssertEqual(expansion.visibleSessions(in: groups[1]).count, 10)
        XCTAssertTrue(expansion.canViewLess(groupId: groups[0].id, totalCount: 22))
        XCTAssertFalse(expansion.canViewLess(groupId: groups[1].id, totalCount: 13))
    }

    func testExpansionHandlesRefreshNewArchiveAndProjectCollapsePredictably() {
        var sessions = makeSessions(count: 25, project: "Workspace")
        var group = SessionListWorkspaceGroup.groups(from: sessions)[0]
        var sessionExpansion = SessionListSessionExpansion()
        var workspaceDisclosure = SessionListWorkspaceDisclosure()
        sessionExpansion.revealMore(groupId: group.id, totalCount: group.sessions.count)

        let newSession = makeSession(
            id: "Workspace-new",
            workingDirectory: group.path,
            title: "Newest"
        )
        sessions.insert(newSession, at: 0)
        group = SessionListWorkspaceGroup.groups(from: sessions)[0]
        XCTAssertEqual(sessionExpansion.visibleSessions(in: group).count, 20)
        XCTAssertEqual(sessionExpansion.visibleSessions(in: group).first?.id, "Workspace-new")
        XCTAssertEqual(Set(sessionExpansion.visibleSessions(in: group).map(\.id)).count, 20)

        sessions.removeAll { $0.id == "Workspace-3" }
        group = SessionListWorkspaceGroup.groups(from: sessions)[0]
        XCTAssertEqual(sessionExpansion.visibleSessions(in: group).count, 20)
        XCTAssertEqual(Set(sessionExpansion.visibleSessions(in: group).map(\.id)).count, 20)

        let collapse = workspaceDisclosure.beginToggle(group.id)
        XCTAssertTrue(workspaceDisclosure.complete(collapse))
        XCTAssertFalse(workspaceDisclosure.isExpanded(group.id))
        XCTAssertTrue(sessionExpansion.canViewLess(groupId: group.id, totalCount: group.sessions.count))
        let expand = workspaceDisclosure.beginToggle(group.id)
        XCTAssertTrue(workspaceDisclosure.complete(expand))
        XCTAssertTrue(workspaceDisclosure.isExpanded(group.id))
        XCTAssertEqual(sessionExpansion.visibleSessions(in: group).count, 20)

        sessionExpansion.reconcile(groupCounts: [group.id: 9])
        XCTAssertFalse(sessionExpansion.canViewLess(groupId: group.id, totalCount: 9))
        XCTAssertEqual(sessionExpansion.visibleCount(for: group.id, totalCount: 9), 9)
    }

    func testListLayoutAlignsHeaderAndSessionColumns() {
        XCTAssertEqual(SessionListLayout.headerInsets.leading, 0)
        XCTAssertEqual(SessionListLayout.headerInsets.trailing, 0)
        XCTAssertEqual(SessionListLayout.rowInsets.leading, SessionListLayout.rowContainerHorizontalInset)
        XCTAssertEqual(SessionListLayout.rowInsets.trailing, SessionListLayout.rowContainerHorizontalInset)
        XCTAssertEqual(SessionListLayout.rowInsets.top, 2)
        XCTAssertEqual(SessionListLayout.rowInsets.bottom, 2)
        XCTAssertEqual(SessionListLayout.briefingInsets.leading, SessionListLayout.rowInsets.leading)
        XCTAssertEqual(SessionListLayout.briefingInsets.trailing, SessionListLayout.rowInsets.trailing)
        XCTAssertEqual(SessionListLayout.rowContainerHorizontalInset, 16)
        XCTAssertEqual(SessionListLayout.rowContentHorizontalPadding, 12)
        XCTAssertEqual(
            SessionListLayout.headerLeadingPadding,
            SessionListLayout.rowContainerHorizontalInset + SessionListLayout.rowContentHorizontalPadding
        )
        XCTAssertEqual(SessionListLayout.headerTrailingPadding, SessionListLayout.rowContainerHorizontalInset)
        XCTAssertEqual(
            SessionListLayout.headerLeadingPadding + SessionListLayout.iconColumnWidth + SessionListLayout.iconTextSpacing,
            SessionListLayout.rowInsets.leading + SessionListLayout.rowContentHorizontalPadding + SessionListLayout.iconColumnWidth + SessionListLayout.iconTextSpacing
        )
        XCTAssertEqual(SessionListLayout.iconColumnWidth, 18)
        XCTAssertEqual(SessionListLayout.iconTextSpacing, 8)
        XCTAssertGreaterThan(SessionListLayout.headerTitleSize, SessionListLayout.rowTitleSize)
        XCTAssertEqual(SessionListLayout.headerTitleSize, TronTypography.sizeBodyLG)
        XCTAssertEqual(SessionListLayout.rowTitleSize, TronTypography.sizeBody3)
        XCTAssertEqual(SessionListLayout.minimumRowHeight, 38)
        XCTAssertEqual(SessionListLayout.listTopContentMargin, 38)
        XCTAssertEqual(SessionListLayout.listBottomContentMargin, 92)
        XCTAssertEqual(SessionListLayout.floatingButtonSize, 56)
        XCTAssertEqual(SessionListLayout.rowContainerCornerRadius, 12)
        XCTAssertEqual(SessionListLayout.expansionControlMinimumHeight, 44)
    }

    private func makeSession(
        id: String,
        workingDirectory: String = "/tmp/tron-fixtures/Workspace",
        title: String? = nil,
        lastUserPrompt: String? = nil,
        isProcessing: Bool = false,
        isFork: Bool = false
    ) -> CachedSession {
        CachedSession(
            id: id,
            workspaceId: workingDirectory,
            rootEventId: nil,
            headEventId: nil,
            title: title,
            latestModel: "gpt-5",
            workingDirectory: workingDirectory,
            createdAt: "2026-06-16T00:00:00Z",
            lastActivityAt: "2026-06-16T12:00:00Z",
            archivedAt: nil,
            eventCount: 1,
            messageCount: 1,
            inputTokens: 0,
            outputTokens: 0,
            lastTurnInputTokens: 0,
            cost: 0,
            lastUserPrompt: lastUserPrompt,
            isProcessing: isProcessing,
            isFork: isFork,
            source: title == "Chat" ? "chat" : nil
        )
    }

    private func makeSessions(count: Int, project: String) -> [CachedSession] {
        (0..<count).map { index in
            makeSession(
                id: "\(project)-\(index)",
                workingDirectory: "/tmp/tron-fixtures/\(project)",
                title: "Session \(index)"
            )
        }
    }
}
