import XCTest

/// Source-level guards for iPad-specific Agent settings layout.
///
/// The iPad landscape form keeps destructive and mutating controls visible
/// without relying on deep scrolling in a compact floating sheet.
final class AgentSettingsPageLayoutTests: XCTestCase {

    func testAgentSettingsUsesIPadLandscapeTwoColumnLayout() throws {
        let content = try source(named: "AgentSettingsPage.swift")

        XCTAssertTrue(
            content.contains("private var usesIPadLandscapeLayout: Bool"),
            "Agent settings needs an iPad-landscape branch"
        )
        XCTAssertTrue(
            content.contains("UIDevice.current.userInterfaceIdiom == .pad"),
            "The landscape branch must stay iPad-only"
        )
        XCTAssertTrue(
            content.contains("return screenBounds.width > screenBounds.height"),
            "The wide layout should be tied to landscape bounds"
        )
        XCTAssertTrue(
            content.contains("private var landscapeContent: some View"),
            "Agent settings needs a dedicated landscape projection"
        )

        let landscapeStart = try XCTUnwrap(
            content.range(of: "private var landscapeContent: some View")?.lowerBound
        )
        let landscapeContent = content[landscapeStart..<content.endIndex]
        let protectedIndex = try XCTUnwrap(landscapeContent.range(of: "protectedBranchesSection")?.lowerBound)
        let promptIndex = try XCTUnwrap(
            landscapeContent.range(of: "promptLibrarySection", range: protectedIndex..<landscapeContent.endIndex)?.lowerBound
        )
        XCTAssertLessThan(
            protectedIndex,
            promptIndex,
            "Protected branch controls should stay high in the landscape right column"
        )
    }

    private func source(named fileName: String) throws -> String {
        let fileURL = URL(fileURLWithPath: #filePath)
        var url = fileURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        url.appendPathComponent("Sources")
        url.appendPathComponent("Views")
        url.appendPathComponent("Settings")
        url.appendPathComponent("Pages")
        url.appendPathComponent(fileName)
        return try String(contentsOf: url, encoding: .utf8)
    }
}
