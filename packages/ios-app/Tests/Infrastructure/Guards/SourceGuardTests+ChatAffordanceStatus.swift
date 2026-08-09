import Testing
import Foundation

extension SourceGuardTests {
    @Test("Interactive chat loading has one visible owner and one action policy")
    func testInteractiveChatLoadingPresentationRemainsCoherent() throws {
        let iosRoot = iosAppRoot()
        let messageList = try String(
            contentsOf: iosRoot.appendingPathComponent(
                "Sources/UI/Chat/Shell/ChatView+MessageList.swift"
            ),
            encoding: .utf8
        )
        let chatView = try String(
            contentsOf: iosRoot.appendingPathComponent(
                "Sources/UI/Chat/Shell/ChatView.swift"
            ),
            encoding: .utf8
        )
        let timelineNotifications = try String(
            contentsOf: iosRoot.appendingPathComponent(
                "Sources/UI/Chat/Messages/NotificationViews.swift"
            ),
            encoding: .utf8
        )
        let systemEvents = try String(
            contentsOf: iosRoot.appendingPathComponent(
                "Sources/Session/Timeline/Messages/SystemEvent.swift"
            ),
            encoding: .utf8
        )
        let reconstruction = try String(
            contentsOf: iosRoot.appendingPathComponent(
                "Sources/Session/Chat/ViewModel/ChatViewModel+Reconstruction.swift"
            ),
            encoding: .utf8
        )

        #expect(messageList.contains("placeholderText: historyPhase.placeholderText"))
        #expect(messageList.contains("allowsTextEntry: historyPhase.allowsLocalDraftActions"))
        #expect(messageList.contains("allowsAttachments: historyPhase.allowsLocalDraftActions"))
        #expect(messageList.contains("allowsSpeechCapture: historyPhase.allowsLocalDraftActions"))
        #expect(messageList.contains("allowsSubmission: historyPhase.hasAuthoritativeSnapshot"))
        #expect(messageList.contains("availabilityBlockReason: historyPhase.submissionBlockReason"))
        #expect(messageList.contains(".allowsHitTesting(initialLoadComplete)"))
        #expect(messageList.contains(".accessibilityHidden(!initialLoadComplete)"))
        #expect(!messageList.contains("Loading conversation"))
        #expect(!messageList.contains("chat-history-loading-state"))
        #expect(!messageList.contains("interactionPolicy"))
        #expect(!chatView.contains("@Environment(\\.interactionPolicy)"))
        #expect(!chatView.contains("markInitialReconstructionDelayed"))
        #expect(!timelineNotifications.contains("CatchingUpNotificationView"))
        #expect(!systemEvents.contains("case catchingUp"))

        let commitStart = try #require(reconstruction.range(
            of: "// INVARIANT: Do not suspend between this marker"
        ))
        let commitEnd = try #require(reconstruction.range(
            of: "\n        conversationHistoryPhase = .authoritative",
            range: commitStart.upperBound..<reconstruction.endIndex
        ))
        let snapshotCommit = reconstruction[
            commitStart.lowerBound..<commitEnd.upperBound
        ]
        #expect(snapshotCommit.contains("replaceAllMessages"))
        #expect(snapshotCommit.contains("updateTokenState"))
        #expect(!snapshotCommit.contains("await "))

        let cachedCommitStart = try #require(reconstruction.range(
            of: "// INVARIANT: Cached rows and their draft-ready phase publish"
        ))
        let cachedCommitEnd = try #require(reconstruction.range(
            of: "\n            conversationHistoryPhase = .cachedSynchronizing",
            range: cachedCommitStart.upperBound..<reconstruction.endIndex
        ))
        let cachedCommit = reconstruction[
            cachedCommitStart.lowerBound..<cachedCommitEnd.upperBound
        ]
        #expect(cachedCommit.contains("replaceAllMessages"))
        #expect(!cachedCommit.contains("await "))
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

    @Test("Compact session reopening always creates a fresh chat presentation")
    func testCompactSessionReopeningUsesFreshPresentationIdentity() throws {
        let source = try String(
            contentsOf: iosAppRoot().appendingPathComponent("Sources/UI/Chat/Shell/ContentView.swift"),
            encoding: .utf8
        )

        #expect(source.contains("@State private var compactSessionRoute: CompactSessionRoute?"))
        #expect(source.contains(".navigationDestination(item: $compactSessionRoute)"))
        #expect(source.contains(".id(route.presentationId)"))
        #expect(source.contains("selectedSessionId: sidebarSessionSelection"))
        #expect(!source.contains(".navigationDestination(item: $selectedSessionId)"))
    }

    @Test("Engine Dashboard is the single profile-level high-signal engine surface")
    func testEngineDashboardOwnsHighSignalCockpit() throws {
        let iosRoot = iosAppRoot()
        let sidebar = try String(
            contentsOf: iosRoot.appendingPathComponent("Sources/UI/Chat/Shell/SessionSidebar.swift"),
            encoding: .utf8
        )
        let console = try String(
            contentsOf: iosRoot.appendingPathComponent(
                "Sources/UI/WorkerConsole/Overview/WorkerConsoleViews.swift"
            ),
            encoding: .utf8
        )
        let consoleRow = try String(
            contentsOf: iosRoot.appendingPathComponent(
                "Sources/UI/WorkerConsole/Overview/WorkerConsoleRow.swift"
            ),
            encoding: .utf8
        )
        let consoleSurface = console + consoleRow
        let viewModel = try String(
            contentsOf: iosRoot.appendingPathComponent("Sources/Session/WorkerKernel/WorkerConsoleViewModel.swift"),
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
        #expect(!sidebar.contains("dashboardSessionId"))
        #expect(!sidebar.contains("sessionId: selectedSessionId"))
        #expect(viewModel.contains("sessionId: nil"))
        #expect(!viewModel.contains("currentSessionId"))
        #expect(consoleSurface.contains("Direct chat tool"))
        #expect(consoleSurface.contains("Integrated worker"))
        #expect(consoleSurface.contains("Delegated worker"))
        #expect(consoleSurface.contains("runnerLabel(worker.runnerKind)"))
        #expect(consoleSurface.contains("private func compactMetadataLabel"))
        #expect(consoleSurface.contains("HStack(spacing: 3)"))
        #expect(!consoleSurface.contains("\"This session\""))
        #expect(!consoleSurface.contains("\"Promoted\""))
        #expect(!consoleSurface.contains("routingEvidence"))
        #expect(sidebar.contains("await workerConsole.monitorSummary("))
        #expect(console.contains("await viewModel.monitor("))
        #expect(console.contains("await viewModel.monitorSummary("))
        #expect(console.contains("selectedSection == .activity"))
        #expect(!viewModel.contains("pollWorkerEvents"))
        #expect(sidebar.contains("continuity: dependencies.connectionRepository.continuity"))
        #expect(sidebar.contains("workerConsoleOwnerId != ownerId"))
        #expect(sidebar.contains(".task(id: workerConsoleRefreshKey)"))
        #expect(sidebar.contains(".contentShape(shape)\n                .glassEffect("))
        #expect(sidebar.contains(".buttonStyle(.plain)\n        .contentShape(shape)"))
        #expect(theme.contains(".glassEffect(\n                        .regular.tint(color.opacity(glassOpacity)).interactive(),\n                        in: shape\n                    )\n                    .contentShape(shape)"))
        #expect(sidebar.components(separatedBy: ".task(id: workerConsoleRefreshKey)").count == 2)
        #expect(sidebar.components(separatedBy: "WorkerConsoleSheet(").count == 2)
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
