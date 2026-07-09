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
        XCTAssertTrue(
            list.contains(
                ".frame(maxWidth: .infinity, minHeight: SessionListLayout.expansionControlMinimumHeight)"
            )
        )
        XCTAssertTrue(list.contains(".buttonStyle(.plain)\n        .contentShape(Rectangle())"))
        XCTAssertTrue(list.contains(#".accessibilityLabel("\(title) sessions in \(projectName)")"#))
        XCTAssertTrue(list.contains(".accessibilityHint(hint)"))
    }
}
