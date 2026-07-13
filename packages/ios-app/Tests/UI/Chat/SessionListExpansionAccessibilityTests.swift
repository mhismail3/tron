import XCTest
@testable import TronMobile

final class SessionListExpansionAccessibilityTests: XCTestCase {
    func testExpansionControlsUseAccessibleFullContainerButtons() throws {
        let testFile = URL(fileURLWithPath: #filePath)
        let iosRoot = testFile
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let list = try String(
            contentsOf: iosRoot.appendingPathComponent("Sources/UI/Chat/Shell/SessionList.swift"),
            encoding: .utf8
        )
        let sidebar = try String(
            contentsOf: iosRoot.appendingPathComponent("Sources/UI/Chat/Shell/SessionSidebar.swift"),
            encoding: .utf8
        )
        let pagination = try String(
            contentsOf: iosRoot.appendingPathComponent("Sources/UI/Chat/Shell/SessionListPagination.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(sidebar.contains("sessionExpansion.visibleSessions(in: group)"))
        XCTAssertTrue(sidebar.contains("SessionListExpansionControls("))
        XCTAssertTrue(sidebar.contains("beginPaginationReveal(group)"))
        XCTAssertTrue(sidebar.contains("beginPaginationHide(group)"))
        XCTAssertTrue(sidebar.contains("sessionExpansion.beginRevealMore("))
        XCTAssertTrue(sidebar.contains("sessionExpansion.beginShowLess("))
        XCTAssertTrue(sidebar.contains("sessionExpansion.beginRevealRows(transition)"))
        XCTAssertTrue(sidebar.contains("isEnabled: !paginationIsTransitioning"))
        XCTAssertTrue(sidebar.contains("toggleWorkspaceGroup"))
        XCTAssertTrue(sidebar.contains("workspaceDisclosure.beginToggle(groupId)"))
        XCTAssertTrue(sidebar.contains("workspaceDisclosure.complete(transition)"))
        XCTAssertTrue(list.contains("case collapsing"))
        XCTAssertTrue(list.contains("case expanding"))
        XCTAssertTrue(list.contains("disclosureRowAnimation"))
        XCTAssertTrue(list.contains("disclosureCollapseDelay"))
        XCTAssertTrue(list.contains("isVisible ? boundedIndex : boundedCount - boundedIndex - 1"))
        XCTAssertTrue(list.contains("disclosureLayoutDelay"))
        XCTAssertTrue(sidebar.contains("ForEach(Array(visibleSessions.enumerated())"))
        XCTAssertTrue(list.contains(".animation(SessionListLayout.expansionAnimation, value: isExpanded)"))
        XCTAssertTrue(pagination.contains("static let pageSize = 10"))
        XCTAssertTrue(list.contains(#"title: "View more""#))
        XCTAssertTrue(list.contains(#"title: "View less""#))
        let viewMore = try XCTUnwrap(list.range(of: #"title: "View more""#))
        let spacer = try XCTUnwrap(
            list.range(
                of: "Spacer(minLength: SessionListLayout.iconTextSpacing)",
                range: viewMore.upperBound..<list.endIndex
            )
        )
        let viewLess = try XCTUnwrap(
            list.range(of: #"title: "View less""#, range: spacer.upperBound..<list.endIndex)
        )
        XCTAssertLessThan(viewMore.lowerBound, spacer.lowerBound)
        XCTAssertLessThan(spacer.lowerBound, viewLess.lowerBound)
        XCTAssertTrue(
            list.contains(
                ".frame(minHeight: SessionListLayout.expansionControlMinimumHeight)"
            )
        )
        XCTAssertTrue(list.contains(".transition(.opacity)"))
        XCTAssertTrue(list.contains(".frame(maxWidth: .infinity)"))
        XCTAssertTrue(
            list.contains(
                ".padding(.leading, SessionListLayout.expansionControlLeadingPadding)"
            )
        )
        XCTAssertTrue(
            list.contains(
                ".padding(.trailing, SessionListLayout.expansionControlTrailingPadding)"
            )
        )
        XCTAssertTrue(list.contains("static let expansionControlLeadingPadding = rowContentHorizontalPadding"))
        XCTAssertTrue(list.contains("static let expansionControlTrailingPadding = rowContentHorizontalPadding"))
        XCTAssertTrue(list.contains(".buttonStyle(.plain)\n        .contentShape(Rectangle())"))
        XCTAssertTrue(list.contains(".disabled(!isEnabled)"))
        XCTAssertTrue(list.contains(#".accessibilityLabel("\(title) sessions in \(projectName)")"#))
        XCTAssertTrue(list.contains(".accessibilityHint(hint)"))
    }
}
