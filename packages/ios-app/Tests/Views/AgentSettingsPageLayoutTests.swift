import XCTest

/// Source-level guards for iPad-specific Settings page layouts.
///
/// iPad landscape forms keep critical settings visible without relying on deep
/// scrolling in compact floating sheets.
final class AgentSettingsPageLayoutTests: XCTestCase {

    func testSettingsAdaptiveLayoutDetectsIPadLandscape() throws {
        let content = try source(pathComponents: ["Sources", "Views", "Settings", "SettingsSupport.swift"])

        XCTAssertTrue(
            content.contains("enum SettingsAdaptiveLayout"),
            "Settings pages should share a single iPad landscape detector"
        )
        XCTAssertTrue(
            content.contains("UIDevice.current.userInterfaceIdiom == .pad"),
            "The landscape branch must stay iPad-only"
        )
        XCTAssertTrue(
            content.contains("return screenBounds.width > screenBounds.height"),
            "The wide layout should be tied to landscape bounds"
        )
    }

    func testAgentSettingsUsesIPadLandscapeTwoColumnLayout() throws {
        let content = try settingsPageSource(named: "AgentSettingsPage.swift")

        XCTAssertTrue(
            content.contains("SettingsAdaptiveLayout.usesIPadLandscapeLayout"),
            "Agent settings should use the shared iPad-landscape branch"
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

    func testConnectionSettingsUsesIPadLandscapeColumns() throws {
        let content = try settingsPageSource(named: "ConnectionSettingsPage.swift")

        XCTAssertTrue(
            content.contains("SettingsAdaptiveLayout.usesIPadLandscapeLayout"),
            "Server settings should use the shared iPad-landscape branch"
        )
        XCTAssertTrue(
            content.contains("private var landscapeContent: some View"),
            "Server settings needs a dedicated landscape projection"
        )

        let landscapeStart = try XCTUnwrap(
            content.range(of: "private var landscapeContent: some View")?.lowerBound
        )
        let landscapeContent = content[landscapeStart..<content.endIndex]
        let pairedIndex = try XCTUnwrap(landscapeContent.range(of: "pairedServersSection")?.lowerBound)
        let transcriptionIndex = try XCTUnwrap(
            landscapeContent.range(of: "transcriptionSection", range: pairedIndex..<landscapeContent.endIndex)?.lowerBound
        )
        let diagnosticsIndex = try XCTUnwrap(
            landscapeContent.range(of: "diagnosticsSection", range: transcriptionIndex..<landscapeContent.endIndex)?.lowerBound
        )
        let updatesIndex = try XCTUnwrap(landscapeContent.range(of: "updatesSection")?.lowerBound)

        XCTAssertLessThan(pairedIndex, transcriptionIndex)
        XCTAssertLessThan(transcriptionIndex, diagnosticsIndex)
        XCTAssertTrue(
            landscapeContent.contains("if settingsState.isLoaded && !activeServerUnavailable {\n                        updatesSection\n                    }"),
            "Updates should stay in the right landscape column without also stacking diagnostics below it"
        )
        XCTAssertFalse(
            landscapeContent.contains("updatesSection\n                        diagnosticsSection"),
            "Server landscape should not stack Updates and Diagnostics in the same long column"
        )
        XCTAssertTrue(
            landscapeContent.contains("serverBackedSettingsLoadingOrUnavailableSection"),
            "Server landscape layout should still expose unavailable/loading states"
        )
        XCTAssertTrue(
            landscapeContent.contains(".fixedSize(horizontal: false, vertical: true)"),
            "Compact left-column server sections should not stretch to the diagnostics column height"
        )
    }

    func testProvidersSettingsUsesIPadLandscapeColumns() throws {
        let content = try settingsPageSource(named: "ProvidersSettingsPage.swift")

        XCTAssertTrue(
            content.contains("SettingsAdaptiveLayout.usesIPadLandscapeLayout"),
            "Providers settings should use the shared iPad-landscape branch"
        )
        XCTAssertTrue(
            content.contains("private var landscapeContent: some View"),
            "Providers settings needs a dedicated landscape projection"
        )
        XCTAssertTrue(
            content.contains("ProviderInfo.modelProviders.prefix(3)"),
            "The left providers column should hold the first configured model providers"
        )
        XCTAssertTrue(
            content.contains("ProviderInfo.modelProviders.dropFirst(3)"),
            "The right providers column should keep remaining providers and services visible"
        )
        XCTAssertTrue(
            content.contains("ForEach(ProviderInfo.services)"),
            "Services must stay visible in the Providers landscape projection"
        )
    }

    private func settingsPageSource(named fileName: String) throws -> String {
        try source(pathComponents: ["Sources", "Views", "Settings", "Pages", fileName])
    }

    private func source(pathComponents: [String]) throws -> String {
        let fileURL = URL(fileURLWithPath: #filePath)
        var url = fileURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        for component in pathComponents {
            url.appendPathComponent(component)
        }
        return try String(contentsOf: url, encoding: .utf8)
    }
}
