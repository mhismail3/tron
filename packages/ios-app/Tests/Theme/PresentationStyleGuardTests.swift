import Foundation
import Testing
@testable import TronMobile

@Suite("Established Tron presentation policy")
struct PresentationStyleGuardTests {
    private var packageRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // Theme directory
            .deletingLastPathComponent() // Tests directory
            .deletingLastPathComponent() // ios-app package root
    }

    private var uiSources: [(URL, String)] {
        swiftSources(at: packageRoot.appending(path: "Sources/UI"))
    }

    private func chatCompositionSources() throws -> String {
        try [
            "Sources/UI/Chat/ChatView.swift",
            "Sources/UI/Chat/ChatUIKitSessionSurfaceHost.swift",
            "Sources/UI/Chat/ChatUIKitViewportController.swift",
            "Sources/UI/Chat/ChatUIKitComposerController.swift",
            "Sources/UI/Chat/ChatRoutes.swift",
            "Sources/State/ChatSessionPresentation.swift",
        ].map { path in
            try String(contentsOf: packageRoot.appending(path: path), encoding: .utf8)
        }.joined(separator: "\n")
    }

    private func swiftSources(at root: URL) -> [(URL, String)] {
        let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        return (enumerator?.allObjects as? [URL] ?? [])
            .filter { $0.pathExtension == "swift" }
            .sorted { $0.path < $1.path }
            .compactMap { url in String(data: (try? Data(contentsOf: url)) ?? Data(), encoding: .utf8).map { (url, $0) } }
    }

    private func containsCall(_ name: String, in source: String) -> Bool {
        source.range(
            of: "(^|[^A-Za-z0-9_])\(NSRegularExpression.escapedPattern(for: name))\\(",
            options: .regularExpression
        ) != nil
    }

    private func occurrenceCount(_ needle: String, in source: String) -> Int {
        max(0, source.components(separatedBy: needle).count - 1)
    }

    private func toolbarItemBlocks(in source: String) -> [String] {
        var blocks: [String] = []
        var searchStart = source.startIndex
        while let item = source.range(of: "ToolbarItem", range: searchStart..<source.endIndex),
              let opening = source[item.lowerBound...].firstIndex(of: "{") {
            var depth = 0
            var cursor = opening
            repeat {
                if source[cursor] == "{" { depth += 1 }
                if source[cursor] == "}" { depth -= 1 }
                cursor = source.index(after: cursor)
            } while cursor < source.endIndex && depth > 0
            guard depth == 0 else { break }
            blocks.append(String(source[item.lowerBound..<cursor]))
            searchStart = cursor
        }
        return blocks
    }

    @Test("app-owned blocking presentations use the canonical activity lifecycle")
    func blockingPresentationsUseCanonicalLifecycle() throws {
        let coordinatorPath = "Sources/State/PresentationActivityCoordinator.swift"
        for (url, source) in swiftSources(at: packageRoot.appending(path: "Sources"))
            where !url.path.hasSuffix(coordinatorPath) {
            #expect(!source.contains(".sheet("), "Raw sheet in \(url.lastPathComponent)")
            #expect(!source.contains(".fullScreenCover("), "Raw full-screen cover in \(url.lastPathComponent)")
        }
        let app = try String(
            contentsOf: packageRoot.appending(path: "Sources/App/TronMobileApp.swift"),
            encoding: .utf8
        )
        let notices = try String(
            contentsOf: packageRoot.appending(path: "Sources/UI/Components/InAppNoticePresentation.swift"),
            encoding: .utf8
        )
        #expect(app.contains("struct SceneRootView: View"))
        #expect(app.contains("@State private var presentationActivity = PresentationActivityCoordinator()"))
        #expect(notices.contains(".environment(\\.tronPresentationActivityCoordinator, presentationActivity)"))
    }

    @Test("binding-owned system presentations use the canonical activity lifecycle")
    func systemPresentationsUseCanonicalLifecycle() {
        for (url, source) in swiftSources(at: packageRoot.appending(path: "Sources")) {
            let boundaries = occurrenceCount(".alert(", in: source)
                + occurrenceCount(".fileImporter(", in: source)
                + occurrenceCount(".photosPicker(", in: source)
            guard boundaries > 0 else { continue }
            #expect(
                occurrenceCount(".tronManagedSystemPresentation(", in: source) >= boundaries,
                "Unmanaged system presentation in \(url.lastPathComponent)"
            )
        }
    }

    @Test("text toolbar actions use a leading icon and the system toolbar weight")
    func textToolbarActionsUseIconsAndDefaultWeight() throws {
        for (url, source) in uiSources {
            for block in toolbarItemBlocks(in: source) where block.contains("Button") {
                let hasInlineText = containsCall("Text", in: block)
                    || containsCall("Label", in: block)
                    || block.contains("Button(\"")
                guard hasInlineText else { continue }
                #expect(
                    block.contains("TronToolbarTextLabel"),
                    "\(url.lastPathComponent) contains a textual toolbar button outside TronToolbarTextLabel"
                )
                #expect(!block.contains("weight: .bold"), "\(url.lastPathComponent) bolds toolbar text")
                #expect(!block.contains("weight: .semibold"), "\(url.lastPathComponent) semibolds toolbar text")
                #expect(!block.contains("weight: .medium"), "\(url.lastPathComponent) medium-weights toolbar text")
            }
        }

        let presentation = try String(
            contentsOf: packageRoot.appending(path: "Sources/UI/Theme/TronPresentation.swift"),
            encoding: .utf8
        )
        let label = (presentation.components(separatedBy: "struct TronToolbarTextLabel").dropFirst().first ?? "")
            .components(separatedBy: "struct TronSaveToolbarButton").first ?? ""
        #expect(label.contains("Image(systemName: systemImage)"))
        #expect(label.contains("Text(title)"))
        #expect(!label.contains(".font("))
        let action = (presentation.components(separatedBy: "func tronToolbarAction").dropFirst().first ?? "")
            .components(separatedBy: "func tronNavigationTitle").first ?? ""
        #expect(!action.contains("font("))
    }

    @Test("inbound producer messages are trailing tappable context rows")
    func triggeredSessionMessagesAreTrailingAndTappable() throws {
        let row = try String(
            contentsOf: packageRoot.appending(path: "Sources/UI/Chat/TranscriptRow.swift"),
            encoding: .utf8
        )
        let message = try String(
            contentsOf: packageRoot.appending(path: "Sources/UI/Chat/SessionInputMessageView.swift"),
            encoding: .utf8
        )
        let kernel = try String(
            contentsOf: packageRoot.appending(path: "Sources/UI/Chat/ChatTranscriptProjectionKernel.swift"),
            encoding: .utf8
        )
        let toolDetails = try String(
            contentsOf: packageRoot.appending(path: "Sources/UI/Chat/ToolTechnicalDetailsSheet.swift"),
            encoding: .utf8
        )

        #expect(row.contains("item.role == .user || item.semantic?.direction == .inboundContext"))
        #expect(row.contains("InboundProducerMessageView(item: item)"))
        #expect(message.contains("Button { showingDetails = true }"))
        #expect(message.contains("ChatCompactPillSurface("))
        #expect(message.contains("ChatCompactPillLabel("))
        #expect(message.contains("title: InboundProducerPresentationPolicy.compactTitle"))
        #expect(message.contains("detail: status"))
        #expect(!message.contains("goal.compactStatus"))
        #expect(!message.contains("UserPromptText(text: messageText)"))
        #expect(message.contains("InboundContextDetailsSheet(item: item)"))
        #expect(message.contains("TronMarkdownView(text: messageText, streaming: false)"))
        #expect(message.contains("TronTechnicalMetadataSection("))
        #expect(message.contains("TronTechnicalJSONRow("))
        #expect(message.contains("@State private var detent: PresentationDetent = .medium"))
        #expect(message.contains(".presentationDetents([.medium, .large], selection: $detent)"))
        #expect(message.contains(".tronTopBlur(.toolDetail)"))
        #expect(message.contains("Image(systemName: \"checkmark\")"))
        #expect(!message.contains("TronToolbarTextLabel(\"Done\""))
        #expect(toolDetails.contains("TronTechnicalMetadataSection("))
        #expect(kernel.contains("custom_message is inbound model context, never a tool run"))
    }

    @Test("dashboard settings action is icon-only and accessible")
    func dashboardSettingsActionIsIconOnlyAndAccessible() throws {
        let shell = try String(
            contentsOf: packageRoot.appending(path: "Sources/UI/Chat/SessionShellView.swift"),
            encoding: .utf8
        )
        let toolbar = (shell.components(separatedBy: "private var dashboardToolbar").dropFirst().first ?? "")
            .components(separatedBy: "private var renameConfirmationPresented").first ?? ""

        #expect(toolbar.contains("Image(systemName: \"gearshape\")"))
        #expect(toolbar.contains(".accessibilityLabel(\"Settings\")"))
        #expect(!toolbar.contains("TronToolbarTextLabel(\"Settings\""))
        #expect(!toolbar.contains("Text(\"Settings\")"))
    }

    @Test("settings owns the notification bell and standardized inbox sheets")
    func notificationInboxChrome() throws {
        let settings = try String(
            contentsOf: packageRoot.appending(path: "Sources/UI/Settings/SettingsView.swift"),
            encoding: .utf8
        )
        let inbox = try String(
            contentsOf: packageRoot.appending(path: "Sources/UI/Settings/NotificationInboxView.swift"),
            encoding: .utf8
        )
        #expect(settings.contains("ToolbarItem(placement: .topBarLeading)"))
        #expect(settings.contains("NotificationInboxToolbarButton("))
        #expect(settings.contains("NotificationInboxView(onOpenSession: onImported)"))
        #expect(inbox.contains("bell.badge.fill"))
        #expect(inbox.contains("Open notifications, \\(unreadCount) unread"))
        #expect(inbox.contains("TronSegmentedControl("))
        #expect(inbox.contains("private var filterControl: some View"))
        #expect(!inbox.contains("private var filterCard: some View"))
        #expect(!inbox.contains("TronTechnicalSectionLabel(\"Inbox\")"))
        #expect(!inbox.contains("ContentUnavailableView("))
        #expect(inbox.contains("private var emptyState: some View"))
        #expect(inbox.contains(".font(TronTypography.headline)"))
        #expect(inbox.contains(".font(TronTypography.bodySM)"))
        #expect(inbox.contains("TronGlassCard("))
        #expect(inbox.contains("TronTechnicalMetadataSection("))
        #expect(inbox.contains("TronToolbarTextLabel("))
        #expect(inbox.contains("static let recentLimit = 15"))
        #expect(inbox.contains("NotificationInboxHistoryView("))
        #expect(inbox.contains("LazyVStack(spacing: TronSpacing.sm)"))
        #expect(inbox.contains("style: .plain"))
        #expect(!inbox.contains("chevron.right"))
        #expect(!inbox.contains("Circle()"))
        #expect(inbox.contains("isOpening ? \"Opening…\" : \"Open Chat\""))
        #expect(inbox.contains(".presentationDetents([.medium, .large])"))
        #expect(inbox.occurrences(of: "TronSheetTitle(title:") == 3)
        #expect(inbox.occurrences(of: "Image(systemName: \"checkmark\")") == 3)
        #expect(!inbox.contains(".pickerStyle(.segmented)"))
        #expect(!inbox.contains("List {"))
        #expect(!inbox.contains("Form {"))
    }

    @Test("shared toggles own accessible motion while tool chips retain native glass interaction")
    func sharedToggleMotionAndNativeToolChipInteraction() throws {
        let presentation = try String(
            contentsOf: packageRoot.appending(path: "Sources/UI/Theme/TronPresentation.swift"),
            encoding: .utf8
        )
        let compactPill = try String(
            contentsOf: packageRoot.appending(path: "Sources/UI/Chat/ChatCompactPill.swift"),
            encoding: .utf8
        )
        let toolRuns = try String(
            contentsOf: packageRoot.appending(path: "Sources/UI/Chat/ChatToolRunViews.swift"),
            encoding: .utf8
        )
        let transcriptEvents = try String(
            contentsOf: packageRoot.appending(path: "Sources/UI/Chat/ChatTranscriptEventViews.swift"),
            encoding: .utf8
        )
        let notification = (transcriptEvents.components(
            separatedBy: "struct ChatNotificationView"
        ).dropFirst().first ?? "").components(
            separatedBy: "struct TranscriptNotice"
        ).first ?? ""

        #expect(presentation.contains("enum TronToggleMotionPolicy"))
        #expect(presentation.contains("private struct TronToggleControl: View"))
        #expect(presentation.contains("@Environment(\\.accessibilityReduceMotion) private var reduceMotion"))
        #expect(presentation.contains(".phaseAnimator([false, true, false], trigger: isOn)"))
        #expect(presentation.contains("width: TronToggleMotionPolicy.controlWidth"))
        #expect(presentation.contains("height: TronToggleMotionPolicy.controlHeight"))
        #expect(presentation.contains("TronToggleControl(isOn: isOn, accent: resolvedAccent)"))
        #expect(presentation.contains(".accessibilityRepresentation"))
        #expect(presentation.contains("Toggle(isOn: $isOn) { Text(title) }"))

        #expect(toolRuns.occurrences(of: "interactive: true") == 2)
        #expect(toolRuns.occurrences(of: "        .chatCompactPillInteraction(\n") == 2)
        #expect(compactPill.contains("private struct ChatCompactPillInteractionModifier"))
        #expect(compactPill.contains(".onTapGesture(perform: action)"))
        #expect(compactPill.contains(".accessibilityAddTraits(.isButton)"))
        #expect(transcriptEvents.contains(".chatCompactPillInteraction("))
        #expect(!notification.contains("Button { showingDetail = true }"))
        #expect(!notification.contains(".contentShape(Rectangle())"))
        let interactionPosition = try #require(
            notification.firstRange(of: ".chatCompactPillInteraction(")?.lowerBound
        )
        let semanticFramePosition = try #require(
            notification.firstRange(of: ".frame(minWidth: 44, minHeight: 44)")?.lowerBound
        )
        #expect(interactionPosition < semanticFramePosition)
        #expect(!toolRuns.contains("ChatToolChipPressStyle"))
        #expect(toolRuns.contains("ChatToolChipAnimationTransactionKey"))
        #expect(toolRuns.contains("transaction.admitsChatToolChipAnimation = true"))
    }

    @Test("Markdown rendering has one cold inline-attribution construction and no view parser")
    func markdownParserOwnership() throws {
        let renderer = try String(
            contentsOf: packageRoot.appending(path: "Sources/UI/Chat/TronMarkdownView.swift"),
            encoding: .utf8
        )
        let presentation = try String(
            contentsOf: packageRoot.appending(path: "Sources/UI/Chat/MarkdownPresentation.swift"),
            encoding: .utf8
        )

        #expect(!renderer.contains("AttributedString("))
        #expect(presentation.matches(#"\bAttributedString\s*\("#) == 1)
        #expect(presentation.contains("blocks = ColdParser.parse(source)"))
    }

    @Test("bounded text preparation stays off-main, exact-source keyed, and renderer supplied")
    func boundedTextPreparationOwnership() throws {
        let cache = try String(
            contentsOf: packageRoot.appending(path: "Sources/UI/Chat/ChatTextPreparation.swift"),
            encoding: .utf8
        )
        let store = try String(
            contentsOf: packageRoot.appending(path: "Sources/UI/Chat/ChatTranscriptPresentationStore.swift"),
            encoding: .utf8
        )
        let transcript = try String(
            contentsOf: packageRoot.appending(path: "Sources/UI/Chat/TranscriptRow.swift"),
            encoding: .utf8
        )
        #expect(cache.contains("actor ChatTextPreparationCache"))
        #expect(cache.contains("maximumAccountedBytes = 4 * 1_024 * 1_024"))
        #expect(cache.contains("maximumConcurrentPreparations = 2"))
        #expect(cache.contains("maximumSourceBytes = 320_000"))
        #expect(cache.contains("snapshot.transcript.suffix(ChatTranscriptPageRequest.maximumItemCount)"))
        #expect(store.contains("preparedTextByRenderedID: built.preparedTextByRenderedID"))
        #expect(store.contains("handleMemoryPressure()"))
        #expect(transcript.contains("TronMarkdownView(document: document"))
        #expect(transcript.contains("preparedText.thinkingInline("))
        #expect(!cache.contains("Task.sleep"))
        #expect(!cache.contains("Task.yield"))
    }

    @Test("app-owned UI never falls back to system fonts or stock bordered controls")
    func noRetiredDefaults() {
        let forbidden: [(String, String)] = [
            (#"\.font\(\.(largeTitle|title|title2|title3|headline|subheadline|body|callout|footnote|caption|caption2)"#, "system semantic font"),
            (#"\.font\(\.system"#, "direct system font"),
            (#"\.buttonStyle\(\.(bordered|borderedProminent)"#, "stock bordered button"),
            (#"\.pickerStyle\(\.segmented"#, "stock segmented control"),
            (#"\.searchable\("#, "system search field"),
            (#"\.textFieldStyle\(\.(roundedBorder|automatic)"#, "stock text-field style"),
            (#"borderStyle\s*=\s*\.roundedRect"#, "UIKit rounded-rect field"),
            (#"ProgressView\(\s*\""#, "system-font ProgressView label"),
            (#"(?<![A-Za-z0-9_])Section\(\""#, "system-generated section header"),
            (#"\.navigationTitle\(\"[^\"]+\"\)"#, "system navigation title"),
        ]

        for (url, source) in uiSources {
            for (pattern, description) in forbidden {
                if description == "system-generated section header",
                   url.lastPathComponent == "TerminalSheet.swift" {
                    // Native Menu sections group terminal actions without
                    // introducing stock section chrome into app content.
                    continue
                }
                #expect(
                    source.range(of: pattern, options: .regularExpression) == nil,
                    "\(url.lastPathComponent) contains a \(description)"
                )
            }
        }
    }

    @Test("settings and modal details use composed glass groups instead of stock collections")
    func noStockSettingsCollections() {
        let composedOwners = [
            "AgentDefaultsSettingsView.swift", "AppearanceSettingsView.swift", "ConnectionSettingsView.swift",
            "CustomModelsSettingsView.swift", "GatewayDiagnosticsView.swift", "GatewayLogsSettingsView.swift", "PackagesSettingsView.swift", "ProviderSettingsView.swift",
            "ResourceSettingsView.swift", "RuntimeBehaviorSettingsView.swift", "SettingsView.swift", "NotificationInboxView.swift", "ProjectResourcesView.swift", "ExtensionInteractionSheet.swift",
            "SessionContextSheet.swift", "SessionTreeSheet.swift",
        ]
        for (url, source) in uiSources where composedOwners.contains(url.lastPathComponent) {
            #expect(source.matches(#"\b(Form|List)(\([^\n]*\))?\s*\{"#) == 0,
                    "\(url.lastPathComponent) contains a stock collection surface")
        }
    }

    @Test("every app-owned collection uses the Tron surface")
    func collectionSurfaces() {
        let pattern = #"\b(Form|List)(\([^\n]*\))?\s*\{"#
        for (url, source) in uiSources where url.lastPathComponent != "TronPresentation.swift" {
            let collectionCount = source.matches(pattern)
            let surfaceCount = source.matches(#"\.tronCollectionSurface\(\)"#)
            #expect(
                surfaceCount >= collectionCount,
                "\(url.lastPathComponent) has \(collectionCount) Form/List surfaces but only \(surfaceCount) Tron surfaces"
            )
        }
    }

    @Test("app-owned text inputs use shared field surfaces")
    func fieldSurfaces() {
        let systemAlertFields = [
            #"TextField("Name", text: $newFolder)"#,
            #"TextField("Label", text: $label)"#,
            #"TextField("Name", text: $name)"#,
            #"TextField("Session name", text: $renameName)"#,
        ]

        for (url, source) in uiSources where url.lastPathComponent != "TronPresentation.swift" {
            let lines = source.components(separatedBy: .newlines)
            for (index, line) in lines.enumerated()
            where line.contains("TextField(") || line.contains("SecureField(") || line.contains("TextEditor(") {
                if line.contains("UITextField(") || systemAlertFields.contains(where: line.contains) { continue }
                let end = min(lines.count, index + 40)
                let neighborhood = lines[index..<end].joined(separator: "\n")
                let styled = neighborhood.contains(".tronField(")
                    || neighborhood.contains(".tronComposerField(")
                    || neighborhood.contains(".tronInlineField(")
                    || neighborhood.contains(".tronTextEditor(")
                #expect(styled, "\(url.lastPathComponent):\(index + 1) does not use a shared Tron field surface")
            }
        }
    }

    @Test("app-owned sheets use one top-right confirmation dismissal and actionable cards omit disclosure chevrons")
    func sheetAndCardConventions() throws {
        let presentation = try String(
            contentsOf: packageRoot.appending(path: "Sources/UI/Theme/TronPresentation.swift"),
            encoding: .utf8
        )
        #expect(presentation.contains("struct TronConfirmationSheet: View"))
        #expect(presentation.contains(".tronNavigationTitle(\"Confirm\", accent: .tronEmerald)"))
        #expect(presentation.contains(".presentationDetents([.medium])"))
        #expect(presentation.contains("ToolbarItem(placement: .topBarLeading)"))
        #expect(presentation.contains("ToolbarItem(placement: .topBarTrailing)"))
        #expect(presentation.contains("if placement == .toolbar"))
        #expect(presentation.contains("if placement == .content"))
        #expect(presentation.contains(".tronToolbarAction(accent: .tronTextSecondary)"))
        #expect(presentation.contains("TronActionButtonStyle(role: destructive ? .destructive : .primary)"))

        for (url, source) in uiSources {
            #expect(
                !source.contains("ToolbarItem(placement: .cancellationAction)"),
                "\(url.lastPathComponent) contains a top-left sheet dismissal"
            )
            #expect(
                !source.contains(".confirmationDialog("),
                "\(url.lastPathComponent) uses an anchored confirmation instead of a full Tron sheet"
            )
            let allowedNavigationChevrons = url.lastPathComponent == "OnboardingView.swift"
                || url.lastPathComponent == "AuthPromptSheet.swift"
                || url.lastPathComponent == "RuntimeBehaviorSettingsView.swift"
                || url.lastPathComponent == "SessionShellView.swift"
                || url.lastPathComponent == "ConnectionSettingsView.swift"
                || url.lastPathComponent == "PairedDeviceDetailView.swift"
            if !allowedNavigationChevrons {
                #expect(
                    !source.contains("Image(systemName: \"chevron.right\")"),
                    "\(url.lastPathComponent) contains a decorative disclosure chevron"
                )
            }
        }
    }

    @Test("dashboard deletion waits for confirmation without destructive swipe removal")
    func dashboardDeletionConfirmationPolicy() throws {
        let source = try String(
            contentsOf: packageRoot.appending(path: "Sources/UI/Chat/SessionShellView.swift"),
            encoding: .utf8
        )
        let presentation = try String(
            contentsOf: packageRoot.appending(path: "Sources/UI/Theme/TronPresentation.swift"),
            encoding: .utf8
        )

        #expect(source.contains(#"confirmTitle: "Delete""#))
        #expect(source.contains("item: $sessionToDelete"))
        #expect(source.contains("onConfirm: { delete(session) }"))
        #expect(!source.contains("SessionShellDeletionConfirmationOwner"))
        #expect(!source.contains("confirmedDeletedDashboardIDs"))
        #expect(source.contains(#"Button("Delete", systemImage: "trash") { sessionToDelete = session }"#))
        #expect(source.contains(#".accessibilityIdentifier("session-row-\(session.dashboardID)")"#))
        #expect(source.contains(".tint(Color.tronError)"))
        #expect(source.contains(#".accessibilityIdentifier("session-delete-action-\(session.dashboardID)")"#))
        #expect(source.contains(#"session.isUnread ? "Mark Read" : "Mark Unread""#))
        #expect(source.contains(".tint(Color.gray)"))
        #expect(!source.contains(".tint(Color.tronCyan)"))
        #expect(source.contains(#".accessibilityIdentifier("session-attention-action-\(session.dashboardID)")"#))
        #expect(source.contains(#"session.isUnread ? "circle" : "circle.fill""#))
        #expect(source.contains(#"Button("Rename", systemImage: "pencil") { beginRename(session) }"#))
        #expect(source.contains(".tint(Color.tronEmerald)"))
        #expect(source.contains("let navigationIntent = navigationOwner.begin()"))
        #expect(source.contains("navigationOwner.admit(navigationIntent)"))
        #expect(source.contains("model.ownsNavigationRoute(route)"))
        #expect(source.contains("routeReplacementOwner.request("))
        #expect(source.contains("currentToken: mountedSessionRouteToken"))
        #expect(source.contains("completeRouteReplacement(afterRetiring: route.id, token: token)"))
        #expect(source.contains("catch is CancellationError { return }"))
        #expect(!source.contains(#"Button("Delete", systemImage: "trash", role: .destructive)"#))
        #expect(presentation.contains(".tronToolbarAction(accent: .tronTextSecondary)\n                        .accessibilityIdentifier(\"confirmation-cancel\")"))
    }

    @Test("session rename alerts keep a fixed native clear affordance")
    func sessionRenameClearAffordance() throws {
        let shell = try String(
            contentsOf: packageRoot.appending(path: "Sources/UI/Chat/SessionShellView.swift"),
            encoding: .utf8
        )
        let context = try String(
            contentsOf: packageRoot.appending(path: "Sources/UI/Chat/SessionContextSheet.swift"),
            encoding: .utf8
        )
        let alert = try String(
            contentsOf: packageRoot.appending(path: "Sources/UI/Components/TronTextEntryAlert.swift"),
            encoding: .utf8
        )

        #expect(shell.contains(".tronTextEntryAlert("))
        #expect(context.contains(".tronTextEntryAlert("))
        #expect(!shell.contains(".alert(\"Rename Session\""))
        #expect(!context.contains(".alert(\"Rename Session\""))
        #expect(alert.contains("field.clearButtonMode = .whileEditing"))
        #expect(alert.contains("field.returnKeyType = .done"))
        #expect(alert.contains("func textFieldShouldClear"))
        #expect(alert.contains("updateSaveAdmission(value)"))
        #expect(alert.contains("configuration.onConfirm(value)"))
        #expect(alert.contains("!value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty"))
    }

    @Test("dashboard retry and opening deadlines remain bounded without capped dirty attempts")
    func dashboardRetryAndOpeningDeadlinePolicy() throws {
        let appModel = try String(
            contentsOf: packageRoot.appending(path: "Sources/State/AppModel.swift"),
            encoding: .utf8
        )
        let pool = try String(
            contentsOf: packageRoot.appending(path: "Sources/State/DashboardGatewayConnectionPool.swift"),
            encoding: .utf8
        )
        let presentation = try String(
            contentsOf: packageRoot.appending(path: "Sources/State/SessionPresentationStore.swift"),
            encoding: .utf8
        )
        #expect(appModel.contains("catalogSatisfiedGeneration < self.catalogInvalidationGeneration"))
        #expect(pool.contains("current.refreshSatisfiedGeneration < current.refreshInvalidationGeneration"))
        #expect(!pool.contains("maximumRefreshRetryAttempts"))
        #expect(appModel.contains("timeout: .seconds(10)"))
        #expect(pool.contains("timeout: .seconds(10)"))
        #expect(presentation.contains(#""session.open","#))
        #expect(presentation.contains("timeout: .seconds(20)"))
        #expect(presentation.contains("for attempt in 0..<3"))
        #expect(presentation.contains("throughCompletionRevision: response.completionRevision"))
        #expect(presentation.contains("connectionGeneration == expectedConnectionGeneration"))
        #expect(presentation.contains("subscriptionTarget == target"))
        #expect(presentation.contains("throw CancellationError()"))
        #expect(presentation.contains(#""session.presentation.set""#))
        #expect(presentation.contains("presentationLeaseRenewalInterval"))
        #expect(presentation.components(separatedBy: "timeout: .seconds(5)").count >= 3)
    }

    @Test("confirmation actions use adaptive toolbar placement")
    func confirmationActionPlacement() {
        #expect(TronConfirmationActionPlacementPolicy.placement(
            measuredTitleWidth: 80,
            toolbarBudget: 100,
            isAccessibilitySize: false,
            containsLineBreak: false
        ) == .toolbar)
        #expect(TronConfirmationActionPlacementPolicy.placement(
            measuredTitleWidth: 101,
            toolbarBudget: 100,
            isAccessibilitySize: false,
            containsLineBreak: false
        ) == .content)
        #expect(TronConfirmationActionPlacementPolicy.placement(
            measuredTitleWidth: 80,
            toolbarBudget: 100,
            isAccessibilitySize: true,
            containsLineBreak: false
        ) == .content)
        #expect(TronConfirmationActionPlacementPolicy.placement(
            measuredTitleWidth: 80,
            toolbarBudget: 100,
            isAccessibilitySize: false,
            containsLineBreak: true
        ) == .content)
    }

    @Test("jitter-prone sheets use lazy or static scrolling presentation")
    func denseSheetPerformancePolicy() throws {
        let presentation = try String(
            contentsOf: packageRoot.appending(path: "Sources/UI/Theme/TronPresentation.swift"),
            encoding: .utf8
        )
        let context = try String(
            contentsOf: packageRoot.appending(path: "Sources/UI/Chat/SessionContextSheet.swift"),
            encoding: .utf8
        )
        let history = try String(
            contentsOf: packageRoot.appending(path: "Sources/UI/Chat/SessionTreeSheet.swift"),
            encoding: .utf8
        )
        let resources = try String(
            contentsOf: packageRoot.appending(path: "Sources/UI/Settings/ProjectResourcesView.swift"),
            encoding: .utf8
        )
        let runtime = try String(
            contentsOf: packageRoot.appending(path: "Sources/UI/Settings/RuntimeBehaviorSettingsView.swift"),
            encoding: .utf8
        )
        let connections = try String(
            contentsOf: packageRoot.appending(path: "Sources/UI/Settings/ConnectionSettingsView.swift"),
            encoding: .utf8
        )
        #expect(presentation.contains("struct TronScrollSurfaceModifier"))
        #expect(context.contains("TronReadOnlyTextView(text: summary.instructions)"))
        #expect(history.contains("Task.detached(priority: .userInitiated)"))
        #expect(history.contains(".tronScrollSurface(accent: accent"))
        #expect(resources.contains("overviewSections"))
        #expect(resources.contains("surfaceStyle: .scrollOptimized"))
        #expect(runtime.contains("LazyVStack(alignment: .leading, spacing: 18)"))
        #expect(connections.contains("GatewayTechnicalIdentityRow(detail: detail)"))
    }

    @Test("workspace folder rows own their complete glass hit region")
    func workspaceFolderHitRegion() throws {
        let browser = try String(
            contentsOf: packageRoot.appending(path: "Sources/UI/Onboarding/WorkspaceBrowser.swift"),
            encoding: .utf8
        )
        let owner = try String(
            contentsOf: packageRoot.appending(path: "Sources/UI/Onboarding/WorkspaceBrowserOwner.swift"),
            encoding: .utf8
        )
        #expect(browser.contains("@State private var loadOwner = WorkspaceBrowserOwner()"))
        #expect(browser.contains(".onDisappear { loadOwner.cancel() }"))
        #expect(!browser.contains("defer { navigating = false; loading = false }"))
        #expect(owner.contains("guard self.generation == generation else { return }"))
        #expect(owner.contains("flight?.cancel()"))
        #expect(owner.contains("loading = !navigation"))
        #expect(owner.contains("func createFolder("))
        #expect(browser.contains("let parent = currentPath"))
        let folderRows = try #require(
            browser.components(separatedBy: "ForEach(directories)").dropFirst().first?
                .components(separatedBy: "private func browserGroup").first
        )
        #expect(folderRows.contains(".frame(maxWidth: .infinity, alignment: .leading)"))
        #expect(folderRows.contains(".contentShape(Rectangle())"))
        #expect(folderRows.contains(".tronGlassSurface(accent: .tronSlate"))
    }

    @Test("onboarding chrome retains the established control geometry")
    func onboardingChromeGeometry() throws {
        let onboarding = try String(
            contentsOf: packageRoot.appending(path: "Sources/UI/Onboarding/OnboardingView.swift"),
            encoding: .utf8
        )
        let components = try String(
            contentsOf: packageRoot.appending(path: "Sources/UI/Onboarding/OnboardingPresentationComponents.swift"),
            encoding: .utf8
        )
        let presentation = try String(
            contentsOf: packageRoot.appending(path: "Sources/UI/Theme/TronPresentation.swift"),
            encoding: .utf8
        )
        #expect(!onboarding.contains("struct PairingCodeField"))
        #expect(components.contains("struct OnboardingNavigationTitle"))
        #expect(components.contains("struct PairingCodeField"))
        #expect(components.contains("struct OnboardingPage"))
        #expect(components.contains("struct OnboardingCard"))
        #expect(onboarding.contains(".padding(.horizontal, 10)\n        .padding(.vertical, 6)"))
        #expect(onboarding.contains(".frame(width: value == step ? 16 : 6, height: 6)"))
        #expect(onboarding.contains("Label(\"Back\", systemImage: \"chevron.left\")"))
        #expect(onboarding.contains("Label(\"Next\", systemImage: \"chevron.right\")"))
        #expect(!onboarding.contains("Text(\"Connect\").tronToolbarAction()"))
        let toolbarModifier = presentation.components(separatedBy: "func tronToolbarAction").dropFirst().first ?? ""
        #expect(!toolbarModifier.prefix(300).contains("glassEffect"))
        #expect(toolbarModifier.prefix(180).contains(".tronEmerald"))
    }

    @Test("light chat chrome masks moving transcript rows beneath the toolbar")
    func lightChatChromeMask() throws {
        let blur = try String(
            contentsOf: packageRoot.appending(path: "Sources/UI/Chat/ChatTopVariableBlur.swift"),
            encoding: .utf8
        )
        #expect(blur.contains("Color.tronBackground.opacity(0.98)"))
        #expect(blur.contains("Color.tronBackground.opacity(0.94)"))
        #expect(blur.contains("Color.clear"))
    }

    @Test("terminal sheet, presentation lifecycle, and native renderer stay separated")
    func terminalSourceOwnership() throws {
        let sheet = try String(
            contentsOf: packageRoot.appending(path: "Sources/UI/Terminal/TerminalSheet.swift"),
            encoding: .utf8
        )
        let presentation = try String(
            contentsOf: packageRoot.appending(path: "Sources/UI/Terminal/TerminalPresentationController.swift"),
            encoding: .utf8
        )
        let renderer = try String(
            contentsOf: packageRoot.appending(path: "Sources/UI/Terminal/TerminalRenderer.swift"),
            encoding: .utf8
        )
        #expect(sheet.contains("struct TerminalSheet: View"))
        #expect(sheet.contains("NativeTerminal("))
        #expect(sheet.contains("isInteractive: controller.isRunning(model: model)"))
        #expect(sheet.contains("Section(\"Open terminals\")"))
        #expect(sheet.contains("Section(\"Recent terminals\")"))
        #expect(!sheet.contains(".alert(\"Terminal action failed\""))
        #expect(!sheet.contains("Task { await controller"))
        #expect(!sheet.contains("final class TerminalController"))
        #expect(!sheet.contains("UIViewRepresentable"))
        #expect(presentation.contains("final class TerminalController"))
        #expect(presentation.contains("private var lifecycleFlight: LifecycleFlight?"))
        #expect(presentation.contains("private var pendingLifecycleRequest: LifecycleRequest?"))
        #expect(presentation.contains("model.presentError(error, scope: noticeScope)"))
        #expect(presentation.contains("func start(sessionID: String, model: AppModel)"))
        #expect(!presentation.contains("import SwiftTerm"))
        #expect(!presentation.contains("UIViewRepresentable"))
        #expect(renderer.contains("struct NativeTerminal: UIViewRepresentable"))
        #expect(renderer.contains("if !isInteractive"))
        #expect(renderer.contains("view.resignFirstResponder()"))
        #expect(renderer.contains("allowsTerminalInput"))
        #expect(renderer.contains("stopCursorBlinking"))
        #expect(renderer.contains("canBecomeFirstResponder"))
        #expect(renderer.contains("final class TerminalKeyboardController"))
        #expect(renderer.contains("final class TronNativeTerminalView"))
        #expect(!renderer.contains("AppModel"))
    }

    @Test("dashboard header and row share the historical icon anchor")
    func dashboardAlignment() throws {
        let shell = try String(
            contentsOf: packageRoot.appending(path: "Sources/UI/Chat/SessionShellView.swift"),
            encoding: .utf8
        )
        #expect(shell.contains("rowContainerHorizontalInset + rowContentHorizontalPadding"))
        #expect(shell.contains(".padding(.leading, SessionDashboardLayout.headerLeadingPadding)"))
        #expect(shell.contains(".padding(.horizontal, SessionDashboardLayout.rowContentHorizontalPadding)"))

        let rowStart = try #require(shell.range(of: "private struct HistoricalSessionRow"))
        let row = String(shell[rowStart.lowerBound...])
        let title = try #require(row.range(of: "Text(session.title)")?.lowerBound)
        let fork = try #require(row.range(of: "Image(systemName: \"arrow.triangle.branch\")")?.lowerBound)
        let elapsed = try #require(row.range(of: "Text(trailingStatus)")?.lowerBound)
        #expect(title < fork)
        #expect(fork < elapsed)
    }

    @Test("dashboard navigation and search require explicit user intent")
    func dashboardNavigationAndSearch() throws {
        let shell = try String(
            contentsOf: packageRoot.appending(path: "Sources/UI/Chat/SessionShellView.swift"),
            encoding: .utf8
        )
        let newSession = try String(
            contentsOf: packageRoot.appending(path: "Sources/UI/Chat/NewSessionSheet.swift"),
            encoding: .utf8
        )
        let sourceControl = try String(
            contentsOf: packageRoot.appending(path: "Sources/UI/Chat/NewSessionSourceControlSheet.swift"),
            encoding: .utf8
        )
        let presentation = try String(
            contentsOf: packageRoot.appending(path: "Sources/UI/Theme/TronPresentation.swift"),
            encoding: .utf8
        )
        let setup = try String(
            contentsOf: packageRoot.appending(path: "Sources/UI/Onboarding/SetupComponents.swift"),
            encoding: .utf8
        )
        #expect(shell.contains("NewSessionSheet(onCreated: present)"))
        #expect(!shell.contains("struct NewSessionSheet: View"))
        #expect(newSession.contains("@State private var configurationOwner = NewSessionConfigurationOwner()"))
        #expect(newSession.contains("@State private var creationOwner = NewSessionCreationOwner()"))
        #expect(newSession.contains("title: \"Server\""))
        #expect(newSession.contains("ForEach(quickSelections)"))
        #expect(newSession.contains("selectQuickSelection"))
        #expect(newSession.contains("NewSessionSourceControlSheet"))
        #expect(newSession.contains("private func selectServer(_ profile: GatewayProfile)"))
        #expect(newSession.contains("session.gatewayProfileID == profileID"))
        #expect(newSession.contains("model.profiles.selected?.id == profileID"))
        #expect(newSession.contains(".task(id: PresentationActivityTaskID("))
        #expect(newSession.contains("source: NewSessionConfigurationLoadID("))
        #expect(newSession.contains("presentationActive: presentationActivity.allowsPresentationPublication"))
        #expect(newSession.contains("title: \"Project Trust\""))
        #expect(newSession.contains("value: \"Untrusted\""))
        #expect(newSession.contains(".transition(reduceMotion ? .opacity : .move(edge: .top).combined(with: .opacity))"))
        #expect(newSession.contains("identity: \"new-session.project-trust\""))
        #expect(newSession.contains("confirmTitle: \"Trust\""))
        #expect(newSession.contains("alwaysUsesToolbarActions: true"))
        #expect(newSession.contains("this session will open without project resources"))
        #expect(newSession.contains("NewSessionTrustPolicy.decisionBeforeCreation(trustInspection)"))
        #expect(!newSession.contains("Button(\"Open Without Project Resources\")"))
        #expect(newSession.contains(".disabled(creating || !configurationReady)"))
        #expect(shell.contains("@State private var presentedSession: AppModel.SessionNavigationRoute?"))
        #expect(shell.contains(".navigationDestination(item: $presentedSession)"))
        #expect(shell.contains("initialEditorText: route.editorText"))
        #expect(shell.contains("onForkCreated: present"))
        #expect(shell.contains("model.revokePresentationIntake(target)"))
        #expect(!shell.contains("NavigationSplitView"))
        #expect(!shell.contains("List(selection:"))
        #expect(!shell.contains(".onChange(of: model.selectedSessionID)"))
        #expect(shell.contains("ZStack(alignment: .bottom)"))
        #expect(shell.contains(".ignoresSafeArea(.keyboard, edges: .bottom)"))
        #expect(shell.contains("private var dashboardSearchControl: some View"))
        #expect(shell.contains("onClose: dismissDashboardSearch"))
        #expect(shell.contains("onFocusChange: { focused in"))
        #expect(shell.contains("DragGesture(minimumDistance: 16)"))
        #expect(shell.contains("focusOnAppear: true"))
        let serverFilter = try #require(
            shell.components(separatedBy: "private var serverFilterSheet: some View").dropFirst().first?
                .components(separatedBy: "private func setSortMode").first
        )
        #expect(serverFilter.contains("Image(systemName: \"checkmark\")"))
        #expect(serverFilter.contains(".accessibilityLabel(\"Done\")"))
        #expect(!serverFilter.contains("Button(\"Done\")"))
        #expect(sourceControl.contains("HStack(alignment: .center, spacing: 12)"))
        #expect(!sourceControl.contains("HStack(alignment: .top, spacing: 12)"))
        #expect(sourceControl.matches(#"\.tronField\("#) == 2)
        #expect(presentation.contains("Text(focused ? \"\" : prompt)"))
        #expect(presentation.contains(".glassEffect(.regular.tint(accent.opacity(0.16))"))
        #expect(presentation.contains("onFocusChange?(isFocused)"))
        #expect(setup.contains(".regular.tint((settingsTheme?.accent ?? .tronEmerald).opacity(0.16)).interactive()"))
        #expect(setup.contains(".interactiveDismissDisabled(showingSearch)"))
        #expect(setup.contains("Task.sleep(for: .milliseconds(300))"))
        #expect(setup.contains("onClose: closeSearch"))
        #expect(shell.contains("Button(\"Rename\", systemImage: \"pencil\")"))
        #expect(shell.contains("model.renameSession(session.id, name: name)"))
    }

    @Test("settings containers disclose progressive sub sheets")
    func progressiveSettingsSheets() throws {
        let settings = try String(
            contentsOf: packageRoot.appending(path: "Sources/UI/Settings/SettingsView.swift"),
            encoding: .utf8
        )
        let providerSettings = try String(
            contentsOf: packageRoot.appending(path: "Sources/UI/Settings/ProviderSettingsView.swift"),
            encoding: .utf8
        )
        let providers = try String(
            contentsOf: packageRoot.appending(path: "Sources/UI/Onboarding/SetupComponents.swift"),
            encoding: .utf8
        )
        let providerAuth = try String(
            contentsOf: packageRoot.appending(path: "Sources/UI/Onboarding/AuthPromptSheet.swift"),
            encoding: .utf8
        )
        let appearance = try String(
            contentsOf: packageRoot.appending(path: "Sources/UI/Settings/AppearanceSettingsView.swift"),
            encoding: .utf8
        )
        let connections = try String(
            contentsOf: packageRoot.appending(path: "Sources/UI/Settings/ConnectionSettingsView.swift"),
            encoding: .utf8
        )
        let logs = try String(
            contentsOf: packageRoot.appending(path: "Sources/UI/Settings/GatewayLogsSettingsView.swift"),
            encoding: .utf8
        )
        let defaults = try String(
            contentsOf: packageRoot.appending(path: "Sources/UI/Settings/AgentDefaultsSettingsView.swift"),
            encoding: .utf8
        )
        let runtime = try String(
            contentsOf: packageRoot.appending(path: "Sources/UI/Settings/RuntimeBehaviorSettingsView.swift"),
            encoding: .utf8
        )
        let resources = try String(
            contentsOf: packageRoot.appending(path: "Sources/UI/Settings/ResourceSettingsView.swift"),
            encoding: .utf8
        )
        let customModels = try String(
            contentsOf: packageRoot.appending(path: "Sources/UI/Settings/CustomModelsSettingsView.swift"),
            encoding: .utf8
        )
        let trust = try String(
            contentsOf: packageRoot.appending(path: "Sources/UI/Settings/TrustSettingsView.swift"),
            encoding: .utf8
        )
        let presentation = try String(
            contentsOf: packageRoot.appending(path: "Sources/UI/Theme/TronPresentation.swift"),
            encoding: .utf8
        )
        let structuredJSON = try String(
            contentsOf: packageRoot.appending(path: "Sources/UI/Components/StructuredJSONView.swift"),
            encoding: .utf8
        )
        #expect(!settings.contains("NavigationLink"))
        #expect(settings.contains("struct TronProgressiveSheetLink"))
        #expect(!settings.contains("struct AppearanceSettingsView"))
        #expect(appearance.contains("struct AppearanceSettingsView"))
        #expect(appearance.contains("TronSegmentedControl"))
        #expect(appearance.contains("minimumHeight: 40"))
        #expect(!appearance.contains(".frame(minHeight: 44, alignment: .leading)"))
        #expect(!appearance.contains("TronSettingsGroup(\"Color Mode\""))
        #expect(!appearance.contains(".pickerStyle(.segmented)"))
        #expect(appearance.contains("icon: \"textformat.size\""))
        #expect(appearance.contains("icon: \"slider.horizontal.3\""))
        #expect(appearance.contains("titleFont: TronFontLoader.createFont("))
        #expect(appearance.contains("family: family"))
        let textFontSection = (appearance.components(separatedBy: "TronSettingsGroup(\"Text Font\"").dropFirst().first ?? "")
            .components(separatedBy: "TronSettingsGroup(\"Code Font\"").first ?? ""
        let textSlider = try #require(textFontSection.firstRange(of: "axisSlider(")?.lowerBound)
        let textPreview = try #require(textFontSection.firstRange(of: "The quick brown fox")?.lowerBound)
        #expect(textSlider < textPreview)
        let codeFontSection = (appearance.components(separatedBy: "TronSettingsGroup(\"Code Font\"").dropFirst().first ?? "")
            .components(separatedBy: "Text(\"About Fonts\")").first ?? ""
        let codeSlider = try #require(codeFontSection.firstRange(of: "axisSlider(")?.lowerBound)
        let codePreview = try #require(codeFontSection.firstRange(of: "let result = await tron.run()")?.lowerBound)
        #expect(codeSlider < codePreview)
        #expect(connections.contains("struct ConnectionsSettingsView"))
        #expect(connections.contains("struct ImportSettingsView"))
        #expect(!connections.contains("model.loadGatewayLogs"))
        #expect(logs.contains("struct GatewayLogsSettingsView"))
        #expect(settings.contains("GatewayLogsSettingsView()"))
        let authorizedDevicesPosition = try #require(connections.firstRange(of: "\"Authorized Devices\"")?.lowerBound)
        let pushNotificationsPosition = try #require(connections.firstRange(of: "\"Push Notifications\"")?.lowerBound)
        #expect(authorizedDevicesPosition < pushNotificationsPosition)
        #expect(connections.contains("serverDetailDetent"))
        #expect(connections.contains(".presentationDetents([.medium, .large], selection: $serverDetailDetent)"))
        #expect(connections.contains("gatewayActionButton"))
        #expect(providerSettings.contains("struct ProvidersSettingsView"))
        #expect(defaults.contains("struct AgentDefaultsSettingsView"))
        #expect(settings.contains("isPresented: $isPresented"))
        #expect(!settings.contains("Button(\"Log Out\""))
        #expect(settings.contains("enum Scope { case dashboard, project }"))
        #expect(settings.contains("if scope == .project"))
        #expect(settings.contains("ImportSettingsView(onImported: onImported)"))
        #expect(settings.contains("VStack(spacing: 18)"))
        #expect(settings.contains("summary: \"Theme, type scale, and visual preferences\""))
        #expect(settings.occurrences(of: "TronSettingsGroup(\"") == 3)
        #expect(settings.contains("TronSettingsGroup(\"App & Connections\""))
        #expect(settings.contains("TronSettingsGroup(\"Agent\""))
        #expect(settings.contains("TronSettingsGroup(\"Workspace & Diagnostics\""))
        #expect(!settings.contains("TronGlassCard("))
        #expect(settings.contains("private func settingsDivider(accent: Color)"))
        #expect(settings.contains("TronSettingsDivider(accent: accent)"))
        #expect(settings.contains("accent: .tronEmerald"))
        #expect(settings.contains("accent: .tronPurple"))
        #expect(settings.contains("accent: .tronBlue"))
        #expect(settings.contains("accent: accent,\n                subtitleColor: .tronTextSecondary"))
        #expect(settings.contains("destination().tronSettingsVisualTheme(accent: accent)"))
        #expect(presentation.contains("struct TronSettingsVisualTheme"))
        #expect(presentation.contains("informationalAccent = accent.mix(with: .tronSlate, by: 0.58)"))
        #expect(presentation.contains("settingsTheme?.informationalAccent ?? accent"))
        #expect(presentation.contains("var usesSemanticAccent = false"))
        #expect(presentation.contains("guard !usesSemanticAccent else { return accent }"))
        #expect(providerSettings.contains("usesSemanticAccent: loadFailed"))
        #expect(!trust.contains("usesSemanticAccent: true"))
        #expect(trust.contains("settingsTheme?.informationalAccent ?? .tronSlate"))
        #expect(trust.contains("accent: .tronSuccess"))
        #expect(presentation.contains("enum TronSettingsButtonContrastPolicy"))
        #expect(presentation.contains("colorScheme == .dark"))
        #expect(connections.contains(".tronSettingsButtonForeground(accent)"))
        #expect(connections.contains("respectsSettingsTheme: false"))
        #expect(settings.contains("subtitleColor: .tronTextSecondary"))
        #expect(!settings.contains("LazyVStack(spacing: 16)"))
        #expect(!settings.contains("Import Legacy Sessions"))
        #expect(!providerSettings.contains(".providerAuthPresenter()"))
        #expect(providers.contains("ProviderConfigurationSheet(provider: provider, target: providerTarget)"))
        #expect(providers.contains("ProviderAuthFlowContent()"))
        #expect(providers.contains(".presentationDetents([.medium, .large])"))
        #expect(providers.contains("Text(provider.configured ? \"Configure\" : \"Connect\")"))
        #expect(!providers.contains("systemImage: provider.configured ? \"slider.horizontal.3\" : \"key.fill\""))
        #expect(providers.contains(".navigationBarTitleDisplayMode(.inline)"))
        #expect(providers.contains("ProviderConfigurationPresentation.configurationDetail(for: provider)"))
        #expect(providers.contains("if isPresentingOwnedAuth"))
        #expect(providers.contains("\"Log In with a Different Account\""))
        #expect(providers.contains("\"Enter a New API Key\""))
        #expect(providers.contains("ProviderConfigurationPresentation.clearTitle(for: provider)"))
        #expect(providers.contains("cancelAuth(operationID: operationID)"))
        #expect(!providers.contains("Menu {"))
        #expect(!providers.contains("Image(systemName: \"ellipsis\")"))
        #expect(providerAuth.contains("struct ProviderAuthFlowContent"))
        #expect(providerAuth.contains("title: submitting ? \"Submitting…\" : (prompt.kind == .manualCode ? \"Complete Login\" : \"Save\")"))
        #expect(providerAuth.contains("systemImage: prompt.kind == .manualCode ? \"checkmark.shield\" : \"square.and.arrow.down\""))
        #expect(providerAuth.contains("isEnabled: !value.isEmpty && !submitting"))
        #expect(!providerAuth.contains("title: submitting ? \"Continuing…\" : \"Continue\""))
        #expect(providers.contains("provider.configured ? 0.14 : 0.08"))
        #expect(providers.contains("return \"Connected - "))
        #expect(!providers.contains("Label(\"Connected\""))
        #expect(providers.contains("TronTypography.secondaryCodeDescription"))
        #expect(providers.contains("TronTypography.secondaryDescription"))
        #expect(providers.contains(".lineLimit(1)"))
        #expect(providers.contains(".glassEffect("))
        #expect(defaults.contains("value: draft.trust.capitalized"))
        #expect(defaults.contains("TronInlineMenu(\"Change\", accent: .tronAmber)"))
        #expect(defaults.contains("\"Project Resources\","))
        #expect(defaults.contains("detail: \"Trust controls project resource loading; it is not a sandbox.\""))
        #expect(!defaults.contains("accessibilityLabel(\"Default Trust:"))
        #expect(!defaults.contains("Menu {"))
        #expect(defaults.contains("TronSaveToolbarButton"))
        #expect(defaults.contains("isEnabled: hasUnsavedChanges"))
        #expect(defaults.contains("drafts.hasChanges(draft, for: target)"))
        #expect(defaults.contains("ifCurrent: draft"))
        #expect(defaults.contains("drafts.seedBaselineIfMissing(draft, for: target)"))
        #expect(!defaults.contains("Save Defaults"))
        #expect(runtime.contains("TronSaveToolbarButton"))
        #expect(runtime.contains("isEnabled: hasUnsavedChanges"))
        #expect(runtime.contains("drafts.hasChanges(draft, for: target)"))
        #expect(runtime.contains("ifCurrent: draft"))
        #expect(runtime.contains("value: value"))
        #expect(runtime.contains("TronInlineMenu(\"Change\""))
        #expect(runtime.contains(".tronInlineField(numeric: true)"))
        #expect(runtime.contains("drafts.seedBaselineIfMissing(draft, for: target)"))
        #expect(!runtime.contains("Save Runtime Settings"))
        #expect(resources.contains("TronSaveToolbarButton"))
        #expect(resources.contains("isEnabled: hasUnsavedChanges"))
        #expect(resources.contains("drafts.hasChanges(draft, for: target)"))
        #expect(resources.contains("ifCurrent: draft"))
        #expect(resources.contains("value: summary(value, text: text)"))
        #expect(presentation.contains("enum TronSettingsSecondaryRole"))
        #expect(presentation.contains("enum TronSettingsRowSemantics"))
        #expect(presentation.contains("struct TronDynamicValue"))
        #expect(presentation.contains("enum TronToggleMotionPolicy"))
        #expect(presentation.contains("private struct TronToggleControl: View"))
        #expect(presentation.contains("@Environment(\\.accessibilityReduceMotion) private var reduceMotion"))
        #expect(presentation.contains(".phaseAnimator([false, true, false], trigger: isOn)"))
        #expect(presentation.contains("width: TronToggleMotionPolicy.controlWidth"))
        #expect(presentation.contains("height: TronToggleMotionPolicy.controlHeight"))
        #expect(presentation.contains("TronToggleControl(isOn: isOn, accent: resolvedAccent)"))
        #expect(presentation.contains(".accessibilityRepresentation"))
        #expect(presentation.contains("Toggle(isOn: $isOn) { Text(title) }"))
        #expect(resources.contains("pathEditor(value)"))
        #expect(resources.contains(".multilineTextAlignment(.leading)"))
        #expect(resources.contains("minHeight: value.acceptsMultipleLines ? 120 : 52"))
        #expect(resources.contains("TronInfoCard("))
        #expect(resources.contains("text: value.explanation"))
        #expect(resources.contains("drafts.seedBaselineIfMissing(draft, for: target)"))
        #expect(!resources.contains("Save Changes"))
        #expect(customModels.contains("TronSaveToolbarButton"))
        #expect(customModels.contains("isEnabled: canSave"))
        #expect(customModels.contains("editedAdvancedDocumentBinding"))
        #expect(customModels.contains("editedProviderBinding(provider.identifier)"))
        #expect(customModels.contains("editedProviderBinding(provider.baseURL)"))
        #expect(customModels.contains("editedProviderBinding(provider.models)"))
        #expect(!customModels.contains(".onChange(of: provider.wrappedValue)"))
        #expect(!customModels.contains("@FocusState private var advancedEditorFocused"))
        #expect(!customModels.contains("Save and Restart"))
        #expect(connections.contains("Button(importing ? \"Importing…\" : \"Import Legacy Sessions\")"))
        #expect(connections.contains("detail: acceptedOperationLabel ?? updateStatus.presentationTitle"))
        #expect(connections.contains("title: \"Deployment error\",\n                                    detail: String(error.prefix(2_048))"))
        #expect(connections.contains("title: \"Restart drain\",\n            detail: detail"))
        #expect(!connections.contains("title: \"Restart drain\",\n                value:"))
        #expect(trust.contains("summary.stateIcon"))
        #expect(trust.contains("frame(width: 38, height: 38)"))
        let saveToolbarButton = (presentation.components(separatedBy: "struct TronSaveToolbarButton").dropFirst().first ?? "")
            .components(separatedBy: "struct TronReloadToolbarButton").first ?? ""
        #expect(saveToolbarButton.contains(".tronToolbarAction(accent: actionColor)"))
        #expect(saveToolbarButton.contains(".tronTextMuted"))
        #expect(saveToolbarButton.contains("private var actionColor"))
        #expect(saveToolbarButton.contains("systemImage: \"square.and.arrow.down\""))
        #expect(saveToolbarButton.contains(".tint(actionColor)"))
        #expect(!saveToolbarButton.contains(".tronToolbarAction()"))
        #expect(!saveToolbarButton.contains(".foregroundStyle(actionColor)"))
        #expect(!saveToolbarButton.contains(".buttonStyle(.glass)"))
        #expect(!saveToolbarButton.contains(".buttonBorderShape(.capsule)"))
        let settingsRow = (presentation.components(separatedBy: "struct TronSettingsRow<Trailing: View>: View").dropFirst().first ?? "")
            .components(separatedBy: "extension TronSettingsRow where Trailing == EmptyView").first ?? ""
        let infoCard = (presentation.components(separatedBy: "struct TronInfoCard: View").dropFirst().first ?? "")
            .components(separatedBy: "struct TronSettingsDivider").first ?? ""
        let gatewayUpdateGroup = (connections.components(separatedBy: "private func gatewayUpdateGroup").dropFirst().first ?? "")
            .components(separatedBy: "private func gatewayActionButton").first ?? ""
        for alignedSurface in [settingsRow, infoCard] {
            #expect(alignedSurface.contains(".frame(width: 22, height: 22, alignment: .center)"))
            #expect(alignedSurface.contains(".padding(.horizontal, 14)"))
        }
        #expect(!gatewayUpdateGroup.contains(".padding(12)"))
        #expect(presentation.contains("static var numericValue"))
        #expect(presentation.contains("static var codeJSON"))
        #expect(structuredJSON.contains("TronTypography.codeJSON"))
    }

    @Test("authorized devices disclose supervised source build and fixed LocalDevice installation")
    func authorizedDeviceInstallPresentation() throws {
        let connections = try String(
            contentsOf: packageRoot.appending(path: "Sources/UI/Settings/ConnectionSettingsView.swift"),
            encoding: .utf8
        )
        let detail = try String(
            contentsOf: packageRoot.appending(path: "Sources/UI/Settings/PairedDeviceDetailView.swift"),
            encoding: .utf8
        )
        let model = try String(
            contentsOf: packageRoot.appending(path: "Sources/State/AppModel.swift"),
            encoding: .utf8
        )

        #expect(connections.contains("Button { selectedAuthorizedDevice = authorized }"))
        #expect(connections.contains("PairedDeviceDetailView(authorized: authorized)"))
        #expect(!connections.contains("deviceToRevoke"))
        #expect(detail.contains("title: \"Source Repository\""))
        #expect(!detail.contains("Physical Install Target"))
        #expect(!detail.contains("IosInstallTargetPicker"))
        #expect(detail.contains("sole eligible physical iOS device"))
        #expect(detail.contains("WorkspaceBrowser(initialPath: config?.sourceRoot)"))
        #expect(detail.contains("Text(installActive ? \"Build and Install Running\" : \"Rebuild and Install Tron\")"))
        #expect(detail.contains("fixed Tron Device + LocalDevice configuration"))
        #expect(detail.contains("without erasing app or Keychain data"))
        #expect(detail.contains("confirmTitle: \"Install\""))
        #expect(detail.contains("centersTitle: true"))
        #expect(detail.contains("alwaysUsesToolbarActions: true"))
        #expect(detail.contains("title: \"Use This Server\""))
        #expect(detail.contains("model.requestIosDeviceInstall(for: authorized)"))
        #expect(detail.contains(".foregroundStyle(Color.tronEmerald)"))
        #expect(detail.contains(".task(id: \"\\(authorized.id):\\(usesServer)\")"))
        #expect(!detail.contains("usesServer):\\(presentationActivity.allowsPresentationPublication)"))
        #expect(connections.contains("GatewayConnectionStatusBadge("))
        #expect(model.contains("capabilities.contains(\"ios-device-install.v2\")"))
        #expect(model.contains("method: \"device.install\""))
        #expect(!detail.contains("CoreDevice"))
        #expect(!detail.contains("TRON_IOS_DEVICE_ID"))
    }

    @Test("project resources and diagnostics use readable bounded presentations")
    func gatewayDetailPresentations() throws {
        let context = try String(
            contentsOf: packageRoot.appending(path: "Sources/UI/Chat/SessionContextSheet.swift"),
            encoding: .utf8
        )
        let resources = try String(
            contentsOf: packageRoot.appending(path: "Sources/UI/Settings/ProjectResourcesView.swift"),
            encoding: .utf8
        )
        let agentConfiguration = try String(
            contentsOf: packageRoot.appending(path: "Sources/UI/Settings/AgentConfigurationControls.swift"),
            encoding: .utf8
        )
        let agentDefaults = try String(
            contentsOf: packageRoot.appending(path: "Sources/UI/Settings/AgentDefaultsSettingsView.swift"),
            encoding: .utf8
        )
        let history = try String(
            contentsOf: packageRoot.appending(path: "Sources/UI/Chat/SessionTreeSheet.swift"),
            encoding: .utf8
        )
        let terminalSheet = try String(
            contentsOf: packageRoot.appending(path: "Sources/UI/Terminal/TerminalSheet.swift"),
            encoding: .utf8
        )
        let structuredJSON = try String(
            contentsOf: packageRoot.appending(path: "Sources/UI/Components/StructuredJSONView.swift"),
            encoding: .utf8
        )
        let interactions = try String(
            contentsOf: packageRoot.appending(path: "Sources/UI/Chat/ExtensionInteractionSheet.swift"),
            encoding: .utf8
        )
        let customModels = try String(
            contentsOf: packageRoot.appending(path: "Sources/UI/Settings/CustomModelsSettingsView.swift"),
            encoding: .utf8
        )
        let trust = try String(
            contentsOf: packageRoot.appending(path: "Sources/UI/Settings/TrustSettingsView.swift"),
            encoding: .utf8
        )
        let settings = try String(
            contentsOf: packageRoot.appending(path: "Sources/UI/Settings/ConnectionSettingsView.swift"),
            encoding: .utf8
        )
        let logs = try String(
            contentsOf: packageRoot.appending(path: "Sources/UI/Settings/GatewayLogsSettingsView.swift"),
            encoding: .utf8
        )
        let packages = try String(
            contentsOf: packageRoot.appending(path: "Sources/UI/Settings/PackagesSettingsView.swift"),
            encoding: .utf8
        )
        #expect(context.contains("ProjectResourcesView(sessionID: sessionID)"))
        #expect(context.contains("case agentContext, projectResources, history, processHistory, terminal"))
        #expect(context.contains("destination = .projectResources"))
        #expect(context.contains("TronSettingsGroup(\"Configuration\""))
        #expect(context.contains("TronModelSelectionRow("))
        #expect(context.contains("navigationTitle: \"Session Model\""))
        #expect(context.contains("TronThinkingSelectionRow("))
        #expect(agentConfiguration.contains("TronProgressiveSheetLink(accessibilityLabel: navigationTitle)"))
        #expect(agentConfiguration.contains("ModelPicker(selection: $selection, models: models)"))
        #expect(agentConfiguration.contains("TronInlineMenu(\"Change\", accent: accent)"))
        #expect(agentDefaults.contains("TronModelSelectionRow("))
        #expect(agentDefaults.contains("TronThinkingSelectionRow("))
        #expect(context.contains("TronSettingsGroup(\"Session\""))
        let configurationSection = (context.components(separatedBy: "private func configurationSection").dropFirst().first ?? "")
            .components(separatedBy: "private func sessionSection").first ?? ""
        let sessionSection = (context.components(separatedBy: "private func sessionSection").dropFirst().first ?? "")
            .components(separatedBy: "private var gitRow").first ?? ""
        let resourcesPosition = try #require(configurationSection.firstRange(of: "title: \"Project Resources\"")?.lowerBound)
        let renamePosition = try #require(configurationSection.firstRange(of: "title: \"Rename Session\"")?.lowerBound)
        #expect(resourcesPosition < renamePosition)
        #expect(!sessionSection.contains("title: \"Rename Session\""))
        #expect(!context.contains("TronSettingsGroup(\"Runtime\""))
        #expect(!context.contains("TronSettingsGroup(\"Export and Share\""))
        #expect(!context.contains("title: \"Reload Resources\""))
        #expect(!context.contains("@State private var showFork"))
        #expect(!context.contains("NavigationLink"))
        #expect(!context.contains("struct ForkSheet"))
        #expect(context.contains("private var configurationRowAccent: Color { .tronPurple }"))
        #expect(context.contains("private var sessionRowAccent: Color { .tronBlue }"))
        #expect(configurationSection.components(separatedBy: "accent: configurationRowAccent").count - 1 == 4)
        #expect(sessionSection.components(separatedBy: "accent: sessionRowAccent").count - 1 == 5)
        let gitSection = (context.components(separatedBy: "private var gitRow").dropFirst().first ?? "")
            .components(separatedBy: "private func divider").first ?? ""
        #expect(gitSection.components(separatedBy: "accent: sessionRowAccent").count - 1 == 4)
        let exportSection = (context.components(separatedBy: "private func exportRow").dropFirst().first ?? "")
            .components(separatedBy: "private func loadGit").first ?? ""
        #expect(exportSection.contains("accent: sessionRowAccent"))
        #expect(history.contains("let onNavigated: () -> Void"))
        #expect(history.contains("onNavigated()"))
        #expect(history.contains("case timeline = \"Timeline\""))
        #expect(!history.contains("Label(\"New Fork\""))
        #expect(!history.contains("choosingFork"))
        #expect(!history.contains("private var branchRail"))
        #expect(history.contains("Button(\"Fork New Session\", systemImage: \"arrow.triangle.branch\", action: fork)"))
        #expect(history.contains("private enum SessionHistoryCardMetrics"))
        #expect(history.components(separatedBy: ".frame(width: SessionHistoryCardMetrics.iconWidth, height: 20").count - 1 == 3)
        #expect(history.contains("static let verticalPadding: CGFloat = TronSpacing.md"))
        #expect(history.contains("LazyVStack(alignment: .leading, spacing: TronSpacing.md)"))
        let eventRows = (history.components(separatedBy: "private struct TreeNodeRow").dropFirst().first ?? "")
            .components(separatedBy: "private struct HistoryEntryDetailsSheet").first ?? ""
        #expect(eventRows.contains("Text(row.title)\n                                .font(TronTypography.sans(size: TronTypography.sizeBodySM, weight: .semibold))"))
        #expect(!eventRows.contains("Text(row.title)\n                                .font(TronTypography.body)"))
        #expect(!eventRows.contains("Text(row.title)\n                                .font(TronTypography.headline)"))
        #expect(!history.contains(".glassEffect(.regular.tint(accent.opacity(0.14)).interactive(), in: .circle)"))
        #expect(history.contains(".frame(width: 44, height: 44)\n                    .contentShape(Rectangle())"))
        let detailActions = (history.components(separatedBy: "TronSettingsGroup(\"Actions\"").dropFirst().first ?? "")
            .components(separatedBy: "private func actionRow").first ?? ""
        let bookmarkAction = try #require(detailActions.firstRange(of: "Add Bookmark")?.lowerBound)
        let forkAction = try #require(detailActions.firstRange(of: "Fork New Session")?.lowerBound)
        #expect(bookmarkAction < forkAction)
        #expect(resources.contains("TronToolbarTextLabel(\n                            \"Reload\""))
        #expect(resources.contains("try await model.reloadResources(sessionID: sessionID)"))
        let reloadOwner = (resources.components(separatedBy: "private func reload()").dropFirst().first ?? "")
            .components(separatedBy: "private func load()").first ?? ""
        #expect(!reloadOwner.contains("await model.loadResources("))
        #expect(resources.contains("@State private var reloading = false"))
        #expect(resources.contains("@State private var loadGeneration = 0"))
        #expect(resources.contains("generation == loadGeneration else { return }"))
        #expect(resources.contains("loading || reloading"))
        #expect(resources.contains("ToolbarItem(placement: .topBarLeading)"))
        #expect(resources.contains("TronSheetTitle(title: \"Project Resources\")"))
        #expect(context.contains("snapshot.stats.latestCacheHitRate"))
        #expect(context.contains("ProgressView(value: percent, total: 100)"))
        #expect(context.contains(".accessibilityLabel(usage.accessibilityLabel)"))
        #expect(context.contains("Context usage: "))
        #expect(context.contains("Image(systemName: \"rectangle.compress.vertical\")"))
        #expect(context.contains("Text(\"Compact\")"))
        #expect(context.contains("SessionCompactionControlPolicy.automaticStatus"))
        #expect(context.contains("contextAndCompactionRow(contextValue: contextValue, snapshot: snapshot)"))
        #expect(context.contains(".lineLimit(1)"))
        #expect(context.contains(".accessibilityLabel(\"Context usage: \\(contextValue)\")"))
        #expect(!context.contains("Text(\"Context\")"))
        #expect(!context.contains("(contextValue, \"Context\")"))
        #expect(context.contains("(cacheValue, \"Cache Hit\")"))
        #expect(context.contains("\"Read / Write\""))
        #expect(!context.contains("cacheValue)\\nR"))
        #expect(!context.contains("title: \"Automatic Compaction\""))
        #expect(!context.contains("title: \"Runtime\""))
        #expect(history.contains("private func runtimeSummary(_ snapshot: SessionSnapshot)"))
        #expect(context.contains("title: \"Read Full Instructions\""))
        #expect(context.contains("TronTechnicalJSONRow("))
        #expect(!context.contains("DisclosureGroup(isExpanded: $showRaw)"))
        #expect(structuredJSON.contains("struct TronTechnicalJSONRow: View"))
        #expect(structuredJSON.contains("TronReadOnlyTextView(text: document ?? \"\", style: .code)"))
        #expect(!structuredJSON.contains("ScrollView([.horizontal, .vertical]"))
        #expect(structuredJSON.contains(".fixedSize(horizontal: false, vertical: true)"))
        #expect(structuredJSON.contains(".presentationDetents([.medium, .large], selection: $detent)"))
        #expect(structuredJSON.contains("detent = .medium"))
        #expect(!structuredJSON.contains("showRaw.toggle()"))
        #expect(!structuredJSON.contains("Hide raw JSON"))
        #expect(context.contains("guard SessionExportPresentationPolicy.canStart(activeFormat: exportingFormat) else { return }"))
        #expect(context.contains("SessionExportPresentationPolicy.showsProgress"))
        #expect(context.contains(".disabled(!SessionExportPresentationPolicy.canStart"))
        #expect(context.contains("format == \"jsonl\" ? \"JSONL Export\" : \"HTML Export\""))
        #expect(context.contains("model.presentError(error, scope: noticeScope)"))
        #expect(!context.contains("exportError"))
        #expect(!context.contains("title: exporting"))
        #expect(context.contains("await model.discardExportArtifact(exportedURL)"))
        for action in ["renameSession", "compact", "setModel", "setThinking", "reloadResources"] {
            #expect(!context.contains("try? await model.\(action)"))
        }
        #expect(interactions.contains("guard !submitting"))
        #expect(interactions.contains("catch is CancellationError"))
        #expect(!interactions.contains("try? await model."))
        #expect(context.contains("let sessionID: String"))
        for title in ["Extensions", "Prompts", "Skills", "Context Files", "Tools"] {
            #expect(resources.contains("\(title)"))
        }
        #expect(resources.contains("struct ProjectResourceDetailPresentation: Equatable"))
        #expect(resources.contains("ProjectResourceTextPresentation.readableDescription"))
        #expect(resources.contains("for key in [\"label\", \"name\", \"title\", \"path\", \"id\"]"))
        #expect(resources.contains("TronSettingsGroup(\"At a Glance\""))
        #expect(resources.contains("private func capabilityCollection("))
        #expect(resources.contains("LazyVGrid("))
        #expect(resources.contains("presentation.tools"))
        #expect(resources.contains("presentation.commands"))
        #expect(resources.contains("TronTechnicalJSONRow("))
        #expect(resources.contains("subtitleLineLimit: 1"))
        #expect(resources.contains("Collapse all producer whitespace"))
        #expect(resources.contains(".fixedSize(horizontal: false, vertical: true)"))
        #expect(terminalSheet.contains(".alert(\"Quit Terminal?\""))
        #expect(!terminalSheet.contains(".confirmationDialog(\"Quit this terminal?\""))
        let diagnostics = try String(
            contentsOf: packageRoot.appending(path: "Sources/State/GatewayDiagnosticsService.swift"),
            encoding: .utf8
        )
        let workspaceService = try String(
            contentsOf: packageRoot.appending(path: "Sources/State/WorkspaceInspectionService.swift"),
            encoding: .utf8
        )
        let workspaceSheet = try String(
            contentsOf: packageRoot.appending(path: "Sources/UI/Chat/WorkspaceInspectorSheet.swift"),
            encoding: .utf8
        )
        let workspaceOwner = try String(
            contentsOf: packageRoot.appending(path: "Sources/UI/Chat/WorkspaceInspectorOwner.swift"),
            encoding: .utf8
        )
        let attachmentPreview = try String(
            contentsOf: packageRoot.appending(path: "Sources/UI/Chat/AttachmentFilePreviewSheet.swift"),
            encoding: .utf8
        )
        #expect(logs.contains("extension GatewayLogRecord"))
        #expect(logs.contains("Newest entries first"))
        #expect(settings.contains("await model.requestGatewayRestart(for: currentProfile)"))
        #expect(logs.contains("let loaded = await model.loadGatewayLogsResult(limit: 1_000)"))
        #expect(!logs.contains("while !Task.isCancelled"))
        #expect(!settings.contains("try? await model."))
        #expect(context.contains("model.workspaceInspection.inspect(sessionID: sessionID)"))
        #expect(!context.contains("model.gatewayDiagnostics.inspectGit"))
        #expect(context.contains("detailInline: true"))
        #expect(context.contains("SessionWorkspaceRowPresentation"))
        #expect(context.contains("workspacePresentation = .loading"))
        #expect(context.contains("workspaceLoadGeneration &+= 1"))
        #expect(context.contains("case .failed"))
        #expect(context.contains("Button { destination = .workspace }"))
        #expect(!context.contains("await model.refreshSessions()"))
        #expect(context.contains("await monitorWorkspace(snapshot: presentation)"))
        #expect(workspaceService.contains("session.workspace.inspect"))
        #expect(workspaceService.contains("session.workspace.git.diff"))
        #expect(workspaceService.contains("session.workspace.git.history.list"))
        #expect(workspaceService.contains("session.workspace.git.history.diff"))
        #expect(workspaceService.contains("Task.detached(priority: .userInitiated)"))
        #expect(workspaceSheet.contains("ToolDiffView(lines: presentation.lines"))
        #expect(workspaceSheet.contains("AttachmentFilePreviewSheet("))
        #expect(workspaceSheet.contains("Task.sleep(for: .seconds(4))"))
        #expect(workspaceSheet.contains("ScrollViewReader { proxy in"))
        #expect(workspaceSheet.contains("Color.clear.frame(height: 0).id(\"workspace-top\")"))
        #expect(workspaceSheet.contains("proxy.scrollTo(\"workspace-top\", anchor: .top)"))
        #expect(workspaceSheet.contains(".tronScrollEdgeChrome()"))
        #expect(workspaceSheet.contains("@State private var detent: PresentationDetent = .medium"))
        #expect(workspaceSheet.contains("foreground: .tronBlue"))
        #expect(workspaceOwner.contains("WorkspaceHistoryGraphLayout.rows"))
        #expect(workspaceSheet.contains("WorkspaceHistoryGraphPalette.color"))
        #expect(workspaceSheet.contains("private let lineWidth: CGFloat = 2.2"))
        #expect(!workspaceSheet.contains(".background(Color.tronBackground)"))
        #expect(workspaceSheet.contains(".foregroundStyle(Color.tronBlue)"))
        #expect(workspaceSheet.contains("icon: changeStatusIcon(change)"))
        #expect(!workspaceSheet.contains("TronPulseLoadingIndicator"))
        #expect(workspaceSheet.contains("truncationMode: .head"))
        #expect(workspaceSheet.contains("WorkspaceCommitMessagePresentation.body"))
        #expect(workspaceSheet.contains("model.workspaceInspection.commitDiff("))
        #expect(workspaceSheet.contains("Task.detached(priority: .userInitiated)"))
        #expect(workspaceOwner.contains("maximumRetainedCommits = 400"))
        #expect(workspaceOwner.contains("changesByPath"))
        #expect(workspaceOwner.contains("historyRows"))
        #expect(attachmentPreview.contains(".presentationDetents([.large])"))
        #expect(attachmentPreview.contains(".tronTopBlurSurface()"))
        #expect(!attachmentPreview.contains(".presentationDetents([.medium, .large]"))
        #expect(context.contains("model.sessionContextPresentation(for: sessionID)"))
        #expect(context.contains("model.sessionContextRevision(for: sessionID)"))
        #expect(resources.contains("model.sessionResourceRevision(for: sessionID)"))
        #expect(context.contains("guard presentationActivity.allowsPresentationPublication else { return }"))
        #expect(resources.contains("guard presentationActivity.allowsPresentationPublication else { return }"))
        let presentationStore = try String(
            contentsOf: packageRoot.appending(path: "Sources/State/SessionPresentationStore.swift"),
            encoding: .utf8
        )
        for owner in ["contextLoadGeneration", "treeLoadGeneration", "resourceLoadGeneration"] {
            #expect(presentationStore.contains(owner))
        }
        #expect(presentationStore.contains("prepareSecondaryProjectionForRuntimeInstallation(installed)"))
        #expect(presentationStore.contains("ownsSubscription(sessionID: sessionID, requestedToken: token)"))
        #expect(logs.contains("model.loadGatewayLogs"))
        #expect(!context.contains("model.client"))
        #expect(!settings.contains("model.client"))
        #expect(!logs.contains("model.client"))
        #expect(diagnostics.contains("request(\"git.inspect\""))
        #expect(diagnostics.contains("request(\"system.logs\""))
        #expect(customModels.contains("Advanced JSON"))
        #expect(customModels.contains("HStack(alignment: .center, spacing: TronSpacing.xl)"))
        #expect(customModels.contains("frame(width: 20, height: 20, alignment: .center)"))
        #expect(!customModels.contains("Label(\"Secret-looking values are hidden."))
        #expect(!customModels.contains("Label(\"Advanced JSON has unsaved edits."))
        #expect(customModels.contains("private var providersSection: some View"))
        #expect(!customModels.contains("TronSettingsGroup(\"Providers\""))
        #expect(customModels.contains("CustomModelProviderRow("))
        #expect(customModels.contains("private struct CustomModelProviderRow"))
        #expect(customModels.contains("private func providerEditorSheet("))
        #expect(customModels.contains("fieldLabel(\"Provider identifier\")"))
        #expect(customModels.contains("TronTechnicalJSONRow("))
        #expect(customModels.contains("titleColor: TronSettingsButtonContrastPolicy.usesWhiteForeground(in: colorScheme)"))
        #expect(customModels.contains("TronTypography.code(size: TronTypography.sizeBody2)"))
        #expect(customModels.contains("Button { isPresented = true }"))
        #expect(customModels.contains("Image(systemName: \"ellipsis\")"))
        #expect(!customModels.contains("chevron.right"))
        let providerSummary = (customModels.components(separatedBy: "private func providerSummary").dropFirst().first ?? "")
            .components(separatedBy: "private func providerEditorSheet").first ?? ""
        #expect(!providerSummary.contains("tronGlassSurface"))
        let providerEditor = (customModels.components(separatedBy: "private func providerEditorSheet").dropFirst().first ?? "")
            .components(separatedBy: "private func fieldLabel").first ?? ""
        #expect(providerEditor.contains("editorSectionHeader(\"Connection\")"))
        #expect(providerEditor.contains("\"Models\",\n                        detail:"))
        #expect(providerEditor.contains("\"Protocol\",\n                        detail:"))
        #expect(!providerEditor.contains("Identify the provider and choose the endpoint."))
        #expect(providerEditor.contains("dense: true"))
        #expect(providerEditor.contains("surfaceTint: Color.tronEmerald.opacity(0.14)"))
        #expect(providerEditor.contains("icon: \"network\",\n                        title: \"API format\""))
        #expect(providerEditor.components(separatedBy: "TronSettingsGroup").count - 1 == 0)
        #expect(providerEditor.components(separatedBy: "tronGlassSurface").count - 1 == 1)
        #expect(!customModels.contains("expandedProviderIDs"))
        #expect(!customModels.contains("DisclosureGroup(isExpanded: isExpanded)"))
        #expect(trust.contains("VStack(spacing: 10)"))
        #expect(trust.contains("info.circle.fill"))
        #expect(trust.contains("icon: \"exclamationmark.shield\""))
        #expect(trust.contains("TronInfoCard("))
        #expect(trust.contains("Text(\"Decision\")"))
        #expect(!trust.contains("TronSettingsGroup(\"Decision\""))
        #expect(!trust.contains("VStack(spacing: 0)"))
        let packageOverview = packages.components(separatedBy: "struct PackageResolvedResourcesView").first ?? ""
        let packageDetail = packages.components(separatedBy: "struct PackageResolvedResourcesView").dropFirst().first ?? ""
        #expect(packageOverview.contains("TronProgressiveSheetLink("))
        #expect(packageOverview.contains("accessibilityLabel: \"Inspect resolved resources, \\(summary)\""))
        #expect(packageOverview.contains("Inspect Resolved Resources"))
        #expect(packageOverview.contains("icon: \"arrow.down.circle.fill\""))
        #expect(packageOverview.contains("icon: \"magnifyingglass.circle.fill\""))
        #expect(packageOverview.contains("private var packageInstallSheet: some View"))
        let packageInstall = (packageOverview.components(separatedBy: "private var packageInstallSheet: some View").dropFirst().first ?? "")
            .components(separatedBy: "private func sheetSectionHeader").first ?? ""
        #expect(packageInstall.contains("sheetSectionHeader("))
        #expect(packageInstall.contains("dense: true"))
        #expect(packageInstall.contains("surfaceTint: Color.tronEmerald.opacity(0.14)"))
        #expect(!packageInstall.contains("TronSettingsGroup"))
        #expect(packageOverview.contains("presentationDetents([.medium, .large])"))
        #expect(packageOverview.contains("await model.checkPackageUpdates(target: requestedTarget"))
        #expect(!packageOverview.contains("TronSettingsGroup(\"Updates\""))
        #expect(!packageOverview.contains("Update All"))
        #expect(!packageOverview.contains("Check for Updates"))
        #expect(!packageOverview.contains("TronStructuredJSONView"))
        #expect(!packageDetail.contains("TronStructuredJSONView"))
        #expect(packageDetail.contains("PackageResolvedResourcesPresentation"))
        #expect(packageDetail.contains("TronProgressiveSheetLink("))
        #expect(packageDetail.contains("PackageResolvedResourceCategoryView"))
        #expect(packageDetail.contains("TronTechnicalJSONRow("))
        let runtimeSettings = try String(
            contentsOf: packageRoot.appending(path: "Sources/UI/Settings/ResourceSettingsView.swift"),
            encoding: .utf8
        )
        #expect(runtimeSettings.contains("Additional Locations"))
        #expect(runtimeSettings.contains("Advanced Mac Overrides"))
        #expect(runtimeSettings.contains("Automatic discovery only"))
        #expect(!runtimeSettings.contains("case .sessionDir"))
    }

    @Test("custom model and log rows keep aligned lazy lifecycle presentation")
    func scalableSettingsRows() throws {
        let customModels = try String(
            contentsOf: packageRoot.appending(path: "Sources/UI/Settings/CustomModelsSettingsView.swift"),
            encoding: .utf8
        )
        let logs = try String(
            contentsOf: packageRoot.appending(path: "Sources/UI/Settings/GatewayLogsSettingsView.swift"),
            encoding: .utf8
        )
        let appModel = try String(
            contentsOf: packageRoot.appending(path: "Sources/State/AppModel.swift"),
            encoding: .utf8
        )
        let providersSection = (customModels.components(separatedBy: "private var providersSection: some View").dropFirst().first ?? "")
            .components(separatedBy: "private func providerRow").first ?? ""
        let providerSummary = (customModels.components(separatedBy: "private func providerSummary").dropFirst().first ?? "")
            .components(separatedBy: "private func providerEditorSheet").first ?? ""
        let customProviderRow = customModels.components(separatedBy: "private struct CustomModelProviderRow").dropFirst().first ?? ""
        let logRow = (logs.components(separatedBy: "private struct GatewayLogRow").dropFirst().first ?? "")
            .components(separatedBy: "struct GatewayLogDetailView").first ?? ""
        let disconnectHandler = (appModel.components(separatedBy: "case \"transport.disconnected\", \"system.stopping\":").dropFirst().first ?? "")
            .components(separatedBy: "case \"transport.resyncRequired\":").first ?? ""

        #expect(providersSection.contains("LazyVStack(alignment: .leading"))
        #expect(providersSection.contains("} else {\n                ForEach($providers)"))
        #expect(!providersSection.contains("} else {\n                VStack"))
        #expect(providerSummary.contains(".frame(width: 22, height: 22, alignment: .center)"))
        #expect(customProviderRow.contains(".padding(.leading, 14)"))
        #expect(customProviderRow.contains(".padding(.trailing, 60)"))

        #expect(logs.contains("@State private var recordIndex = GatewayLogRecordIndex()"))
        #expect(logs.contains("Dictionary(grouping: all, by:"))
        #expect(logs.contains("ForEach(rows) { item in"))
        #expect(logs.contains("GatewayLogRow(record: item.record)\n                                .equatable()"))
        #expect(!logs.contains("Array(visibleRecords.enumerated())"))
        #expect(!logs.contains(".padding(.leading, 54)"))
        #expect(logs.contains("private struct GatewayLogRow: View, Equatable"))
        #expect(logs.contains(".task(id: PresentationActivityTaskID("))
        #expect(logs.contains("readinessGeneration: model.diagnosticsReadinessGeneration"))
        #expect(logs.contains("isReady: model.diagnosticsAreReady"))
        #expect(!logs.contains("model.connectionState == .connected"))
        #expect(logs.contains("await model.loadGatewayLogsResult(limit: 1_000)"))
        #expect(logs.contains("loaded.failedProfileIDs.contains($0.profileID)"))
        #expect(logs.contains("await loadLogs(preserveExistingOnEmpty: true)"))
        #expect(logs.contains("await loadLogs(preserveExistingOnEmpty: false)"))
        #expect(disconnectHandler.contains("lifecycleInvalidateSessionConnectionOwnership()"))
        #expect(!disconnectHandler.contains("\n            invalidateSessionConnectionOwnership()"))
        #expect(logs.contains("TronLoadingState("))
        #expect(logs.contains("TronInfoCard("))
        #expect(!logs.contains("ContentUnavailableView"))
        #expect(logRow.contains("VStack(alignment: .leading, spacing: 3)"))
        #expect(logRow.contains("HStack(alignment: .firstTextBaseline, spacing: 5)"))
        #expect(logRow.contains(".font(TronTypography.caption2)"))
        #expect(logRow.components(separatedBy: "metadataSeparator").count == 5)
        #expect(logRow.contains("Text(record.record.levelTitle)\n                    .foregroundStyle(record.record.accent)"))
        #expect(!logRow.contains("Image(systemName: record.record.icon)"))
        #expect(!logRow.contains("TronTypography.bodySM"))
        #expect(logRow.contains(".frame(maxWidth: .infinity, alignment: .leading)\n        .padding(.vertical, 7)"))
        let actionPosition = try #require(logRow.firstRange(of: "Text(actionDescription)")?.lowerBound)
        let sourcePosition = try #require(logRow.firstRange(of: "Text(sourceDescription)")?.lowerBound)
        let levelPosition = try #require(logRow.firstRange(of: "Text(record.record.levelTitle)")?.lowerBound)
        let timestampPosition = try #require(logRow.firstRange(of: "Text(timestampDescription)")?.lowerBound)
        let messagePosition = try #require(logRow.firstRange(of: "Text(record.record.message)")?.lowerBound)
        #expect(actionPosition < sourcePosition)
        #expect(sourcePosition < levelPosition)
        #expect(levelPosition < timestampPosition)
        #expect(timestampPosition < messagePosition)
        #expect(logRow.contains(".accessibilityLabel(\"\\(actionDescription), \\(sourceDescription), \\(record.record.levelTitle) log, \\(timestampDescription)\")"))
        #expect(!logRow.contains("HStack(alignment: .top"))
    }

    @Test("removed provisional chat surfaces have no production source call sites")
    func removedProvisionalChatSurfaces() throws {
        let sourcesRoot = packageRoot.appending(path: "Sources")
        let enumerator = FileManager.default.enumerator(
            at: sourcesRoot,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        let productionSources = try (enumerator?.allObjects as? [URL] ?? [])
            .filter { $0.pathExtension == "swift" }
            .sorted { $0.path < $1.path }
            .map { url in (url, try String(contentsOf: url, encoding: .utf8)) }

        let forbiddenSymbols = [
            "ComposerActivityWave",
            "TaperedActivityWave",
            "SubagentSessionsSheet",
            "showSubagents",
            "originatingSubagents",
        ]
        for symbol in forbiddenSymbols {
            let occurrenceCount = productionSources.reduce(0) { count, source in
                count + source.1.occurrences(of: symbol)
            }
            #expect(occurrenceCount == 0, "\(symbol) remains in production Sources")
        }

        let runtimeProjectionCount = productionSources.reduce(0) { count, source in
            count + source.1.occurrences(of: "ChatNotificationPresentation.runtime(in:")
        }
        #expect(runtimeProjectionCount == 1)
        #expect(productionSources.contains { $0.1.contains("let runtimeItems: [ChatTranscriptRenderItem]") })

        let chat = try #require(productionSources.first { $0.0.lastPathComponent == "ChatView.swift" }?.1)
        #expect(!chat.contains("snapshot.extensionPresentation.semanticState.widgets.filter"))
        let liveGroupProjectionCount = productionSources.reduce(0) { count, source in
            count + source.1.occurrences(of: "ChatExtensionWidgetPolicy.liveGroups")
        }
        #expect(liveGroupProjectionCount == 0)
        #expect(productionSources.contains { $0.1.contains("processButton") })
        #expect(!productionSources.contains { $0.1.contains("ExtensionActivityPill(") })

        let processSheets = try #require(
            productionSources.first { $0.0.lastPathComponent == "SessionProcessSheets.swift" }?.1
        )
        #expect(processSheets.contains(".tronNavigationTitle(\"Subagents\")"))
        #expect(processSheets.contains(".tronNavigationTitle(\"Subagent History\")"))
        #expect(processSheets.occurrences(of: ".tronTopBlur(.sheet)") == 3)
        #expect(processSheets.occurrences(of: ".tronPresentation()") == 3)
        #expect(processSheets.occurrences(of: "@State private var detent: PresentationDetent = .medium") == 2)
        #expect(processSheets.occurrences(of: "@State private var detent: PresentationDetent = .large") == 1)
        #expect(processSheets.occurrences(of: "item: $selectedProcess") == 2)
        #expect(!processSheets.contains("NavigationLink"))
        #expect(processSheets.contains("SessionProcessRow(process: process, accent: accent, surfaceStyle: .glass)"))
        #expect(processSheets.contains("SessionProcessRow(process: process, accent: accent, surfaceStyle: .scrollOptimized)"))
        #expect(processSheets.contains("TronGlassCard(accent: cardAccent, cornerRadius: 14, interactive: false"))
        #expect(processSheets.contains(".tronScrollSurface(accent: cardAccent, cornerRadius: 12"))
        #expect(processSheets.contains("size: 24"))
        #expect(processSheets.contains("private struct SessionProcessPill: View"))
        #expect(processSheets.contains("LIVE ACTIVITY"))
        #expect(processSheets.contains("durationSpeedScale(durationMs: process.durationMs)"))
        #expect(!processSheets.contains("Canonical transcript ready"))
        #expect(processSheets.contains(".accessibilityAddTraits(.isHeader)"))
        #expect(processSheets.contains(".accessibilityValue(accessibilityValue)"))
        #expect(processSheets.contains("@State private var scrollPosition = ScrollPosition"))
        #expect(!processSheets.contains("Image(systemName: \"chevron.right\")"))
        #expect(!processSheets.contains(".navigationTitle("))

        let orb = try #require(
            productionSources.first { $0.0.lastPathComponent == "ProcessActivityOrb.swift" }?.1
        )
        #expect(orb.contains("var isVisible = true"))
        #expect(orb.contains("reduceMotion || !isVisible || !sceneActive"))
    }

    @Test("transcript media is epoch-keyed, downsampled, bounded, and single-flight")
    func boundedTranscriptMedia() throws {
        let loader = try String(
            contentsOf: packageRoot.appending(path: "Sources/State/ChatMediaLoader.swift"),
            encoding: .utf8
        )
        let model = try String(
            contentsOf: packageRoot.appending(path: "Sources/State/AppModel.swift"),
            encoding: .utf8
        )
        let client = try String(
            contentsOf: packageRoot.appending(path: "Sources/Gateway/GatewayClient.swift"),
            encoding: .utf8
        )
        let boundedTransport = try String(
            contentsOf: packageRoot.appending(path: "Sources/Gateway/BoundedHTTPDataTransport.swift"),
            encoding: .utf8
        )
        #expect(loader.contains("maximumDecodedThumbnailBytes = 4 * 1_024 * 1_024"))
        #expect(loader.contains("maximumThumbnailCount = 64"))
        #expect(loader.contains("maximumThumbnailPixelDimension = 192"))
        #expect(loader.contains("maximumEncodedBytes = 25 * 1_024 * 1_024"))
        #expect(loader.contains("maximumConcurrentPreparations = 1"))
        #expect(loader.contains("maximumThumbnailFlights = 32"))
        #expect(loader.contains("CGImageSourceCreateThumbnailAtIndex"))
        #expect(loader.contains("thumbnailFlights[identity]"))
        #expect(loader.contains("previewFlight?.task.cancel()"))
        #expect(model.contains("func chatMediaIdentity(blobID: String)"))
        #expect(model.contains("chatMedia.removeAll()"))
        #expect(client.contains("profile.id == profileID"))
        #expect(client.contains("connection?.id == connectionID"))
        #expect(client.contains("maximumBytes: maximumBytes"))
        #expect(boundedTransport.contains("response.expectedContentLength"))
        #expect(boundedTransport.contains("chunk.count <= maximumBytes - data.count"))
    }

    @Test("session exports stay file-backed and lifecycle-owned")
    func fileBackedSessionExports() throws {
        let model = try String(
            contentsOf: packageRoot.appending(path: "Sources/State/AppModel.swift"),
            encoding: .utf8
        )
        let client = try String(
            contentsOf: packageRoot.appending(path: "Sources/Gateway/GatewayClient.swift"),
            encoding: .utf8
        )
        let transport = try String(
            contentsOf: packageRoot.appending(path: "Sources/Gateway/BoundedHTTPFileTransport.swift"),
            encoding: .utf8
        )
        let artifacts = try String(
            contentsOf: packageRoot.appending(path: "Sources/State/SessionExportArtifactStore.swift"),
            encoding: .utf8
        )
        #expect(model.contains("client.blobFile("))
        #expect(model.contains("exportArtifacts.adopt(stagedURL"))
        #expect(!model.contains("exportArtifacts.write(data"))
        #expect(client.contains("boundedHTTPFileTransport.download("))
        #expect(transport.contains("URLSessionDownloadDelegate"))
        #expect(transport.contains("admitProgress(totalBytesWritten)"))
        #expect(transport.contains("maximumFiles: Int = 32"))
        #expect(artifacts.contains("FileManager.default.moveItem(at: source, to: destination)"))
    }

    @Test("thinking traces stay compact and expose only overflow details")
    func thinkingTraceAccessibility() throws {
        let transcript = try String(
            contentsOf: packageRoot.appending(path: "Sources/UI/Chat/TranscriptRow.swift"),
            encoding: .utf8
        )
        let reveal = try String(
            contentsOf: packageRoot.appending(path: "Sources/UI/Chat/StreamingTextReveal.swift"),
            encoding: .utf8
        )
        let block = (transcript.components(separatedBy: "private struct ThinkingBlock").dropFirst().first ?? "")
            .components(separatedBy: "private struct MarkdownText").first ?? ""
        #expect(block.contains("ChatThinkingTraceLayoutPolicy"))
        #expect(block.contains("maximumHeight"))
        #expect(block.contains(".onTapGesture"))
        #expect(block.contains("isPresented: $showingDetails"))
        #expect(block.contains("ThinkingTraceDetailSheet"))
        let compactViewport = (block.components(separatedBy: "private var traceViewport").dropFirst().first ?? "")
            .components(separatedBy: "private var paragraph").first ?? ""
        #expect(compactViewport.contains("tailOffset"))
        #expect(compactViewport.contains("LinearGradient"))
        #expect(!compactViewport.contains("ScrollViewReader"))
        #expect(block.contains(".presentationDragIndicator(.hidden)"))
        #expect(block.contains("private let title = \"Thinking\""))
        #expect(block.contains("TronSheetTitle"))
        #expect(block.contains("TronTypography.body"))
        #expect(block.contains(".tronTopBlur(.sheet)"))
        #expect(!block.contains(".presentationDragIndicator(.visible)"))
        #expect(block.contains(".accessibilityLabel(accessibleParagraph)"))
        #expect(block.contains("return \"\\(label). \\(paragraph)\""))
        #expect(reveal.contains("static let maximumLines = 4"))
        #expect(reveal.contains("static func isOverflowing"))
        #expect(reveal.contains("static func viewportHeight"))
    }

    @Test("tool details foreground semantic content and isolate technical JSON")
    func toolDetailPresentation() throws {
        let transcript = try String(
            contentsOf: packageRoot.appending(path: "Sources/UI/Chat/ChatToolRunViews.swift"),
            encoding: .utf8
        )
        let sheet = try String(
            contentsOf: packageRoot.appending(path: "Sources/UI/Chat/ToolDetailSheet.swift"),
            encoding: .utf8
        )
        let changesSheet = try String(
            contentsOf: packageRoot.appending(path: "Sources/UI/Chat/ToolChangesSheet.swift"),
            encoding: .utf8
        )
        let technicalSheet = try String(
            contentsOf: packageRoot.appending(path: "Sources/UI/Chat/ToolTechnicalDetailsSheet.swift"),
            encoding: .utf8
        )
        let processSheets = try String(
            contentsOf: packageRoot.appending(path: "Sources/UI/Chat/SessionProcessSheets.swift"),
            encoding: .utf8
        )
        let navigationChrome = try String(
            contentsOf: packageRoot.appending(path: "Sources/UI/Chat/ToolDetailNavigationChrome.swift"),
            encoding: .utf8
        )
        let detailSheets = sheet + changesSheet + technicalSheet
        let presentation = try String(
            contentsOf: packageRoot.appending(path: "Sources/UI/Chat/ToolDetailPresentation.swift"),
            encoding: .utf8
        )
        let transcriptPresentation = try String(
            contentsOf: packageRoot.appending(path: "Sources/UI/Chat/ChatTranscriptPresentation.swift"),
            encoding: .utf8
        )
        let structured = try String(
            contentsOf: packageRoot.appending(path: "Sources/UI/Components/StructuredJSONView.swift"),
            encoding: .utf8
        )
        let timestamps = try String(
            contentsOf: packageRoot.appending(path: "Sources/Support/GatewayTimestamp.swift"),
            encoding: .utf8
        )
        #expect(transcript.contains("content.tronManagedSheet("))
        #expect(transcript.contains("ToolDetailSheet("))
        #expect(transcript.contains("tool: tool"))
        #expect(transcript.contains("density: detent == .large ? .expanded : .glance"))
        #expect(transcript.contains(".presentationDetents([.medium, .large], selection: $detent)"))
        let runOwner = try #require(
            transcript.components(separatedBy: "struct ToolRunView: View {").dropFirst().first?
                .components(separatedBy: "private struct ToolActivityChip: View {").first
        )
        #expect(runOwner.contains("@State private var resolvedState: ToolRunResolvedState?"))
        #expect(!runOwner.contains("resolvedDetail"))
        #expect(!runOwner.contains("resolvedGroup"))
        #expect(runOwner.contains("@State private var detailDetent: PresentationDetent = .medium"))
        #expect(runOwner.contains("ToolActivityChip("))
        #expect(runOwner.contains("if resolvedState.run.displayCount == 1"))
        #expect(runOwner.contains("resolveDetails(detailToolIDs, installationTag)"))
        #expect(runOwner.contains("resolvedState = ToolRunResolvedState(installationTag: tag, run: run, tools: details)"))
        let statePosition = try #require(runOwner.firstRange(of: "@State private var resolvedState")?.lowerBound)
        let chipPosition = try #require(runOwner.firstRange(of: "ToolActivityChip(")?.lowerBound)
        let sheetPosition = try #require(runOwner.firstRange(of: ".tronManagedSheet(")?.lowerBound)
        #expect(statePosition < chipPosition)
        #expect(chipPosition < sheetPosition)
        #expect(sheet.contains(".defaultScrollAnchor(.top, for: .initialOffset)"))
        #expect(sheet.contains(".defaultScrollAnchor(.top, for: .alignment)"))
        #expect(navigationChrome.contains("navigationTitle(\"\")"))
        #expect(navigationChrome.contains(".navigationBarTitleDisplayMode(.inline)"))
        #expect(transcript.matches(#"\.tronToolDetailNavigationChrome\(\)"#) == 5)
        #expect(detailSheets.matches(#"\.tronToolDetailNavigationChrome\(\)"#) == 2)
        #expect(transcript.matches(#"\.tronTopBlur\(\.toolDetail\)"#) == 5)
        #expect(transcript.occurrences(of: "icon: ToolDetailPresentation.sheetTitleIcon(for: tool)") == 4)
        #expect(changesSheet.contains(".tronTopBlur(.toolDetail)"))
        #expect(technicalSheet.contains(".tronTopBlur(.toolDetail)"))
        #expect(sheet.contains("title: \"Technical details\""))
        #expect(sheet.contains("ToolTechnicalDetailsSheet"))
        #expect(sheet.contains("ToolChipFlowLayout"))
        #expect(sheet.contains("ToolStatusChip"))
        #expect(sheet.contains("ToolMetadataChip"))
        #expect(sheet.occurrences(of: "ChatCompactPillLeadingIcon(") >= 3)
        #expect(processSheets.contains("HStack(spacing: ChatCompactPillLayoutPolicy.itemSpacing)"))
        #expect(processSheets.contains("ChatCompactPillLeadingIcon("))
        let chipLayout = try #require(
            sheet.components(separatedBy: "struct ToolChipFlowLayout: Layout {").dropFirst().first?
                .components(separatedBy: "private struct ToolActivityChip: View {").first
        )
        #expect(sheet.contains("enum ToolChipFlowLayoutPolicy"))
        #expect(chipLayout.contains("struct Cache"))
        #expect(chipLayout.contains("let ideal = subview.sizeThatFits(.unspecified)"))
        #expect(chipLayout.contains("sizeThatFits(ProposedViewSize(width: availableWidth, height: nil))"))
        #expect(chipLayout.contains("proposal: ProposedViewSize(width: frame.width, height: frame.height)"))
        #expect(chipLayout.contains("height: frames.map(\\.maxY).max() ?? 0"))
        #expect(!chipLayout.contains(".fixedSize(horizontal: true"))
        #expect(chipLayout.matches(#"\.lineLimit\(2\)"#) >= 3)
        #expect(sheet.contains(".accessibilityLabel(item.accessibilityLabel)"))
        #expect(!sheet.contains(".accessibilityLabel(\"\\(item.label), \\(item.value)\")"))
        #expect(sheet.contains("ToolChangesSheet"))
        #expect(sheet.contains("if diff.showsInline"))
        #expect(sheet.contains("diff.visibleLines(for: density)"))
        #expect(sheet.contains("Text($0).foregroundColor(Color.tronTextSecondary)"))
        #expect(sheet.contains("Text(path.basename).foregroundColor(accent)"))
        #expect(changesSheet.contains("ToolDiffView(lines: diff.lines, surfaceStyle: .scrollOptimized)"))
        let primaryDetail = try #require(
            sheet.components(separatedBy: "@ViewBuilder private func primarySection").dropFirst().first?
                .components(separatedBy: "private func pathText").first
        )
        #expect(primaryDetail.contains("presentation.sheetTitleIcon != nil"))
        #expect(primaryDetail.contains("presentation.kind == .bash"))
        #expect(primaryDetail.contains("Text(verbatim: preview.text)"))
        #expect(primaryDetail.contains(".font(primaryValueFont)"))
        #expect(primaryDetail.contains(".fixedSize(horizontal: false, vertical: true)"))
        #expect(!primaryDetail.contains("ScrollView(.horizontal"))
        #expect(primaryDetail.contains("preview.isBounded, presentation.kind != .bash"))
        let resultDetail = try #require(
            sheet.components(separatedBy: "@ViewBuilder private func resultSection").dropFirst().first?
                .components(separatedBy: "private var technicalDetailsButton").first
        )
        #expect(resultDetail.contains(".font(TronTypography.code(size: TronTypography.sizeBodySM))"))
        #expect(resultDetail.contains(".frame(maxWidth: .infinity, alignment: .leading)"))
        #expect(sheet.contains("fullDiffButton(diff)"))
        #expect(sheet.contains("changesButton(diff, title: \"View full diff\")"))
        #expect(!sheet.contains("Button(\"Open full diff\")"))
        let subagentSheet = try #require(
            processSheets.components(separatedBy: "struct ReadOnlySubagentSessionSheet").dropFirst().first
        )
        #expect(subagentSheet.contains("ReadOnlySubagentTranscriptRow("))
        #expect(subagentSheet.contains("store.presentation.timeline.items"))
        #expect(subagentSheet.contains("store.loadEarlier()"))
        #expect(subagentSheet.contains("store?.close()"))
        #expect(!subagentSheet.contains("ChatUIKitComposerController"))
        let technicalDetail = try #require(
            technicalSheet.components(separatedBy: "struct ToolTechnicalDetailsSheet").dropFirst().first?
                .components(separatedBy: "private struct ToolTechnicalMetadataItem").first
        )
        let requestJSON = try #require(technicalDetail.firstRange(of: "payload(\"Request\", value: tool.request ?? .null)")?.lowerBound)
        let resultJSON = try #require(technicalDetail.firstRange(of: "payload(\"Result\", value: ToolTechnicalResultResolver.resolve(tool))")?.lowerBound)
        #expect(requestJSON < resultJSON)
        #expect(!technicalDetail.contains("Text(value.prettyPrinted)"))
        #expect(!technicalDetail.contains("ScrollView(.horizontal, showsIndicators: true)"))
        #expect(technicalDetail.contains("TronTechnicalJSONRow("))
        #expect(!technicalDetail.contains("item: $selectedPayload"))
        #expect(technicalDetail.contains("TronTechnicalMetadataItem"))
        #expect(technicalDetail.contains("TronTechnicalMetadataSection("))
        #expect(technicalDetail.contains("TronTechnicalSectionLabel(title)"))
        #expect(technicalDetail.contains("Command preview"))
        #expect(!technicalDetail.contains("readableOutput"))
        #expect(!technicalDetail.contains("Projected fallback"))
        #expect(sheet.contains("boundedPreviewNote(\"Complete \\(label.lowercased()) is available in Technical details.\")"))
        #expect(!sheet.contains("Complete result data is available in Technical details."))
        #expect(!sheet.contains("Request, response, timing, and raw JSON"))
        #expect(!sheet.contains("statusCard"))
        #expect(sheet.contains("showsRawDisclosure: false"))
        #expect(sheet.matches(#"ToolDetailPresentation\(tool: tool\)"#) == 1)
        #expect(!sheet.contains("presentation.kind == .generic, let request"))
        #expect(!presentation.contains("title.lowercased()"))
        let timing = try #require(
            transcriptPresentation.components(separatedBy: "enum ToolTiming {").dropFirst().first?
                .components(separatedBy: "enum ChatTokenCountPresentation {").first
        )
        #expect(timing.contains("value.flatMap(GatewayTimestamp.parse)"))
        #expect(timestamps.contains("Date.ISO8601FormatStyle(includingFractionalSeconds: true)"))
        #expect(timestamps.contains("Date.ISO8601FormatStyle(includingFractionalSeconds: false)"))
        #expect(!timing.contains("ISO8601DateFormatter"))
        #expect(structured.contains("showsRawDisclosure: showsRawDisclosure"))
        #expect(structured.contains("var id: [StructuredJSONPathComponent] { components }"))
        #expect(structured.contains("StructuredJSONPath.resolve(rootValue, components: selection.components)"))
        #expect(!transcript.contains(".prettyPrinted"))
        for tool in ["read", "write", "edit", "bash", "grep", "find", "ls"] {
            #expect(presentation.contains("case \"\(tool)\""), "missing semantic detail mapping for \(tool)")
        }
    }

    @Test("tool and subagent sheet tweaks share value scale and full-width action surfaces")
    func focusedToolSheetTweaks() throws {
        let sheet = try String(
            contentsOf: packageRoot.appending(path: "Sources/UI/Chat/ToolDetailSheet.swift"),
            encoding: .utf8
        )
        let changesSheet = try String(
            contentsOf: packageRoot.appending(path: "Sources/UI/Chat/ToolChangesSheet.swift"),
            encoding: .utf8
        )
        let processSheets = try String(
            contentsOf: packageRoot.appending(path: "Sources/UI/Chat/SessionProcessSheets.swift"),
            encoding: .utf8
        )
        #expect(sheet.occurrences(of: ".font(primaryValueFont)") == 3)
        #expect(sheet.contains("if presentation.sheetTitleIcon != nil"))
        #expect(sheet.contains("HStack(alignment: .center, spacing: 10)"))
        #expect(!sheet.contains("HStack(alignment: .top, spacing: 10)"))
        #expect(sheet.contains("TronTypography.code(size: TronTypography.sizeBodySM, weight: .semibold)"))
        #expect(sheet.contains("fullDiffButton(diff)"))
        #expect(sheet.contains("changesButton(diff, title: \"View full diff\")"))
        let resultPosition = try #require(sheet.firstRange(of: "resultSection(presentation)")?.lowerBound)
        let diffPosition = try #require(sheet.firstRange(of: "diffSection(presentation)")?.lowerBound)
        #expect(resultPosition < diffPosition)
        #expect(!sheet.contains("Button(\"Open full diff\")"))
        #expect(changesSheet.contains("ToolDiffView(lines: diff.lines, surfaceStyle: .scrollOptimized)"))
        #expect(changesSheet.contains("ScrollView(.horizontal, showsIndicators: true)"))
        #expect(changesSheet.contains("VStack(alignment: .leading, spacing: 0)"))
        #expect(!changesSheet.contains("LazyVStack(alignment: .leading, spacing: 0)"))
        #expect(changesSheet.contains(".fixedSize(horizontal: true, vertical: false)"))
        #expect(changesSheet.contains(".scrollBounceBehavior(.basedOnSize, axes: .horizontal)"))
        #expect(!changesSheet.contains("ScrollView([.horizontal, .vertical]"))
        let scrollOptimizedSurface = try #require(
            changesSheet.components(separatedBy: "case .scrollOptimized:").dropFirst().first?
                .components(separatedBy: "private var diffScroll").first
        )
        #expect(scrollOptimizedSurface.contains(".tronScrollSurface(accent: .tronEmerald, tintOpacity: 0.07)"))
        #expect(!scrollOptimizedSurface.contains("tronGlassSurface"))
        let markdownResult = try #require(
            sheet.components(separatedBy: "TronMarkdownView(text: preview.text").dropFirst().first?
                .components(separatedBy: ".tronGlassSurface").first
        )
        #expect(markdownResult.contains(".frame(maxWidth: .infinity, alignment: .leading)"))
        let subagentSheet = try #require(
            processSheets.components(separatedBy: "struct ReadOnlySubagentSessionSheet").dropFirst().first
        )
        #expect(subagentSheet.contains("ReadOnlySubagentTranscriptRow("))
        #expect(subagentSheet.contains("store.presentation.timeline.items"))
        #expect(subagentSheet.contains("store.loadEarlier()"))
        #expect(subagentSheet.contains("store?.close()"))
        #expect(subagentSheet.contains(".defaultScrollAnchor(.bottom, for: .initialOffset)"))
        #expect(subagentSheet.contains(".defaultScrollAnchor(.top, for: .alignment)"))
        #expect(subagentSheet.contains(".defaultScrollAnchor(.top, for: .sizeChanges)"))
        #expect(!subagentSheet.contains("ChatUIKitComposerController"))
    }

    @Test("camera keeps the historical three-control morphing sheet")
    func historicalCameraControls() throws {
        let camera = try String(
            contentsOf: packageRoot.appending(path: "Sources/UI/Chat/CameraCaptureSheet.swift"),
            encoding: .utf8
        )
        #expect(camera.contains("private var controlButtons: some View"))
        #expect(camera.contains("private var centerCameraButton: some View"))
        #expect(camera.contains("systemImage: showingPreview ? \"arrow.counterclockwise\" : \"arrow.triangle.2.circlepath.camera\""))
        #expect(camera.contains("accessibilityLabel: showingPreview ? \"Go back to capture\" : \"Switch Camera\""))
        #expect(camera.contains("static let captureGlassSize: CGFloat = 76"))
        #expect(camera.contains("static let iconButtonSize: CGFloat = 46"))
        #expect(!camera.contains("accessibilityLabel(\"Close camera\")"))
        #expect(!camera.contains("capturedImage == nil ? \"camera.fill\""))
    }

    @Test("server filter uses a medium multi-select sheet")
    func serverFilterUsesMediumSheet() throws {
        let shell = try String(
            contentsOf: packageRoot.appending(path: "Sources/UI/Chat/SessionShellView.swift"),
            encoding: .utf8
        )
        #expect(shell.contains("isPresented: $showingServerFilter"))
        #expect(shell.contains(".presentationDetents([.medium])"))
        #expect(shell.contains("private var serverFilterSheet: some View"))
        let serversHeader = try #require(shell.range(of: "Text(\"Servers\")"))
        let serverGuidance = try #require(shell.range(of: "Text(\"Choose one or more servers"))
        let firstServerOption = try #require(shell.range(of: "title: \"All servers\""))
        #expect(serversHeader.lowerBound < serverGuidance.lowerBound)
        #expect(serverGuidance.lowerBound < firstServerOption.lowerBound)
        #expect(shell.contains("VStack(alignment: .leading, spacing: TronSpacing.xs) {\n                        Text(\"Servers\")"))
        #expect(shell[serverGuidance.lowerBound..<firstServerOption.lowerBound].contains("TronTypography.secondaryDescription"))
        #expect(shell[serverGuidance.lowerBound..<firstServerOption.lowerBound].contains(".padding(.top, TronSpacing.md)"))
        #expect(shell.contains("private func filterOption("))
        #expect(shell.contains("updateServerFilter { $0.toggle(source.profileID) }"))
        #expect(shell.contains("DashboardSessionSortMode.allCases"))
        #expect(shell.contains("DashboardServerFilterPreferences.load()"))
        #expect(shell.contains("DashboardServerFilterPreferences.save(serverFilter)"))
        #expect(shell.contains("serverFilter.sortMode == .recent"))
        #expect(shell.contains("transaction.animation = nil"))
        #expect(shell.contains("model.connectionState == .connecting"))
        #expect(shell.contains("Image(systemName: \"line.3.horizontal.decrease\")"))
        #expect(shell.contains("Text(group.name)"))
        #expect(shell.contains("TronTypography.code(size: TronTypography.sizeBodyLG, weight: .bold)"))
        #expect(shell.contains("Text(serverName)"))
        #expect(!shell.contains("line.3.horizontal.decrease.circle"))
        #expect(!shell.contains("serverFilterGlassNamespace"))
        #expect(!shell.contains("serverFilterPopup"))
    }

    @Test("dashboard rows never retain canonical session selection styling")
    func dashboardRowsDoNotStaySelected() throws {
        let shell = try String(
            contentsOf: packageRoot.appending(path: "Sources/UI/Chat/SessionShellView.swift"),
            encoding: .utf8
        )
        #expect(shell.contains("HistoricalSessionRow("))
        #expect(shell.contains("activity: dashboardPresentation.activity(for: session)"))
        #expect(!shell.contains("HistoricalSessionRow(session: session, selected:"))
        #expect(!shell.contains("let selected: Bool"))
        #expect(shell.contains(".foregroundStyle(Color.tronEmerald)"))
        let appModel = try String(
            contentsOf: packageRoot.appending(path: "Sources/State/AppModel.swift"),
            encoding: .utf8
        )
        #expect(shell.contains("TimelineView(.periodic(from: .now, by: DashboardActivityClock.refreshInterval))"))
        #expect(shell.contains("Text(\"Recent Activity · active first\")"))
        #expect(appModel.contains("SessionSummary.orderedForDashboard(SessionSummary.dashboardSessions(values))"))
        #expect(!shell.contains("orderedByRecency"))
        #expect(!shell.contains("$0.updatedAt > $1.updatedAt"))
    }

    @Test("sheets use explicit reload toolbar actions instead of pull to refresh")
    func sheetReloadActions() throws {
        let sheetOwners = [
            "Sources/UI/Chat/SessionTreeSheet.swift",
            "Sources/UI/Settings/ProjectResourcesView.swift",
            "Sources/UI/Settings/PackagesSettingsView.swift",
            "Sources/UI/Settings/ProviderSettingsView.swift",
        ]
        for path in sheetOwners {
            let source = try String(contentsOf: packageRoot.appending(path: path), encoding: .utf8)
            #expect(!source.contains(".refreshable"), "\(path) still enables pull to refresh")
            let hasReloadAction = source.contains("TronReloadToolbarButton")
                || (source.contains("\"Reload\"") && source.contains("Button(action: reload)"))
            #expect(hasReloadAction, "\(path) is missing an explicit reload action")
        }

        let shell = try String(
            contentsOf: packageRoot.appending(path: "Sources/UI/Chat/SessionShellView.swift"),
            encoding: .utf8
        )
        #expect(!shell.contains(".refreshable"))
        #expect(!shell.contains("refreshDashboardSessions"))
    }

    @Test("the application installs the policy at its root")
    func rootPolicy() throws {
        let app = packageRoot.appending(path: "Sources/App/TronMobileApp.swift")
        let source = try String(contentsOf: app, encoding: .utf8)
        #expect(source.contains(".tronPresentation()"))
    }
}

private extension String {
    func matches(_ pattern: String) -> Int {
        (try? NSRegularExpression(pattern: pattern))?.numberOfMatches(
            in: self,
            range: NSRange(location: 0, length: utf16.count)
        ) ?? 0
    }

    func occurrences(of string: String) -> Int {
        components(separatedBy: string).count - 1
    }
}
