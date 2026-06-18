import XCTest
@testable import TronMobile

@MainActor
final class SessionDashboardPresentationTests: XCTestCase {
    func testDashboardGroupsSessionsByWorkspaceInExistingOrder() {
        let sessions = [
            makeSession(id: "a", workingDirectory: "/tmp/tron-fixtures/Workspace", title: "A"),
            makeSession(id: "b", workingDirectory: "/tmp/tron-fixtures/Tron", title: "B"),
            makeSession(id: "c", workingDirectory: "/tmp/tron-fixtures/Workspace", title: "C")
        ]

        let groups = SessionDashboardWorkspaceGroup.groups(from: sessions)

        XCTAssertEqual(groups.map(\.name), ["Workspace", "Tron"])
        XCTAssertEqual(groups[0].sessions.map(\.id), ["a", "c"])
        XCTAssertEqual(groups[1].sessions.map(\.id), ["b"])
    }

    func testDashboardTitlePrefersTitleThenPromptThenNewSession() {
        XCTAssertEqual(
            makeSession(id: "title", title: "Implement runtime changes").dashboardTitle,
            "Implement runtime changes"
        )
        XCTAssertEqual(
            makeSession(id: "prompt", title: "Chat", lastUserPrompt: "Review chat composer and commit").dashboardTitle,
            "Review chat composer and commit"
        )
        XCTAssertEqual(
            makeSession(id: "workspace", workingDirectory: "/tmp/tron-fixtures/Project", title: nil).dashboardTitle,
            "New Session"
        )
        XCTAssertEqual(
            makeSession(id: "empty", workingDirectory: "", title: nil).dashboardTitle,
            "New Session"
        )
    }

    func testDashboardStatusPrioritizesDeletingProcessingForkIdle() {
        var deleting = makeSession(id: "deleting", isProcessing: true, isFork: true)
        deleting.isDeleting = true

        XCTAssertEqual(SessionDashboardStatus(session: deleting), .deleting)
        XCTAssertEqual(SessionDashboardStatus(session: makeSession(id: "processing", isProcessing: true, isFork: true)), .processing)
        XCTAssertEqual(SessionDashboardStatus(session: makeSession(id: "fork", isFork: true)), .forked)
        XCTAssertEqual(SessionDashboardStatus(session: makeSession(id: "idle")), .idle)
    }

    func testWorkspaceExpansionTogglesGroupsIndependently() {
        var expansion = SessionDashboardWorkspaceExpansion()

        XCTAssertTrue(expansion.isExpanded("workspace"))
        XCTAssertTrue(expansion.isExpanded("tron"))

        expansion.toggle("workspace")

        XCTAssertFalse(expansion.isExpanded("workspace"))
        XCTAssertTrue(expansion.isExpanded("tron"))

        expansion.toggle("workspace")

        XCTAssertTrue(expansion.isExpanded("workspace"))
    }

    func testDashboardLayoutAlignsHeaderAndSessionColumns() {
        XCTAssertEqual(SessionDashboardLayout.headerInsets.leading, 0)
        XCTAssertEqual(SessionDashboardLayout.headerInsets.trailing, 0)
        XCTAssertEqual(SessionDashboardLayout.rowInsets.leading, SessionDashboardLayout.rowContainerHorizontalInset)
        XCTAssertEqual(SessionDashboardLayout.rowInsets.trailing, SessionDashboardLayout.rowContainerHorizontalInset)
        XCTAssertEqual(SessionDashboardLayout.rowInsets.top, 2)
        XCTAssertEqual(SessionDashboardLayout.rowInsets.bottom, 2)
        XCTAssertEqual(SessionDashboardLayout.outerHorizontalPadding, 24)
        XCTAssertEqual(SessionDashboardLayout.rowContainerHorizontalInset, 16)
        XCTAssertEqual(SessionDashboardLayout.rowContentHorizontalPadding, 12)
        XCTAssertEqual(SessionDashboardLayout.iconColumnWidth, 18)
        XCTAssertEqual(SessionDashboardLayout.iconTextSpacing, 8)
        XCTAssertGreaterThan(SessionDashboardLayout.headerTitleSize, SessionDashboardLayout.rowTitleSize)
        XCTAssertEqual(SessionDashboardLayout.headerTitleSize, TronTypography.sizeBodyLG)
        XCTAssertEqual(SessionDashboardLayout.rowTitleSize, TronTypography.sizeBody3)
        XCTAssertEqual(SessionDashboardLayout.minimumRowHeight, 38)
        XCTAssertEqual(SessionDashboardLayout.listTopContentMargin, 38)
        XCTAssertEqual(SessionDashboardLayout.listBottomContentMargin, 92)
        XCTAssertEqual(SessionDashboardLayout.floatingButtonSize, 56)
        XCTAssertEqual(SessionDashboardLayout.rowContainerCornerRadius, 12)
        XCTAssertEqual(SessionDashboardLayout.rowPressedScale, 0.988)
        XCTAssertEqual(SessionDashboardLayout.rowPressedBrightness, 0.035)
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
}
