import XCTest
import SwiftUI
@testable import TronMobile

/// Source-level guards for iPad-specific Settings page layouts.
///
/// iPad landscape forms keep critical settings visible without relying on deep
/// scrolling in compact floating sheets.
final class AgentSettingsPageLayoutTests: XCTestCase {

    func testSettingsAdaptiveLayoutDetectsIPadLandscape() throws {
        let content = try source(pathComponents: ["Sources", "UI", "Views", "Settings", "SettingsSupport.swift"])

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
        XCTAssertNotNil(landscapeContent.range(of: "quickSessionCard"))
        XCTAssertFalse(landscapeContent.contains("message" + "Queue" + "Card"))
        XCTAssertFalse(
            landscapeContent.contains("protected" + "Branches" + "Section"),
            "Protected branch policy is not a primitive settings card"
        )
    }

    func testAgentSettingsDeletesProductPolicySections() throws {
        let content = try settingsPageSource(named: "AgentSettingsPage.swift")

        XCTAssertTrue(content.contains("quickSessionCard"))
        XCTAssertFalse(content.contains("message" + "Queue" + "Card"))
        XCTAssertFalse(content.contains("autonomy" + "Section"))
        XCTAssertFalse(content.contains("guard" + "rails" + "Section"))
        XCTAssertFalse(content.contains("hooks" + "Section"))
        XCTAssertFalse(content.contains("protected" + "Branches" + "Section"))
        XCTAssertFalse(content.contains("approval" + "PromptMode"))
    }

    @MainActor
    func testAgentSettingsPrimitiveCardsRenderForVisualQA() throws {
        let settingsState = SettingsState()
        settingsState.isLoaded = true
        settingsState.quickSessionWorkspace = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("tron-visual-qa")
            .path
        settingsState.defaultModel = "gpt-5.5"
        let content = AgentSettingsPage(
            settingsState: settingsState,
            selectedModelDisplayName: "GPT-5.5",
            updateServerSetting: { _ in }
        )
        .environment(\.dependencies, DependencyContainer())
        .frame(width: 430, height: 1_320)
        .background(Color(uiColor: .systemBackground))

        let windowScene = try XCTUnwrap(
            UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        )
        let window = UIWindow(windowScene: windowScene)
        window.frame = CGRect(x: 0, y: 0, width: 430, height: 1_320)
        let controller = UIHostingController(rootView: content)
        window.rootViewController = controller
        window.makeKeyAndVisible()
        controller.view.frame = window.bounds
        controller.view.setNeedsLayout()
        controller.view.layoutIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))

        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 2
        let image = UIGraphicsImageRenderer(bounds: controller.view.bounds, format: format).image { _ in
            controller.view.drawHierarchy(in: controller.view.bounds, afterScreenUpdates: true)
        }
        XCTAssertGreaterThan(image.size.width, 400)
        XCTAssertGreaterThan(image.size.height, 1_200)

        let documentsURL = try XCTUnwrap(
            FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
        )
        let artifactRoot = ProcessInfo.processInfo.environment["TRON_VISUAL_ARTIFACT_DIR"]
            .map(URL.init(fileURLWithPath:))
            ?? documentsURL.appendingPathComponent("tron-visual-artifacts")
        let outputURL = artifactRoot.appendingPathComponent("agent-settings-primitive-render.png")
        try FileManager.default.createDirectory(
            at: outputURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try XCTUnwrap(image.pngData()).write(to: outputURL)
        print("TRON_VISUAL_ARTIFACT_PATH=\(outputURL.path)")
        add(XCTAttachment(contentsOfFile: outputURL))
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
        let evidenceIndex = try XCTUnwrap(
            landscapeContent.range(of: "runtimeEvidenceSection", range: pairedIndex..<landscapeContent.endIndex)?.lowerBound
        )

        XCTAssertLessThan(pairedIndex, evidenceIndex)
        XCTAssertTrue(
            landscapeContent.contains("serverBackedContent"),
            "Server landscape should render the retained server-backed runtime evidence content in the right column"
        )
        XCTAssertFalse(
            landscapeContent.contains("updates" + "Section"),
            "Server landscape should not retain a fixed update-check section"
        )
        XCTAssertTrue(
            landscapeContent.contains("serverBackedSettingsStatusSection(status)"),
            "Server landscape layout should still expose the explicit unavailable/loading status card"
        )
        XCTAssertTrue(
            landscapeContent.contains(".fixedSize(horizontal: false, vertical: true)"),
            "Compact left-column server sections should not stretch to the diagnostics column height"
        )
        XCTAssertFalse(
            landscapeContent.contains("trans" + "cription" + "Section"),
            "Server settings must not retain deleted media sidecar controls"
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
        try source(pathComponents: ["Sources", "UI", "Views", "Settings", "Pages", fileName])
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
