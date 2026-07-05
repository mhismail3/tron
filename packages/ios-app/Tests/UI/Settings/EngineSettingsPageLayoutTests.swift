import XCTest
import SwiftUI
@testable import TronMobile

/// Source-level guards for iPad-specific Settings page layouts.
///
/// iPad landscape forms keep critical settings visible without relying on deep
/// scrolling in compact floating sheets.
final class EngineSettingsPageLayoutTests: XCTestCase {

    func testSettingsAdaptiveLayoutDetectsIPadLandscape() throws {
        let content = try source(pathComponents: ["Sources", "UI", "Settings", "Shell", "SettingsSupport.swift"])

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

    func testEngineSettingsUsesIPadLandscapeTwoColumnLayout() throws {
        let content = try settingsPageSource(named: "EngineSettingsPage.swift")

        XCTAssertTrue(
            content.contains("SettingsAdaptiveLayout.usesIPadLandscapeLayout"),
            "Engine settings should use the shared iPad-landscape branch"
        )
        XCTAssertTrue(
            content.contains("private var landscapeContent: some View"),
            "Engine settings needs a dedicated landscape projection"
        )

        let landscapeStart = try XCTUnwrap(
            content.range(of: "private var landscapeContent: some View")?.lowerBound
        )
        let landscapeContent = content[landscapeStart..<content.endIndex]
        XCTAssertNotNil(landscapeContent.range(of: "defaultsSection"))
        XCTAssertNotNil(landscapeContent.range(of: "contextSection"))
        XCTAssertNotNil(landscapeContent.range(of: "evidencePolicySection"))
        XCTAssertFalse(landscapeContent.contains("message" + "Queue" + "Card"))
        XCTAssertFalse(
            landscapeContent.contains("protected" + "Branches" + "Section"),
            "Protected branch policy is not a primitive settings card"
        )
    }

    func testEngineSettingsDeletesProductPolicySections() throws {
        let content = try settingsPageSource(named: "EngineSettingsPage.swift")

        XCTAssertTrue(content.contains("defaultsSection"))
        XCTAssertTrue(content.contains("contextSection"))
        XCTAssertTrue(content.contains("evidencePolicySection"))
        XCTAssertFalse(content.contains("message" + "Queue" + "Card"))
        XCTAssertFalse(content.contains("autonomy" + "Section"))
        XCTAssertFalse(content.contains("guard" + "rails" + "Section"))
        XCTAssertFalse(content.contains("hooks" + "Section"))
        XCTAssertFalse(content.contains("protected" + "Branches" + "Section"))
        XCTAssertFalse(content.contains("approval" + "PromptMode"))
    }

    @MainActor
    func testEngineSettingsPrimitiveCardsRenderForVisualQA() throws {
        let settingsState = SettingsState()
        settingsState.isLoaded = true
        settingsState.quickSessionWorkspace = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("tron-visual-qa")
            .path
        settingsState.defaultModel = "gpt-5.5"
        let content = EngineSettingsPage(
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
        let outputURL = artifactRoot.appendingPathComponent("engine-settings-primitive-render.png")
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
        XCTAssertNotNil(landscapeContent.range(of: "pairedServersSection"))
        XCTAssertNotNil(landscapeContent.range(of: "logsSection"))
        XCTAssertTrue(
            landscapeContent.contains("logsSection"),
            "Server landscape should keep redacted local logs available from the right column"
        )
        XCTAssertFalse(
            landscapeContent.contains("updates" + "Section"),
            "Server landscape should not retain a fixed update-check section"
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

    func testEngineSettingsSurfacesActionableServerOwnedControlsInsideEnginePageOnly() throws {
        let engine = try settingsPageSource(named: "EngineSettingsPage.swift")
        let settingsMain = try source(pathComponents: ["Sources", "UI", "Settings", "Shell", "SettingsView+MainSection.swift"])

        XCTAssertTrue(engine.contains("label: \"Model\""))
        XCTAssertTrue(engine.contains("updateServerSetting(.defaultModel(model.id))"))
        XCTAssertTrue(engine.contains("updateServerSetting(.compactionTriggerTokenThreshold(newValue))"))
        XCTAssertTrue(engine.contains("updateServerSetting(.observabilityLogLevel(newValue))"))
        XCTAssertTrue(settingsMain.contains("settingsOwnershipSection("))
        XCTAssertTrue(settingsMain.contains("title: \"Server-Owned\""))
    }

    func testSettingsMainRowsUseSeparateCardsWithoutChevrons() throws {
        let settingsMain = try source(pathComponents: ["Sources", "UI", "Settings", "Shell", "SettingsView+MainSection.swift"])

        XCTAssertTrue(
            settingsMain.contains("ForEach(destinations, id: \\.self)")
                && settingsMain.contains("SettingsCard {")
                && settingsMain.contains("mainSettingsDestinationRow(destination)"),
            "Server-Owned and This iPhone rows should render as separate SettingsCard containers"
        )
        XCTAssertTrue(
            settingsMain.contains("ForEach(SettingsDangerZoneAction.order, id: \\.self)")
                && settingsMain.contains("SettingsCard(accent: .tronError)"),
            "Maintenance actions should render as separate danger cards rather than one divided table"
        )
        XCTAssertFalse(
            settingsMain.contains("SettingsRowDivider()"),
            "Settings main rows should not use internal dividers between entries"
        )
        XCTAssertFalse(
            settingsMain.contains("chevron.right"),
            "Settings main rows should not show chevrons; the whole card remains the tappable affordance"
        )
    }

    func testSettingsFooterStaysInSheetContentFlow() throws {
        let settingsView = try source(pathComponents: ["Sources", "UI", "Settings", "Shell", "SettingsView.swift"])
        let pageContainer = try source(pathComponents: ["Sources", "UI", "Settings", "Shell", "SettingsPageContainer.swift"])
        let settingsMain = try source(pathComponents: ["Sources", "UI", "Settings", "Shell", "SettingsView+MainSection.swift"])
        let footerSupport = try source(pathComponents: ["Sources", "UI", "Settings", "Shell", "SettingsView+FooterSupport.swift"])
        let support = try source(pathComponents: ["Sources", "UI", "Settings", "Shell", "SettingsSupport.swift"])

        XCTAssertTrue(
            settingsView.contains("mainSettingsSection")
                && settingsView.contains("settingsFooterDockView")
                && settingsView.range(of: "mainSettingsSection")!.lowerBound < settingsView.range(of: "settingsFooterDockView")!.lowerBound,
            "The Settings footer should live in the sheet content after actionable rows"
        )
        XCTAssertFalse(
            settingsView.contains(".safeAreaInset(edge: .bottom"),
            "The Settings footer should not be a pinned overlay that can cover Maintenance rows"
        )
        XCTAssertFalse(
            pageContainer.contains("safeAreaInset") || pageContainer.contains("footer:"),
            "SettingsPageContainer should stay a plain scroll container; Settings footer belongs to Settings content"
        )
        XCTAssertTrue(
            settingsMain.contains("var settingsFooterDockView: some View")
                && settingsMain.contains("SettingsFooterBackdrop()"),
            "The inline footer dock should render through the footer support backdrop"
        )
        XCTAssertTrue(
            settingsMain.contains(".frame(height: MainSettingsFooterLayout.dockHeight)"),
            "The inline footer dock should keep a stable touch and visual region"
        )
        XCTAssertTrue(
            footerSupport.contains("struct SettingsFooterBackdrop"),
            "The footer blur/fade should live in reusable footer support, not inline in the main settings list"
        )
        XCTAssertTrue(
            footerSupport.contains(".fill(.thinMaterial)")
                && footerSupport.contains("Color.tronBackground")
                && footerSupport.contains(".mask("),
            "The footer backdrop should use a subtle material fade instead of a heavy masking gradient"
        )
        XCTAssertTrue(
            support.contains("static let dockHeight") && !support.contains("contentBottomClearance"),
            "Footer spacing constants should be centralized with the other Settings layout values"
        )
    }

    private func settingsPageSource(named fileName: String) throws -> String {
        try source(pathComponents: ["Sources", "UI", "Settings", "Pages", fileName])
    }

    private func source(pathComponents: [String]) throws -> String {
        var url = try iosAppRoot()
        for component in pathComponents {
            url.appendPathComponent(component)
        }
        return try String(contentsOf: url, encoding: .utf8)
    }

    private func iosAppRoot() throws -> URL {
        var candidate = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        for _ in 0..<8 {
            if FileManager.default.fileExists(atPath: candidate.appendingPathComponent("project.yml").path) {
                return candidate
            }
            candidate.deleteLastPathComponent()
        }
        throw CocoaError(.fileNoSuchFile)
    }
}
