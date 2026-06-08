import XCTest

/// Source-level guards for the shared Settings page container.
///
/// The container is used inside custom iPad form sheets. Its ScrollView must be
/// constrained to the sheet viewport, otherwise long pages can be clipped in
/// landscape without exposing a usable scroll target.
final class SettingsPageContainerTests: XCTestCase {

    func testSettingsContainerConstrainsScrollViewToViewport() throws {
        let content = try source(named: "SettingsPageContainer.swift")

        XCTAssertTrue(
            content.contains("GeometryReader { geometry in"),
            "Settings pages need the sheet viewport size before laying out the ScrollView"
        )
        XCTAssertTrue(
            content.contains("minHeight: geometry.size.height"),
            "The content stack should fill at least the viewport while allowing overflow to scroll"
        )
        XCTAssertTrue(
            content.contains(".frame(width: geometry.size.width, height: geometry.size.height)"),
            "The ScrollView itself must be bounded by the visible sheet viewport"
        )
    }

    private func source(named fileName: String) throws -> String {
        let fileURL = URL(fileURLWithPath: #filePath)
        var url = fileURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        url.appendPathComponent("Sources")
        url.appendPathComponent("UI")
        url.appendPathComponent("Settings")
        url.appendPathComponent("Shell")
        url.appendPathComponent(fileName)
        return try String(contentsOf: url, encoding: .utf8)
    }
}
