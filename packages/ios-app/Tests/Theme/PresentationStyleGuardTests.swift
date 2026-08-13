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
        let root = packageRoot.appending(path: "Sources/UI")
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

    @Test("app-owned UI never falls back to system fonts or stock bordered controls")
    func noRetiredDefaults() {
        let forbidden: [(String, String)] = [
            (#"\.font\(\.(largeTitle|title|title2|title3|headline|subheadline|body|callout|footnote|caption|caption2)"#, "system semantic font"),
            (#"\.buttonStyle\(\.(bordered|borderedProminent)"#, "stock bordered button"),
            (#"\.pickerStyle\(\.segmented"#, "stock segmented control"),
            (#"\.searchable\("#, "system search field"),
            (#"\.textFieldStyle\(\.(roundedBorder|automatic)"#, "stock text-field style"),
            (#"borderStyle\s*=\s*\.roundedRect"#, "UIKit rounded-rect field"),
            (#"ProgressView\(\s*\""#, "system-font ProgressView label"),
            (#"(?<!Tron)Section\(\""#, "system-generated section header"),
            (#"\.navigationTitle\(\"[^\"]+\"\)"#, "system navigation title"),
        ]

        for (url, source) in uiSources {
            for (pattern, description) in forbidden {
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
            "AgentExtensionSettings.swift", "RuntimeSettingsViews.swift", "SettingsView.swift", "ProjectResourcesView.swift",
            "ExtensionInteractionSheet.swift", "SessionContextSheet.swift", "SessionTreeSheet.swift",
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
                let end = min(lines.count, index + 15)
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
    func sheetAndCardConventions() {
        for (url, source) in uiSources {
            #expect(
                !source.contains("ToolbarItem(placement: .cancellationAction)"),
                "\(url.lastPathComponent) contains a top-left sheet dismissal"
            )
            let allowedNavigationChevrons = url.lastPathComponent == "OnboardingView.swift"
                || url.lastPathComponent == "AuthPromptSheet.swift"
                || url.lastPathComponent == "RuntimeSettingsViews.swift"
            if !allowedNavigationChevrons {
                #expect(
                    !source.contains("Image(systemName: \"chevron.right\")"),
                    "\(url.lastPathComponent) contains a decorative disclosure chevron"
                )
            }
        }
    }

    @Test("onboarding chrome retains the established control geometry")
    func onboardingChromeGeometry() throws {
        let onboarding = try String(
            contentsOf: packageRoot.appending(path: "Sources/UI/Onboarding/OnboardingView.swift"),
            encoding: .utf8
        )
        let presentation = try String(
            contentsOf: packageRoot.appending(path: "Sources/UI/Theme/TronPresentation.swift"),
            encoding: .utf8
        )
        #expect(onboarding.contains(".padding(.horizontal, 10)\n        .padding(.vertical, 6)"))
        #expect(onboarding.contains(".frame(width: value == step ? 16 : 6, height: 6)"))
        #expect(onboarding.contains("Label(\"Back\", systemImage: \"chevron.left\")"))
        #expect(onboarding.contains("Label(\"Next\", systemImage: \"chevron.right\")"))
        #expect(!onboarding.contains("Text(\"Connect\").tronToolbarAction()"))
        let toolbarModifier = presentation.components(separatedBy: "func tronToolbarAction").dropFirst().first ?? ""
        #expect(!toolbarModifier.prefix(300).contains("glassEffect"))
        #expect(toolbarModifier.prefix(180).contains(".tronEmerald"))
    }

    @Test("chat restores historical settings and context control ownership")
    func chatControlOwnership() throws {
        let chat = try String(
            contentsOf: packageRoot.appending(path: "Sources/UI/Chat/ChatView.swift"),
            encoding: .utf8
        )
        #expect(chat.contains("Image(systemName: \"gearshape\")"))
        #expect(chat.contains(".accessibilityLabel(\"Settings\")"))
        #expect(chat.contains("SessionContextProgressButton("))
        #expect(chat.contains("foregroundStyle(Color.tronEmerald)"))
        #expect(!chat.contains("slider.horizontal.3"))
    }

    @Test("top blur uses distinct chat, dashboard, and sheet proportions")
    func topBlurCoverage() throws {
        let blur = try String(
            contentsOf: packageRoot.appending(path: "Sources/UI/Chat/ChatTopVariableBlur.swift"),
            encoding: .utf8
        )
        let chat = try String(
            contentsOf: packageRoot.appending(path: "Sources/UI/Chat/ChatView.swift"),
            encoding: .utf8
        )
        let shell = try String(
            contentsOf: packageRoot.appending(path: "Sources/UI/Chat/SessionShellView.swift"),
            encoding: .utf8
        )
        let app = try String(
            contentsOf: packageRoot.appending(path: "Sources/App/TronMobileApp.swift"),
            encoding: .utf8
        )
        let settings = try String(
            contentsOf: packageRoot.appending(path: "Sources/UI/Settings/SettingsView.swift"),
            encoding: .utf8
        )
        let terminal = try String(
            contentsOf: packageRoot.appending(path: "Sources/UI/Terminal/TerminalSheet.swift"),
            encoding: .utf8
        )
        let camera = try String(
            contentsOf: packageRoot.appending(path: "Sources/UI/Chat/CameraCaptureSheet.swift"),
            encoding: .utf8
        )
        let imagePreview = try String(
            contentsOf: packageRoot.appending(path: "Sources/UI/Chat/AttachmentImagePreviewSheet.swift"),
            encoding: .utf8
        )

        #expect(blur.contains("case .chat: 188"))
        #expect(blur.contains("case .dashboard: 176"))
        #expect(blur.contains("case .sheet: 124"))
        #expect(chat.contains("TronTopBlurOverlay(style: .chat)"))
        #expect(shell.contains("TronTopBlurOverlay(style: .dashboard)"))
        #expect(app.contains(".tronTopBlur(.sheet)"))
        #expect(settings.matches(#"\.tronTopBlur\(\.sheet\)"#) >= 2)
        #expect(terminal.contains(".tronTopBlur(.sheet)"))
        #expect(!camera.contains("tronTopBlur"))
        #expect(!imagePreview.contains("tronTopBlur"))
        #expect(blur.contains(".allowsHitTesting(false)"))
        #expect(blur.contains(".accessibilityHidden(true)"))
        #expect(blur.contains("content.environment(\\.tronTopBlurStyle, style)"))
        #expect(blur.contains("func tronTopBlurSurface()"))
        #expect(!blur.contains("TronNavigationTopBlurInstaller"))

        for (url, source) in uiSources {
            let detentCount = source.matches(#"\.presentationDetents\(\[\.medium, \.large\]"#)
            let blurCount = source.matches(#"\.tronTopBlur\(\.sheet\)"#)
            #expect(
                blurCount >= detentCount,
                "\(url.lastPathComponent) has \(detentCount) medium/large sheets but only \(blurCount) sheet blurs"
            )
        }
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
    }

    @Test("dashboard navigation and search require explicit user intent")
    func dashboardNavigationAndSearch() throws {
        let shell = try String(
            contentsOf: packageRoot.appending(path: "Sources/UI/Chat/SessionShellView.swift"),
            encoding: .utf8
        )
        #expect(shell.contains("@State private var presentedSessionID: String?"))
        #expect(shell.contains(".navigationDestination(item: $presentedSessionID)"))
        #expect(!shell.contains("NavigationSplitView"))
        #expect(!shell.contains("List(selection:"))
        #expect(!shell.contains(".onChange(of: model.selectedSessionID)"))
        #expect(shell.contains(".safeAreaInset(edge: .bottom, spacing: 0)"))
        #expect(shell.contains("focusOnAppear: true"))
        #expect(shell.contains("Button(\"Rename\", systemImage: \"pencil\")"))
        #expect(shell.contains("model.renameSession(session.id, name: name)"))
    }

    @Test("settings containers disclose progressive sub sheets")
    func progressiveSettingsSheets() throws {
        let settings = try String(
            contentsOf: packageRoot.appending(path: "Sources/UI/Settings/SettingsView.swift"),
            encoding: .utf8
        )
        let providers = try String(
            contentsOf: packageRoot.appending(path: "Sources/UI/Onboarding/SetupComponents.swift"),
            encoding: .utf8
        )
        #expect(!settings.contains("NavigationLink"))
        #expect(settings.contains("private struct TronProgressiveSheetLink"))
        #expect(settings.contains(".sheet(isPresented: $isPresented)"))
        #expect(!settings.contains("Button(\"Log Out\""))
        #expect(settings.contains("enum Scope { case dashboard, project }"))
        #expect(settings.contains("if scope == .project"))
        #expect(settings.contains(".providerAuthPresenter()"))
        #expect(settings.contains("currently visible provider"))
        #expect(providers.contains("Button(\"Log Out\", systemImage: \"rectangle.portrait.and.arrow.right\", role: .destructive)"))
        #expect(providers.contains("Image(systemName: \"ellipsis\")"))
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
        let settings = try String(
            contentsOf: packageRoot.appending(path: "Sources/UI/Settings/AgentExtensionSettings.swift"),
            encoding: .utf8
        )
        #expect(context.contains("ProjectResourcesView()"))
        #expect(context.contains("snapshot.stats.latestCacheHitRate"))
        for title in ["Extensions", "Prompts", "Skills", "Context Files", "Tools"] {
            #expect(resources.contains("\(title)"))
        }
        #expect(settings.contains("private struct GatewayLogRecord"))
        #expect(settings.contains("Newest entries first"))
        #expect(settings.contains("Advanced JSON"))
        let runtimeSettings = try String(
            contentsOf: packageRoot.appending(path: "Sources/UI/Settings/RuntimeSettingsViews.swift"),
            encoding: .utf8
        )
        #expect(runtimeSettings.contains("Additional Locations"))
        #expect(runtimeSettings.contains("Advanced Mac Overrides"))
        #expect(runtimeSettings.contains("Automatic discovery only"))
    }

    @Test("composer owns capped UIKit scrolling and attachment photos keep stable previews")
    func robustComposerAndAttachmentPresentation() throws {
        let composer = try String(
            contentsOf: packageRoot.appending(path: "Sources/UI/Chat/ComposerControls.swift"),
            encoding: .utf8
        )
        let chat = try String(
            contentsOf: packageRoot.appending(path: "Sources/UI/Chat/ChatView.swift"),
            encoding: .utf8
        )
        let preview = try String(
            contentsOf: packageRoot.appending(path: "Sources/UI/Chat/AttachmentImagePreviewSheet.swift"),
            encoding: .utf8
        )
        let transcript = try String(
            contentsOf: packageRoot.appending(path: "Sources/UI/Chat/TranscriptRow.swift"),
            encoding: .utf8
        )
        #expect(composer.contains("struct MultilineComposerTextView: UIViewRepresentable"))
        #expect(composer.contains("scrollRangeToVisible(view.selectedRange)"))
        #expect(composer.contains("usesInternalScrolling"))
        #expect(composer.contains("context.coordinator.reconcileFocus(on: view)"))
        #expect(composer.contains("hasMirroredFocus"))
        #expect(chat.contains("MultilineComposerTextView("))
        #expect(!chat.contains("TextField(\"\", text: $text, axis: .vertical)"))
        let attachmentMenu = (chat.components(separatedBy: "Menu {").dropFirst().last ?? "")
            .components(separatedBy: "} label:").first ?? ""
        #expect(attachmentMenu.contains("requestAttachmentPresentation(.camera)"))
        #expect(attachmentMenu.contains("requestAttachmentPresentation(.photos)"))
        #expect(attachmentMenu.contains("requestAttachmentPresentation(.files)"))
        #expect(attachmentMenu.components(separatedBy: ".disabled(!attachmentActionsEnabled)").count == 4)
        #expect(chat.contains(".id(attachmentMenuState.identity)"))
        let attachmentRequest = (chat.components(separatedBy: "private var attachmentMenuState").dropFirst().first ?? "")
            .components(separatedBy: "private func send()").first ?? ""
        #expect(attachmentRequest.contains("sessionID: sessionID"))
        #expect(attachmentRequest.contains("phase: selectedAuthoritativeSnapshot?.phase"))
        #expect(attachmentRequest.contains("guard attachmentActionsEnabled else { return }"))
        #expect(attachmentRequest.contains("queuedAttachmentDestination = destination"))
        #expect(attachmentRequest.contains("Task.sleep(for: .milliseconds(200))"))
        #expect(attachmentRequest.contains("attachmentDestination = destination"))
        #expect(attachmentRequest.contains("cancelAttachmentPresentation"))
        #expect(attachmentRequest.contains("attachmentPresentationBinding"))
        #expect(!chat.contains("@State private var showCamera"))
        #expect(!chat.contains("@State private var showPhotos"))
        #expect(!chat.contains("@State private var showFiles"))
        let pendingChip = (chat.components(separatedBy: "private struct PendingAttachmentChip").dropFirst().first ?? "")
            .components(separatedBy: "private struct ChatTranscriptRenderRow").first ?? ""
        #expect(pendingChip.contains("AttachmentImagePreviewSheet(image: image)"))
        #expect(pendingChip.contains(".frame(width: 44, height: 44, alignment: .topTrailing)"))
        #expect(pendingChip.contains(".regular.tint(Color.tronBlue.opacity(0.18)),"))
        #expect(!pendingChip.contains("Color.tronBlue.opacity(0.18)).interactive()"))
        #expect(preview.contains(".presentationDetents([.medium])"))
        #expect(preview.contains("ConcentricRectangle("))
        #expect(preview.contains("maximumZoomScale = 5"))
        let sentImageChip = (transcript.components(separatedBy: "private struct TranscriptImageChip").dropFirst().first ?? "")
            .components(separatedBy: "private struct TranscriptFileChip").first ?? ""
        #expect(!sentImageChip.isEmpty)
        #expect(sentImageChip.contains(".frame(width: 64, height: 64)"))
        #expect(sentImageChip.contains("AttachmentImagePreviewSheet(image: image)"))
        #expect(!sentImageChip.contains(".presentationDetents([.medium, .large])"))
        #expect(!transcript.contains("private struct ZoomableAttachmentImage"))
        #expect(transcript.contains("private struct TranscriptFileChip"))
    }

    @Test("thinking traces stay complete, compact, and noninteractive")
    func thinkingTraceAccessibility() throws {
        let transcript = try String(
            contentsOf: packageRoot.appending(path: "Sources/UI/Chat/TranscriptRow.swift"),
            encoding: .utf8
        )
        let block = (transcript.components(separatedBy: "private struct ThinkingBlock").dropFirst().first ?? "")
            .components(separatedBy: "private struct MarkdownText").first ?? ""
        #expect(block.contains("@Environment(\\.accessibilityReduceMotion)"))
        #expect(block.contains("animatesInsertion"))
        #expect(block.contains("State(initialValue: animatesInsertion ? [] : Set(segments.map(\\.id)))"))
        #expect(block.contains(".accessibilityLabel(accessibleParagraph)"))
        #expect(block.contains("return \"\\(label). \\(paragraph)\""))
        #expect(block.contains("withAnimation(.easeOut(duration: 0.28))"))
        #expect(!block.contains("Button {"))
        #expect(!block.contains("expanded"))
        #expect(!block.contains(".lineLimit("))
        #expect(!block.contains("minHeight: 44"))
        #expect(!block.contains(".onTapGesture"))
    }

    @Test("tool details are tappable and start at the sheet top")
    func toolDetailPresentation() throws {
        let transcript = try String(
            contentsOf: packageRoot.appending(path: "Sources/UI/Chat/TranscriptRow.swift"),
            encoding: .utf8
        )
        #expect(transcript.contains(".sheet(item: $detailPresentation)"))
        #expect(transcript.contains(".defaultScrollAnchor(.top, for: .initialOffset)"))
        #expect(transcript.contains(".defaultScrollAnchor(.top, for: .alignment)"))
        #expect(transcript.contains(".frame(maxWidth: .infinity, alignment: .topLeading)"))
        for tool in ["read", "write", "edit", "bash", "grep", "find", "ls"] {
            #expect(transcript.contains("case \"\(tool)\""), "missing detail presentation mapping for \(tool)")
        }
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

    @Test("chat transcript controls share compact pills and preserve the viewport while prepending")
    func compactTranscriptPillPresentation() throws {
        let chat = try String(
            contentsOf: packageRoot.appending(path: "Sources/UI/Chat/ChatView.swift"),
            encoding: .utf8
        )
        let transcript = try String(
            contentsOf: packageRoot.appending(path: "Sources/UI/Chat/TranscriptRow.swift"),
            encoding: .utf8
        )
        #expect(chat.contains("Load earlier messages"))
        #expect(chat.contains("New response"))
        #expect(chat.components(separatedBy: ".chatTranscriptPill()").count - 1 >= 2)
        #expect(transcript.contains("struct ChatTranscriptPillModifier: ViewModifier"))
        #expect(transcript.contains("TronTypography.sizeBodySM"))
        #expect(transcript.contains(".padding(.vertical, 6)"))
        #expect(transcript.contains(".fixedSize(horizontal: false, vertical: true)"))
        #expect(transcript.contains(".frame(minWidth: 44, minHeight: 44)"))
        #expect(transcript.contains(".contentShape(Rectangle())"))
        #expect(!transcript.contains(".fixedSize()"))
        #expect(transcript.contains("detail: item.tokensBefore.map(ChatTokenCountPresentation.beforeCompaction)"))
        #expect(transcript.components(separatedBy: ".chatTranscriptPill()").count - 1 == 1)
        #expect(chat.contains("position.scrollTo(y: max(0, previousGeometry.offsetY + delta))"))
        let earlierMessagesChip = (chat.components(separatedBy: "private func earlierMessagesChip").dropFirst().first ?? "")
            .components(separatedBy: "private var composer").first ?? ""
        #expect(!earlierMessagesChip.contains("TronActionButtonStyle(expands: false)"))
    }

    @Test("chat navigation remains emerald with soft scroll edges")
    func emeraldNavigationAndScrollEdges() throws {
        let chat = try String(
            contentsOf: packageRoot.appending(path: "Sources/UI/Chat/ChatView.swift"),
            encoding: .utf8
        )
        let presentation = try String(
            contentsOf: packageRoot.appending(path: "Sources/UI/Theme/TronPresentation.swift"),
            encoding: .utf8
        )
        #expect(chat.contains(".navigationBarBackButtonHidden(true)"))
        #expect(chat.contains("Image(systemName: \"chevron.left\")"))
        #expect(chat.contains(".accessibilityLabel(\"Back\")"))
        #expect(chat.contains(".background(InteractivePopGestureEnabler())"))
        #expect(chat.contains(".tronScrollEdgeChrome()"))
        #expect(chat.contains(".toolbarBackgroundVisibility(.hidden, for: .navigationBar)"))
        #expect(presentation.contains(".scrollEdgeEffectStyle(.soft, for: .all)"))
        #expect(!presentation.contains(".scrollEdgeEffectStyle(.automatic"))
        #expect(presentation.contains(".toolbarBackgroundVisibility(.hidden, for: .navigationBar)"))
        #expect(!presentation.contains(".toolbarBackground(.regularMaterial, for: .navigationBar)"))
        #expect(!presentation.contains(".toolbarBackground(.visible, for: .navigationBar)"))
        let rootPolicy = (presentation.components(separatedBy: "private struct TronPresentationModifier").dropFirst().first ?? "")
            .components(separatedBy: "private struct TronScrollEdgeChromeModifier").first ?? ""
        #expect(!rootPolicy.contains("scrollEdgeEffectStyle"))
        for (url, source) in uiSources where url.lastPathComponent != "TronPresentation.swift" {
            #expect(!source.contains(".scrollEdgeEffectStyle("), "\(url.lastPathComponent) bypasses local scroll-edge chrome")
        }
    }

    @Test("dashboard rows never retain canonical session selection styling")
    func dashboardRowsDoNotStaySelected() throws {
        let shell = try String(
            contentsOf: packageRoot.appending(path: "Sources/UI/Chat/SessionShellView.swift"),
            encoding: .utf8
        )
        #expect(shell.contains("HistoricalSessionRow(session: session)"))
        #expect(!shell.contains("HistoricalSessionRow(session: session, selected:"))
        #expect(!shell.contains("let selected: Bool"))
        #expect(shell.contains(".foregroundStyle(Color.tronEmerald)"))
    }

    @Test("tool runs, transcript notices, and small labels retain compact readable presentation")
    func compactToolAndNoticePresentation() throws {
        let transcript = try String(
            contentsOf: packageRoot.appending(path: "Sources/UI/Chat/TranscriptRow.swift"),
            encoding: .utf8
        )
        let chat = try String(
            contentsOf: packageRoot.appending(path: "Sources/UI/Chat/ChatView.swift"),
            encoding: .utf8
        )
        #expect(transcript.contains("struct TranscriptNotice: View"))
        #expect(transcript.contains("struct ToolRunView: View"))
        #expect(transcript.contains("RoundedRectangle(cornerRadius: 9"))
        #expect(transcript.contains(".padding(.vertical, 6)"))
        #expect(transcript.components(separatedBy: "ProgressView().controlSize(.small)").count >= 3)
        #expect(transcript.contains(".font(TronFont.body(12))"))
        #expect(transcript.contains(".foregroundStyle(Color.tronTextSecondary)"))
        #expect(transcript.contains(".italic()"))
        #expect(chat.contains("ChatTranscriptPresentation.timeline(in: snapshot)"))
        #expect(!chat.contains("ChatTranscriptPresentation.liveToolRun"))
        #expect(chat.contains(".safeAreaInset(edge: .bottom, spacing: 0)"))
        #expect(chat.contains(".frame(height: 12)"))
        #expect(!chat.contains("composerHeight + 20"))
        #expect(!chat.contains("ZStack(alignment: .bottom)"))
        #expect(!chat.contains(".padding(.bottom, composerHeight"))
        #expect(chat.contains("ChatTailFollowPolicy.shouldFollowContentGrowth"))
        #expect(chat.contains("ChatTailFollowPolicy.composerGrowthFollowDecision"))
        #expect(chat.contains(".onChange(of: composerHeight)"))
        #expect(chat.contains("pendingComposerGrowthFollow"))
        #expect(chat.contains("scheduleTailFollow(delay:"))
        #expect(chat.contains("ScrollPosition(idType: String.self, edge: .bottom)"))
        #expect(chat.contains("model.authoritativeSnapshot(for: sessionID)"))
        #expect(!chat.contains("ScrollViewReader"))
        #expect(!chat.contains("proxy.scrollTo"))
        #expect(chat.contains(".accessibilityHidden(!isTranscriptReady)"))
        let composerStage = (chat.components(separatedBy: "composer\n").dropFirst().first ?? "")
            .components(separatedBy: ".background {").first ?? ""
        #expect(!composerStage.contains(".opacity(isTranscriptReady"))
        #expect(!composerStage.contains(".accessibilityHidden(!isTranscriptReady)"))
        #expect(chat.contains("Opening conversation…"))
        #expect(chat.contains("Conversation unavailable"))
        #expect(!chat.contains("positionLatestTail(epoch:"))
        #expect(!chat.contains("failPositioning(sessionID:"))
        #expect(chat.contains(".equatable()"))
        #expect(!chat.contains("model.selectedSnapshot?.transcript.map(\\.id)"))
        #expect(chat.contains("TranscriptNotice("))
    }

    @Test("sheets use explicit reload toolbar actions instead of pull to refresh")
    func sheetReloadActions() throws {
        let sheetOwners = [
            "Sources/UI/Chat/SessionTreeSheet.swift",
            "Sources/UI/Settings/AgentExtensionSettings.swift",
            "Sources/UI/Settings/SettingsView.swift",
        ]
        for path in sheetOwners {
            let source = try String(contentsOf: packageRoot.appending(path: path), encoding: .utf8)
            #expect(!source.contains(".refreshable"), "\(path) still enables pull to refresh")
            #expect(source.contains("TronReloadToolbarButton"), "\(path) is missing an explicit reload action")
        }

        let shell = try String(
            contentsOf: packageRoot.appending(path: "Sources/UI/Chat/SessionShellView.swift"),
            encoding: .utf8
        )
        #expect(shell.contains(".refreshable { await model.refreshSessions() }"))
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
}
