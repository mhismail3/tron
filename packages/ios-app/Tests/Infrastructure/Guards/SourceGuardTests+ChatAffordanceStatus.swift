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

    @Test("Chat shell does not mount passive agent cockpit")
    func testChatShellDoesNotMountPassiveAgentCockpit() throws {
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
            #expect(!source.contains("AgentCockpitViewModel()"))
            #expect(!source.contains("showAgentCockpit"))
            #expect(!source.contains("agentCockpit.refresh"))
            #expect(!source.contains("case agentCockpit"))
        }

        let cockpitViews = try String(
            contentsOf: iosRoot.appendingPathComponent("Sources/UI/AgentCockpit/AgentCockpitViews.swift"),
            encoding: .utf8
        )
        #expect(cockpitViews.contains("struct AgentCockpitSheet"))
        #expect(!cockpitViews.contains("struct AgentStatusCapsuleView"))
        #expect(cockpitViews.contains(#"SheetTitle(title: "Runtime Cockpit", color: .tronEmerald)"#))
        #expect(cockpitViews.contains("SheetDismissButton(color: .tronEmerald)"))
        #expect(cockpitViews.contains("TronSegmentedControl("))
        #expect(!cockpitViews.contains(#"Picker("Cockpit""#))
        #expect(cockpitViews.contains(".adaptivePresentationDetents([.medium, .large], ipadSizing: .largeForm)"))

        let serverSettings = try String(
            contentsOf: iosRoot.appendingPathComponent("Sources/UI/Settings/Pages/ConnectionSettingsPage.swift"),
            encoding: .utf8
        )
        #expect(serverSettings.contains("ConnectionSettingsDiagnosticsSheet"))
        #expect(serverSettings.contains("AgentCockpitSheet("))
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

    @Test("Chat scoped errors do not use generic alert surface")
    func testChatScopedErrorsAvoidGenericAlertSurface() throws {
        let iosRoot = iosAppRoot()
        let chatView = try String(
            contentsOf: iosRoot.appendingPathComponent("Sources/UI/Chat/Shell/ChatView.swift"),
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
    }
}
