import Testing
import Foundation

extension SourceGuardTests {
    @Test("Chat timeline does not mount connection status surface")
    func testChatTimelineDoesNotMountConnectionStatusSurface() throws {
        let iosRoot = iosAppRoot()
        let chatSources = [
            "Sources/UI/Chat/Shell/ChatView+MessageList.swift",
            "Sources/UI/Chat/Shell/ChatView.swift",
        ]
        let removedStatusView = "Connection" + "Status" + "Pill"
        let removedStatusPath = "Sources/UI/Components/" + removedStatusView + ".swift"

        for path in chatSources {
            let source = try String(contentsOf: iosRoot.appendingPathComponent(path), encoding: .utf8)
            #expect(!source.contains(removedStatusView))
        }
        #expect(!FileManager.default.fileExists(atPath: iosRoot.appendingPathComponent(removedStatusPath).path))
    }

    @Test("Chat composer reads canonical connection repository without a view-model mirror")
    func testChatComposerReadsCanonicalConnectionRepository() throws {
        let iosRoot = iosAppRoot()
        let messageList = try String(
            contentsOf: iosRoot.appendingPathComponent("Sources/UI/Chat/Shell/ChatView+MessageList.swift"),
            encoding: .utf8
        )
        let viewModel = try String(
            contentsOf: iosRoot.appendingPathComponent("Sources/Session/Chat/ViewModel/ChatViewModel.swift"),
            encoding: .utf8
        )

        #expect(messageList.contains("isConnected: services.connection.connectionState.isConnected"))
        #expect(!messageList.contains("viewModel.connectionState"))
        #expect(!viewModel.contains("var connectionState:"))
        #expect(!viewModel.contains("connectionState = state"))
        #expect(viewModel.contains("observeLoop({ connection.connectionState })"))
        #expect(viewModel.contains("if case .disconnected = state"))
    }

    @Test("Chat timeline autoloads earlier messages without manual pill")
    func testChatTimelineDoesNotMountManualEarlierMessagesPill() throws {
        let iosRoot = iosAppRoot()
        let uiSources = [
            "Sources/UI/Chat/Shell/ChatView+MessageList.swift",
            "Sources/UI/Chat/Shell/ChatView.swift",
        ]
        let removedLabel = "Load " + "Earlier " + "Messages"

        for path in uiSources {
            let source = try String(contentsOf: iosRoot.appendingPathComponent(path), encoding: .utf8)
            #expect(!source.contains(removedLabel))
        }
    }

    @Test("Compaction pill labels saved percentage as reduction")
    func testCompactionPillLabelsReductionPercentage() throws {
        let iosRoot = iosAppRoot()
        let source = try String(
            contentsOf: iosRoot.appendingPathComponent("Sources/UI/Chat/Messages/NotificationViews.swift"),
            encoding: .utf8
        )

        #expect(source.contains(#""\(compressionPercent)% reduction""#))
        #expect(!source.contains(#""(\(compressionPercent)%)""#))
    }

    @Test("Local timeline notifications stay single-line with full accessible detail")
    func testLocalTimelineNotificationsStaySingleLine() throws {
        let source = try String(
            contentsOf: iosAppRoot().appendingPathComponent("Sources/UI/Chat/Messages/NotificationViews.swift"),
            encoding: .utf8
        )

        #expect(source.contains("Text(\"\\u{2022}\")"))
        #expect(source.contains(".lineLimit(1)"))
        #expect(source.contains(".accessibilityLabel(notification.textContent)"))
    }

    @Test("Chat conversation does not mount passive engine cockpit")
    func testChatConversationDoesNotMountPassiveEngineCockpit() throws {
        let iosRoot = iosAppRoot()
        let chatSources = [
            "Sources/UI/Chat/Shell/ChatView.swift",
            "Sources/UI/Chat/Shell/ChatSheetContent.swift",
            "Sources/UI/Chat/Shell/ChatSheetModifier.swift",
            "Sources/Session/Chat/Coordinators/SheetCoordinator.swift",
            "Sources/Session/Chat/State/ChatSheet.swift",
        ]

        for path in chatSources {
            let source = try String(contentsOf: iosRoot.appendingPathComponent(path), encoding: .utf8)
            #expect(!source.contains("AgentStatusCapsuleView"))
            #expect(!source.contains("WorkerConsoleViewModel()"))
            #expect(!source.contains("showWorkerConsole"))
            #expect(!source.contains("workerConsole.refresh"))
            #expect(!source.contains("case agentCockpit"))
        }

        let serverSettings = try String(
            contentsOf: iosRoot.appendingPathComponent("Sources/UI/Settings/Pages/EngineServersSection.swift"),
            encoding: .utf8
        )
        let engineSettings = try String(
            contentsOf: iosRoot.appendingPathComponent("Sources/UI/Settings/Pages/EngineSettingsPage.swift"),
            encoding: .utf8
        )
        #expect(!serverSettings.contains("ConnectionSettingsDiagnosticsSheet"))
        #expect(!serverSettings.contains("WorkerConsoleSheet("))
        #expect(!serverSettings.contains(#"Image(systemName: "chevron.right")"#))
        #expect(!engineSettings.contains(#"Image(systemName: "chevron.right")"#))
    }

    @Test("Dashboard is the single high-signal worker-console surface")
    func testDashboardOwnsHighSignalCockpit() throws {
        let iosRoot = iosAppRoot()
        let sidebar = try String(
            contentsOf: iosRoot.appendingPathComponent("Sources/UI/Chat/Shell/SessionSidebar.swift"),
            encoding: .utf8
        )
        let theme = try String(
            contentsOf: iosRoot.appendingPathComponent("Sources/UI/Theme/TronColors.swift"),
            encoding: .utf8
        )
        #expect(sidebar.contains("WorkerConsoleDashboardBand("))
        #expect(sidebar.contains("WorkerConsoleSheet("))
        #expect(sidebar.contains("SessionListWorkspaceGroup.groups"))
        #expect(sidebar.contains("workerConsoleRefreshKey"))
        #expect(sidebar.contains("dependencies.connectionRepository.connectionState.isConnected"))
        #expect(sidebar.contains(".task(id: workerConsoleRefreshKey)"))
        #expect(sidebar.contains(".contentShape(shape)\n                .glassEffect("))
        #expect(sidebar.contains(".buttonStyle(.plain)\n        .contentShape(shape)"))
        #expect(theme.contains(".glassEffect(\n                        .regular.tint(color.opacity(glassOpacity)).interactive(),\n                        in: shape\n                    )\n                    .contentShape(shape)"))
        #expect(sidebar.components(separatedBy: ".task(id: workerConsoleRefreshKey)").count == 2)
        #expect(sidebar.components(separatedBy: "WorkerConsoleSheet(").count == 2)
        #expect(!sidebar.contains("Dash" + "board" + "V2"))

        let retiredLegacyHomePaths = [
            "Sources/UI/Chat/Shell/" + "Dash" + "board" + "V2Components.swift",
            "Sources/UI/Chat/Shell/" + "Dash" + "board" + "V2LabSheet.swift",
            "Sources/UI/Chat/Shell/" + "Dash" + "board" + "V2View.swift",
            "UITests/" + "Dash" + "board" + "V2UITests.swift",
            "Tests/Infrastructure/Guards/SourceGuardTests+" + "Dash" + "board" + "V2.swift",
        ]
        for path in retiredLegacyHomePaths {
            #expect(!FileManager.default.fileExists(atPath: iosRoot.appendingPathComponent(path).path))
        }
    }

    @Test("Chat pill sheet is canonically named Session Briefing")
    func testChatPillSheetUsesSessionBriefingName() throws {
        let iosRoot = iosAppRoot()
        let repoRoot = iosRoot
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let retiredSurfaceName = "Agent " + "Control"
        let retiredIdentifierPrefix = "agent-" + "control"
        let projectReference = try String(
            contentsOf: repoRoot.appendingPathComponent("packages/agent/docs/project-reference.md"),
            encoding: .utf8
        )
        let contextButton = try String(
            contentsOf: iosRoot.appendingPathComponent("Sources/UI/Chat/Composer/ContextBriefingButton.swift"),
            encoding: .utf8
        )
        let contextSheet = try String(
            contentsOf: iosRoot.appendingPathComponent("Sources/UI/Chat/Sheets/ContextControlSheet.swift"),
            encoding: .utf8
        )
        let contextModels = try String(
            contentsOf: iosRoot.appendingPathComponent("Sources/UI/Chat/Sheets/ContextControlSheetModels.swift"),
            encoding: .utf8
        )
        let contextContract = try String(
            contentsOf: repoRoot.appendingPathComponent("packages/agent/src/domains/context_control/contract.rs"),
            encoding: .utf8
        )
        let contextContractTests = try String(
            contentsOf: repoRoot.appendingPathComponent("packages/agent/src/domains/context_control/tests.rs"),
            encoding: .utf8
        )
        let uiTest = iosRoot.appendingPathComponent("UITests/SessionBriefingUITests.swift")

        #expect(FileManager.default.fileExists(atPath: uiTest.path))
        #expect(!FileManager.default.fileExists(atPath: iosRoot.appendingPathComponent("UITests/" + "Agent" + "Control" + "UITests.swift").path))
        #expect(projectReference.contains("Session Briefing sheet opened from the composer context ring"))
        #expect(!projectReference.contains(retiredSurfaceName + " sheet opened from the composer context ring"))
        #expect(contextButton.contains("Context Briefing Button"))
        #expect(contextButton.contains(".accessibilityLabel(\"Session Briefing\")"))
        #expect(!contextButton.contains("Opens " + retiredSurfaceName))
        #expect(contextSheet.contains("session-briefing-context-summary"))
        #expect(contextSheet.contains("session-briefing-composition-card"))
        #expect(contextSheet.contains("session-briefing-model-card"))
        #expect(contextSheet.contains("Session Briefing payload"))
        #expect(!contextSheet.contains(retiredSurfaceName + " payload"))
        #expect(!contextSheet.contains(retiredIdentifierPrefix + "-context-summary"))
        #expect(!contextSheet.contains(retiredIdentifierPrefix + "-composition-card"))
        #expect(contextModels.contains("Memory refs only in Session Briefing"))
        #expect(contextContract.contains("First-party Session Briefing UI wrapper"))
        #expect(contextContract.contains(#""session-briefing""#))
        #expect(!contextContract.contains("First-party " + retiredSurfaceName + " UI wrapper"))
        #expect(!contextContract.contains(#"""# + retiredIdentifierPrefix + #"""#))
        #expect(!contextContractTests.contains(retiredSurfaceName))
    }

    @Test("Session list rows use inset liquid glass containers")
    func testSessionListRowsUseInsetLiquidGlassContainers() throws {
        let iosRoot = iosAppRoot()
        let list = try String(
            contentsOf: iosRoot.appendingPathComponent("Sources/UI/Chat/Shell/SessionList.swift"),
            encoding: .utf8
        )
        let sidebar = try String(
            contentsOf: iosRoot.appendingPathComponent("Sources/UI/Chat/Shell/SessionSidebar.swift"),
            encoding: .utf8
        )

        #expect(list.contains("static let rowContainerHorizontalInset: CGFloat = 16"))
        #expect(list.contains("static let rowContentHorizontalPadding: CGFloat = 12"))
        #expect(list.contains("static var headerLeadingPadding: CGFloat"))
        #expect(list.contains("rowContainerHorizontalInset + rowContentHorizontalPadding"))
        #expect(list.contains("static var headerTrailingPadding: CGFloat"))
        #expect(list.contains("static let rowContainerCornerRadius: CGFloat = 12"))
        #expect(list.contains("leading: rowContainerHorizontalInset"))
        #expect(list.contains("trailing: rowContainerHorizontalInset"))
        #expect(list.contains(".padding(.leading, SessionListLayout.headerLeadingPadding)"))
        #expect(list.contains(".padding(.trailing, SessionListLayout.headerTrailingPadding)"))
        #expect(list.contains("HStack(alignment: .center, spacing: SessionListLayout.iconTextSpacing)"))
        #expect(sidebar.contains("Button {"))
        #expect(sidebar.contains("selectedSessionId = session.id"))
        #expect(sidebar.contains(".glassEffect("))
        #expect(sidebar.contains(".regular.tint(Color.tronEmerald.opacity(isSelected ? 0.22 : 0.14)).interactive()"))
        #expect(sidebar.contains(".buttonStyle(.plain)"))
        #expect(sidebar.contains(".listRowInsets(SessionListLayout.rowInsets)"))
        #expect(!list.contains("DragGesture(minimumDistance: 0)"))
        #expect(!list.contains("@GestureState"))
        #expect(!list.contains(".offset(boundedDragOffset)"))
        #expect(!list.contains("rowPressedScale"))
        #expect(!list.contains("rowPressedBrightness"))
        #expect(!list.contains("SessionListRowButtonStyle"))
        #expect(!list.contains("outerHorizontalPadding"))
        #expect(!list.contains(".sectionFill("))
    }

    @Test("Thinking indicator is app-owned Neural Spark only")
    func testThinkingIndicatorIsNeuralSparkOnly() throws {
        let iosRoot = iosAppRoot()
        let source = try String(
            contentsOf: iosRoot.appendingPathComponent("Sources/UI/Chat/Shell/ThinkingIndicator.swift"),
            encoding: .utf8
        )

        #expect(source.contains("NeuralSparkIndicator()"))
        #expect(!source.contains("AppearanceSettings"))
        let removedThemeStyle = "Sources/UI/Theme/" + "Thinking" + "Indicator" + "Style.swift"
        let removedPhaseIndicator = "Sources/UI/Chat/Messages/Indicators/" + "Phase" + "Wave" + "Indicator.swift"
        let removedOrbitIndicator = "Sources/UI/Chat/Messages/Indicators/" + "Orbiting" + "Particle" + "Indicator.swift"
        #expect(!FileManager.default.fileExists(atPath: iosRoot.appendingPathComponent(removedThemeStyle).path))
        #expect(!FileManager.default.fileExists(atPath: iosRoot.appendingPathComponent(removedPhaseIndicator).path))
        #expect(!FileManager.default.fileExists(atPath: iosRoot.appendingPathComponent(removedOrbitIndicator).path))
    }

    @Test("Chat scoped errors use only the local timeline surface")
    func testChatScopedErrorsUseOnlyLocalTimelineSurface() throws {
        let iosRoot = iosAppRoot()
        let chatView = try String(
            contentsOf: iosRoot.appendingPathComponent("Sources/UI/Chat/Shell/ChatView.swift"),
            encoding: .utf8
        )
        let viewModel = try String(
            contentsOf: iosRoot.appendingPathComponent("Sources/Session/Chat/ViewModel/ChatViewModel.swift"),
            encoding: .utf8
        )
        let errorPath = "Sources/Session/Chat/ViewModel/ChatViewModel+Errors.swift"
        let errorRouting = try String(
            contentsOf: iosRoot.appendingPathComponent(errorPath),
            encoding: .utf8
        )

        #expect(!chatView.contains(#".alert("Error""#))
        #expect(errorRouting.contains("appendLocalError"))
        #expect(errorRouting.contains("LocalChatNotification.error"))
        #expect(!errorRouting.contains("clearError"))
        #expect(!viewModel.contains("var errorMessage: String?"))
        #expect(!viewModel.contains("var showError: Bool"))
        #expect(viewModel.contains("func showError(_ message: String)"))
        #expect(viewModel.contains("handleError(message, severity: .fatal)"))
    }
}
