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
        XCTAssertNotNil(landscapeContent.range(of: "serversSection"))
        XCTAssertNotNil(landscapeContent.range(of: "defaultsSection"))
        XCTAssertNotNil(landscapeContent.range(of: "contextSection"))
        XCTAssertNil(landscapeContent.range(of: "evidencePolicySection"))
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
        XCTAssertFalse(content.contains("evidencePolicySection"))
        XCTAssertFalse(content.contains("Log level"))
        XCTAssertFalse(content.contains("Verbose days"))
        XCTAssertFalse(content.contains("label: \"Retention\""))
        XCTAssertFalse(content.contains("Storage cap"))
        XCTAssertFalse(content.contains("observabilityLogLevel"))
        XCTAssertFalse(content.contains("observabilityVerboseRetentionDays"))
        XCTAssertFalse(content.contains("storageRetentionEnabled"))
        XCTAssertFalse(content.contains("storageMaxDatabaseMb"))
        XCTAssertFalse(content.contains("message" + "Queue" + "Card"))
        XCTAssertFalse(content.contains("guard" + "rails" + "Section"))
        XCTAssertFalse(content.contains("hooks" + "Section"))
        XCTAssertFalse(content.contains("protected" + "Branches" + "Section"))
        XCTAssertFalse(content.contains("approval" + "PromptMode"))
    }

    @MainActor
    func testEngineSettingsPrimitiveCardsRenderForVisualQA() throws {
        let testState = IsolatedTestState(label: "engine-settings-render")
        testState.registerTeardown(with: self)
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
        .environment(\.dependencies, testState.makeContainer())
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

        let outputURL = try testState.artifactURL(
            named: "engine-settings-primitive-render.png"
        )
        try XCTUnwrap(image.pngData()).write(to: outputURL)
        print("TRON_VISUAL_ARTIFACT_PATH=\(outputURL.path)")
        add(XCTAttachment(contentsOfFile: outputURL))
    }

    func testServerPairingLivesAsFocusedEngineSection() throws {
        let engine = try settingsPageSource(named: "EngineSettingsPage.swift")
        let servers = try settingsPageSource(named: "EngineServersSection.swift")

        XCTAssertTrue(engine.contains("EngineServersSection("))
        XCTAssertTrue(servers.contains("SettingsSectionHeader(title: \"Servers\")"))
        XCTAssertTrue(servers.contains(".fixedSize(horizontal: false, vertical: true)"))
        XCTAssertFalse(servers.contains("SettingsPageContainer"))
        XCTAssertFalse(servers.contains("LogViewer") || servers.contains("Diagnostics"))
    }

    func testProvidersSettingsUsesIPadLandscapeColumns() throws {
        let content = try settingsPageSource(named: "ProvidersSettingsPage.swift")
        let modelRepository = try source(pathComponents: [
            "Sources", "Engine", "Transport", "Clients", "Repositories",
            "Defaults", "DefaultModelRepository.swift",
        ])

        XCTAssertTrue(
            content.contains("SettingsAdaptiveLayout.usesIPadLandscapeLayout"),
            "Providers settings should use the shared iPad-landscape branch"
        )
        XCTAssertTrue(
            content.contains("LazyVGrid(columns: providerColumns"),
            "Provider groups should use a compact adaptive card grid"
        )
        XCTAssertTrue(
            content.contains("ProviderInfo.searchProviders"),
            "Search credentials should be visible alongside model providers"
        )
        XCTAssertTrue(
            content.contains("ProviderModelRefreshKey("),
            "Provider models should refresh from a continuity-aware task"
        )
        XCTAssertTrue(
            content.contains("continuity: dependencies.connectionRepository.continuity"),
            "Provider projections should reconcile after every usable transport epoch"
        )
        XCTAssertTrue(
            content.contains("refreshOllamaModels(force: true)"),
            "Provider reconciliation should verify the current server catalog"
        )
        XCTAssertTrue(
            content.contains("dependencies.modelRepository.invalidateCache()"),
            "Changing the Ollama endpoint must invalidate the prior endpoint catalog"
        )
        XCTAssertTrue(modelRepository.contains("private var refreshTask: Task<[ModelInfo], Error>?"))
        XCTAssertTrue(modelRepository.contains("if let refreshTask"))
        XCTAssertTrue(modelRepository.contains("refreshTask?.cancel()"))
    }

    func testProviderActionsLiveInCompactCredentialCardHeaders() throws {
        let content = try source(pathComponents: [
            "Sources", "UI", "Settings", "Pages", "ModelProviders", "ModelProviderSection.swift",
        ])
        let credentialRow = try source(pathComponents: [
            "Sources", "UI", "Settings", "Pages", "ModelProviders", "ProviderCredentialRow.swift",
        ])
        let ollama = try source(pathComponents: [
            "Sources", "UI", "Settings", "Pages", "ModelProviders", "OllamaProviderSection.swift",
        ])
        let helpers = try source(pathComponents: [
            "Sources", "UI", "Settings", "Pages", "ModelProviders", "ProviderStatusHelpers.swift",
        ])

        XCTAssertTrue(content.contains("ProviderSectionHeader("))
        XCTAssertTrue(content.contains("Menu {"))
        XCTAssertTrue(content.contains("plus.circle.fill"))
        XCTAssertTrue(content.contains("SettingsRowDivider()"))
        XCTAssertTrue(content.contains("ProviderSettingsRowLayout.leadingIconWidth"))
        XCTAssertTrue(content.contains("ProviderSettingsRowLayout.trailingActionWidth"))
        XCTAssertTrue(content.contains("alignment: .trailing"))
        XCTAssertTrue(content.contains("ProviderCircularActionLabel("))
        XCTAssertTrue(credentialRow.contains("ProviderCircularActionLabel("))
        XCTAssertTrue(credentialRow.contains("ProviderSettingsRowLayout.trailingActionWidth"))
        XCTAssertTrue(credentialRow.contains("alignment: .trailing"))
        XCTAssertTrue(ollama.contains("arrow.clockwise.circle.fill"))
        XCTAssertTrue(ollama.contains("ProviderCircularActionLabel("))
        XCTAssertTrue(ollama.contains("isBusy: isRefreshing"))
        XCTAssertTrue(ollama.contains("systemName: \"checkmark.circle.fill\""))
        XCTAssertTrue(ollama.contains("accessibilityLabel(\"Save Ollama endpoint\")"))
        XCTAssertFalse(ollama.contains("Button(\"Save\")"))
        XCTAssertTrue(ollama.contains("alignment: .trailing"))
        XCTAssertTrue(ollama.contains("Reachable · \\(installedModels.count) model"))
        XCTAssertTrue(ollama.contains("HStack(alignment: .center"))
        XCTAssertTrue(helpers.contains("width: ProviderSettingsRowLayout.circularActionDiameter"))
        XCTAssertTrue(helpers.contains("height: ProviderSettingsRowLayout.circularActionDiameter"))
        XCTAssertFalse(ollama.contains("private var statusDetail"))
        XCTAssertFalse(ollama.contains("Text(\"Endpoint\")"))
    }

    func testEngineCoreUsesAlwaysVisibleCompactRowsAndSeparateDetailSheet() throws {
        let shell = try source(pathComponents: [
            "Sources", "UI", "WorkerConsole", "Overview", "WorkerConsoleViews.swift",
        ])
        let views = try source(pathComponents: [
            "Sources", "UI", "WorkerConsole", "Domains", "EngineDashboardViews.swift",
        ])
        let compactRow = try XCTUnwrap(
            views.components(separatedBy: "private struct EngineCoreToolRow").last?
                .components(separatedBy: "struct EngineCoreToolDetailSheet").first
        )

        XCTAssertTrue(shell.contains("EngineCoreSection(group: group, tools: tools)"))
        XCTAssertTrue(shell.contains(".sheet(item: $selectedCoreTool)"))
        XCTAssertTrue(views.contains("LazyVStack(spacing: 8)"))
        XCTAssertFalse(views.contains("DisclosureGroup(isExpanded: $isExpanded)"))
        XCTAssertTrue(views.contains("EngineCoreToolDetailSheet"))
        XCTAssertTrue(views.contains("EngineDashboardPresentation.toolTitle(tool.modelName)"))
        XCTAssertFalse(compactRow.contains("tool.description"))
        XCTAssertFalse(compactRow.contains("tool.effectClass"))
        XCTAssertFalse(compactRow.contains("tool.risk"))
    }

    func testEngineAndProvidersSheetsDoNotMountSummaryHeroes() throws {
        let engine = try settingsPageSource(named: "EngineSettingsPage.swift")
        let providers = try settingsPageSource(named: "ProvidersSettingsPage.swift")
        let support = try source(pathComponents: ["Sources", "UI", "Settings", "Shell", "SettingsSupport.swift"])

        XCTAssertFalse(engine.contains("SettingsInfoCard("))
        XCTAssertFalse(engine.contains("summaryCard"))
        XCTAssertFalse(engine.contains("EngineSettingsSummary"))
        XCTAssertFalse(providers.contains("SettingsInfoCard("))
        XCTAssertFalse(providers.contains("providersInfoCard"))
        XCTAssertFalse(providers.contains("ProvidersSettingsSummary"))
        XCTAssertFalse(support.contains("EngineSettingsSummary"))
        XCTAssertFalse(support.contains("ProvidersSettingsSummary"))
    }

    func testEngineSettingsSurfacesActionableServerOwnedControlsInsideEnginePageOnly() throws {
        let engine = try settingsPageSource(named: "EngineSettingsPage.swift")
        let settingsMain = try source(pathComponents: ["Sources", "UI", "Settings", "Shell", "SettingsView+MainSection.swift"])

        XCTAssertTrue(engine.contains("label: \"Model\""))
        XCTAssertTrue(engine.contains("updateServerSetting(.defaultModel(model.id))"))
        XCTAssertTrue(engine.contains("updateServerSetting(.compactionTriggerTokenThreshold(newValue))"))
        XCTAssertTrue(settingsMain.contains("MainSettingsGridDestination.order"))
        XCTAssertFalse(settingsMain.contains("Server-Owned"))
        XCTAssertFalse(settingsMain.contains("This iPhone"))
    }

    func testSettingsMainRowsUseSeparateCardsWithoutChevrons() throws {
        let settingsMain = try source(pathComponents: ["Sources", "UI", "Settings", "Shell", "SettingsView+MainSection.swift"])

        XCTAssertTrue(
            settingsMain.contains("ForEach(MainSettingsGridDestination.order, id: \\.self)")
                && settingsMain.contains("SettingsCard {")
                && settingsMain.contains("mainSettingsDestinationRow(destination)"),
            "The top-level settings destinations should render as separate SettingsCard containers"
        )
        XCTAssertTrue(
            settingsMain.contains("ForEach(SettingsDangerZoneAction.order, id: \\.self)")
                && settingsMain.contains("SettingsCard(accent: dangerActionAccent(action))")
                && settingsMain.contains("SettingsSectionHeader(title: \"Danger Zone\")"),
            "Danger Zone actions should render as separate cards rather than one divided table"
        )
        XCTAssertTrue(
            settingsMain.contains("spacing: MainSettingsListLayout.sectionSpacing"),
            "Main settings sections should own spacing separately from row spacing"
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

    func testNotificationAndLogsUseTheirOwnedSettingsEntryPoints() throws {
        let settings = try source(
            pathComponents: ["Sources", "UI", "Settings", "Shell", "SettingsView.swift"]
        )
        let settingsMain = try source(
            pathComponents: ["Sources", "UI", "Settings", "Shell", "SettingsView+MainSection.swift"]
        )
        let support = try source(
            pathComponents: ["Sources", "UI", "Settings", "Shell", "SettingsSupport.swift"]
        )

        XCTAssertTrue(settings.contains("Button { activePage = .notifications }"))
        XCTAssertTrue(settings.contains("Image(systemName: notificationToolbarIcon)"))
        XCTAssertFalse(settings.contains("Button { showLogViewer = true } label:"))
        XCTAssertTrue(settingsMain.contains("case .logs:"))
        XCTAssertTrue(settingsMain.contains("showLogViewer = true"))
        XCTAssertTrue(support.contains("case logs"))
        XCTAssertFalse(support.contains("case notifications"))
        XCTAssertTrue(
            support.contains(
                """
                .app,
                        .logs,
                """
            ),
            "Logs should remain the final ordinary Settings row"
        )
    }

    func testNotificationSheetsUseStandardCardsToolbarsAndMediumDetents() throws {
        let inbox = try source(
            pathComponents: ["Sources", "UI", "Notifications", "NotificationInboxViews.swift"]
        )
        let readiness = try source(
            pathComponents: ["Sources", "UI", "Notifications", "NotificationReadinessView.swift"]
        )
        let pageContainer = try source(
            pathComponents: ["Sources", "UI", "Settings", "Shell", "SettingsPageContainer.swift"]
        )

        XCTAssertTrue(inbox.contains("SettingsPageContainer("))
        XCTAssertTrue(
            inbox.components(
                separatedBy: ".adaptivePresentationDetents([.medium, .large], ipadSizing: .largeForm)"
            ).count >= 3,
            "Both notification sheets should own the standard medium/large presentation"
        )
        XCTAssertTrue(inbox.contains("accessibilityLabel: \"Mark all notifications read\""))
        XCTAssertFalse(inbox.contains("Button(\"Mark All Read\")"))
        XCTAssertTrue(inbox.contains("accessibilityLabel: \"Snooze notification\""))
        XCTAssertTrue(inbox.contains("accessibilityLabel: \"Complete notification\""))
        XCTAssertTrue(inbox.contains("if hasResponseActions {"))
        XCTAssertTrue(inbox.contains("SettingsPageContainer(title: \"Notification\")"))
        XCTAssertTrue(inbox.contains("SettingsSectionHeader(title: \"Reminder\")"))
        XCTAssertTrue(inbox.contains("SettingsSectionHeader(title: \"Source\")"))
        XCTAssertFalse(inbox.contains(".buttonStyle(.borderedProminent)"))
        XCTAssertTrue(inbox.contains("scrollsContent: false"))
        XCTAssertTrue(inbox.contains("List {"))
        XCTAssertTrue(inbox.contains(".swipeActions(edge: .leading, allowsFullSwipe: false)"))
        XCTAssertTrue(inbox.contains(".swipeActions(edge: .trailing, allowsFullSwipe: false)"))
        XCTAssertTrue(inbox.contains("coordinator.acknowledge(.snooze, item: item)"))
        XCTAssertTrue(inbox.contains("coordinator.acknowledge(.complete, item: item)"))
        XCTAssertTrue(inbox.contains("coordinator.acknowledge(.clearUnread, item: item)"))
        XCTAssertTrue(inbox.contains("NotificationInboxLayout.bodyLineLimit"))
        XCTAssertTrue(
            pageContainer.contains("if scrollsContent {"),
            "List-backed settings sheets must be able to opt out of the container's outer ScrollView"
        )

        XCTAssertTrue(readiness.contains("SettingsRowDivider()"))
        XCTAssertTrue(readiness.contains("icon: \"iphone\""))
        XCTAssertTrue(readiness.contains("icon: \"network\""))
        XCTAssertFalse(readiness.contains(".padding(.horizontal, 12)"))
    }

    func testStopAllWorkersLivesInConfirmedSettingsDangerAction() throws {
        let settingsView = try source(pathComponents: ["Sources", "UI", "Settings", "Shell", "SettingsView.swift"])
        let settingsMain = try source(pathComponents: ["Sources", "UI", "Settings", "Shell", "SettingsView+MainSection.swift"])
        let settingsSupport = try source(pathComponents: ["Sources", "UI", "Settings", "Shell", "SettingsSupport.swift"])
        let engine = try source(pathComponents: [
            "Sources", "UI", "WorkerConsole", "Overview", "WorkerConsoleViews.swift",
        ])

        XCTAssertTrue(settingsSupport.contains("case stopAllWorkers"))
        XCTAssertTrue(settingsMain.contains("showWorkerDispatchConfirmation = true"))
        XCTAssertTrue(settingsView.contains(".alert(workerDispatchConfirmationTitle"))
        XCTAssertTrue(settingsView.contains("setWorkersStopped(!workersStopped)"))
        XCTAssertTrue(settingsView.contains("workerKernelRepository.setWorkersStopped("))
        XCTAssertFalse(engine.contains("confirmStopAll"))
        XCTAssertFalse(engine.contains("Resume queued work"))
        XCTAssertFalse(engine.contains("Stop all workers"))
    }

    func testSettingsFooterIsPinnedOnlyAtTheLargeDetent() throws {
        let settingsView = try source(pathComponents: ["Sources", "UI", "Settings", "Shell", "SettingsView.swift"])
        let pageContainer = try source(pathComponents: ["Sources", "UI", "Settings", "Shell", "SettingsPageContainer.swift"])
        let settingsMain = try source(pathComponents: ["Sources", "UI", "Settings", "Shell", "SettingsView+MainSection.swift"])
        let support = try source(pathComponents: ["Sources", "UI", "Settings", "Shell", "SettingsSupport.swift"])

        XCTAssertTrue(
            settingsView.contains("@State private var selectedDetent: PresentationDetent = .medium")
                && settingsView.contains("selection: $selectedDetent")
                && settingsView.contains("if selectedDetent == .large")
                && settingsView.contains("settingsFooterDockView"),
            "The Settings footer should mount only when the phone sheet reaches its large detent"
        )
        XCTAssertFalse(
            settingsView.contains(".safeAreaInset(edge: .bottom"),
            "A transparent safe-area overlay would allow Danger Zone content to remain legible behind the footer"
        )
        XCTAssertFalse(
            pageContainer.contains("safeAreaInset") || pageContainer.contains("footer:"),
            "SettingsPageContainer should stay a plain scroll container; Settings footer belongs to Settings content"
        )
        XCTAssertTrue(
            settingsMain.contains("var settingsFooterDockView: some View")
                && settingsMain.contains(".padding(.horizontal, MainSettingsFooterLayout.horizontalPadding)")
                && settingsMain.contains(".padding(.leading, MainSettingsFooterLayout.taglineLeadingPadding)"),
            "The pinned footer should align its content with the Settings rows"
        )
        XCTAssertFalse(
            settingsMain.contains("SettingsFooterBackdrop()"),
            "The footer should sit directly on the sheet instead of painting a rectangular material layer"
        )
        XCTAssertFalse(
            settingsView.contains("feedbackMailDraft")
                || settingsMain.contains("Send Feedback")
                || settingsMain.contains("feedbackFooterButton"),
            "Settings should not retain the removed feedback-mail action"
        )
        XCTAssertTrue(
            support.contains("static let horizontalPadding")
                && support.contains("static let taglineLeadingPadding")
                && support.contains("static let verticalPadding")
                && !support.contains("feedbackButton")
                && !support.contains("textLeadingPadding")
                && !support.contains("dockHeight"),
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
