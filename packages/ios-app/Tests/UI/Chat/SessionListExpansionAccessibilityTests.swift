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

        XCTAssertTrue(sidebar.contains("sessionExpansion.visibleSessions(in: group)"))
        XCTAssertTrue(sidebar.contains("SessionListExpansionControls("))
        XCTAssertTrue(sidebar.contains("sessionExpansion.revealMore("))
        XCTAssertTrue(sidebar.contains("sessionExpansion.showLess(groupId: group.id)"))
        XCTAssertTrue(list.contains("static let pageSize = 10"))
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
                ".padding(.horizontal, SessionListLayout.expansionControlHorizontalPadding)"
            )
        )
        XCTAssertTrue(list.contains(".buttonStyle(.plain)\n        .contentShape(Rectangle())"))
        XCTAssertTrue(list.contains(#".accessibilityLabel("\(title) sessions in \(projectName)")"#))
        XCTAssertTrue(list.contains(".accessibilityHint(hint)"))
    }
}
