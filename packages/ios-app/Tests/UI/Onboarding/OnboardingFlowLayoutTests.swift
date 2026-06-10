import XCTest

/// Source-level guards for the onboarding sheet's chrome. The flow is heavily
/// visual, so these tests pin the structural placement that keeps controls from
/// floating over compact sheet content.
final class OnboardingFlowLayoutTests: XCTestCase {

    func testBackAndNextStayInSheetToolbar() throws {
        let content = try source(pathComponents: [
            "Sources",
            "UI",
            "Onboarding",
            "Flow",
            "OnboardingFlowView.swift",
        ])

        XCTAssertTrue(
            content.contains("ToolbarItemGroup(placement: .topBarLeading)"),
            "Back navigation should live in the sheet toolbar leading group"
        )
        XCTAssertTrue(
            content.contains("ToolbarItem(placement: .topBarTrailing)"),
            "Next navigation should live in the sheet toolbar trailing item"
        )
        XCTAssertTrue(
            content.contains("toolbarNavigationButton("),
            "Back/Next should share the toolbar navigation button helper"
        )
        XCTAssertFalse(
            content.contains("OnboardingNavigationControls(state: state)"),
            "Back/Next must not be rendered in the bottom content overlay"
        )
        XCTAssertFalse(
            content.contains("private struct OnboardingNavigationControls"),
            "Footer navigation controls should not be reintroduced"
        )
    }

    private func source(pathComponents: [String]) throws -> String {
        var url = try projectRoot()
        for component in pathComponents {
            url.appendPathComponent(component)
        }
        return try String(contentsOf: url, encoding: .utf8)
    }

    private func projectRoot() throws -> URL {
        let fileURL = URL(fileURLWithPath: #filePath)
        return fileURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}
