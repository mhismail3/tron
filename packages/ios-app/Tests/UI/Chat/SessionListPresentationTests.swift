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
        var expansion = SessionListWorkspaceExpansion()

        XCTAssertTrue(expansion.isExpanded("workspace"))
        XCTAssertTrue(expansion.isExpanded("tron"))

        expansion.toggle("workspace")

        XCTAssertFalse(expansion.isExpanded("workspace"))
        XCTAssertTrue(expansion.isExpanded("tron"))

        expansion.toggle("workspace")

        XCTAssertTrue(expansion.isExpanded("workspace"))
    }

    func testListLayoutAlignsHeaderAndSessionColumns() {
        XCTAssertEqual(SessionListLayout.headerInsets.leading, 0)
        XCTAssertEqual(SessionListLayout.headerInsets.trailing, 0)
        XCTAssertEqual(SessionListLayout.rowInsets.leading, SessionListLayout.rowContainerHorizontalInset)
        XCTAssertEqual(SessionListLayout.rowInsets.trailing, SessionListLayout.rowContainerHorizontalInset)
        XCTAssertEqual(SessionListLayout.rowInsets.top, 2)
        XCTAssertEqual(SessionListLayout.rowInsets.bottom, 2)
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
