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
        #expect(shell.contains("@State private var presentedSession: AppModel.SessionNavigationRoute?"))
        #expect(shell.contains(".navigationDestination(item: $presentedSession)"))
        #expect(shell.contains("initialEditorText: route.editorText"))
        #expect(shell.contains("onForkCreated: present"))
        #expect(shell.contains("model.revokePresentationIntake(target)"))
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
        #expect(context.contains("ProjectResourcesView(sessionID: sessionID)"))
        #expect(context.contains("snapshot.stats.latestCacheHitRate"))
        #expect(context.contains("let sessionID: String"))
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
        #expect(!runtimeSettings.contains("case .sessionDir"))
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

        let runtimeWorkingRowCall = "stableTranscriptRow(id: \"runtime-working\")"
        let runtimeWorkingRowCallCount = productionSources.reduce(0) { count, source in
            count + source.1.occurrences(of: runtimeWorkingRowCall)
        }
        #expect(
            runtimeWorkingRowCallCount == 1,
            "expected one mounted runtime working row, found \(runtimeWorkingRowCallCount)"
        )

        let chat = try #require(productionSources.first { $0.0.lastPathComponent == "ChatView.swift" }?.1)
        #expect(!chat.contains("snapshot.extensionUI.widgets.filter"))
        #expect(chat.occurrences(of: "ChatExtensionWidgetPolicy.visibleWidgets") == 2)
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
        let attachmentButton = try #require(
            chat.components(separatedBy: "private struct ComposerAttachmentMenuButton").dropFirst().first?
                .components(separatedBy: "private struct PendingAttachmentChip").first
        )
        #expect(attachmentButton.contains("UIButton(type: .custom)"))
        #expect(attachmentButton.contains("button.backgroundColor = .clear"))
        #expect(attachmentButton.contains("button.showsMenuAsPrimaryAction = true"))
        #expect(!attachmentButton.contains("for: .touchDown"))
        #expect(!attachmentButton.contains("onTouchDown"))
        #expect(attachmentButton.contains("button.isEnabled = isEnabled"))
        #expect(attachmentButton.contains("button.accessibilityLabel = \"Add attachment\""))
        let camera = try #require(attachmentButton.firstRange(of: "action(\"Take Photo\"")?.lowerBound)
        let photos = try #require(attachmentButton.firstRange(of: "action(\"Select Photos\"")?.lowerBound)
        let files = try #require(attachmentButton.firstRange(of: "action(\"Attach Files\"")?.lowerBound)
        #expect(camera < photos)
        #expect(photos < files)
        #expect(attachmentButton.contains("parent.onSelect(destination)"))
        #expect(chat.contains(".id(attachmentMenuState.identity)"))
        let attachmentMenu = try #require(
            chat.components(separatedBy: "private var attachmentButton: some View").dropFirst().first?
                .components(separatedBy: "private var catchUpButton").first
        )
        #expect(!attachmentMenu.contains("composerFocused = false"))
        #expect(!attachmentMenu.contains("resignFirstResponder"))
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

    @Test("tool details foreground semantic content and isolate technical JSON")
    func toolDetailPresentation() throws {
        let transcript = try String(
            contentsOf: packageRoot.appending(path: "Sources/UI/Chat/TranscriptRow.swift"),
            encoding: .utf8
        )
        let sheet = try String(
            contentsOf: packageRoot.appending(path: "Sources/UI/Chat/ToolDetailSheet.swift"),
            encoding: .utf8
        )
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
        #expect(transcript.contains("content.sheet(item: $route)"))
        #expect(transcript.contains("ToolDetailSheet("))
        #expect(transcript.contains("tool: tool"))
        #expect(transcript.contains("density: detent == .large ? .expanded : .glance"))
        #expect(transcript.contains(".presentationDetents([.medium, .large], selection: $detent)"))
        let runOwner = try #require(
            transcript.components(separatedBy: "struct ToolRunView: View {").dropFirst().first?
                .components(separatedBy: "private struct ToolRunChip: View {").first
        )
        #expect(runOwner.contains("@State private var detailRoute: ToolDetailRoute?"))
        #expect(runOwner.contains("@State private var detailDetent: PresentationDetent = .medium"))
        #expect(runOwner.contains("if let tool = run.tools.first, run.tools.count == 1"))
        #expect(runOwner.contains("detailRoute?.resolve(in: run.tools)"))
        let statePosition = try #require(runOwner.firstRange(of: "@State private var detailRoute")?.lowerBound)
        let branchPosition = try #require(runOwner.firstRange(of: "if let tool = run.tools.first")?.lowerBound)
        let hostPosition = try #require(runOwner.firstRange(of: ".toolDetailSheet(")?.lowerBound)
        #expect(statePosition < branchPosition)
        #expect(branchPosition < hostPosition)
        #expect(sheet.contains(".defaultScrollAnchor(.top, for: .initialOffset)"))
        #expect(sheet.contains(".defaultScrollAnchor(.top, for: .alignment)"))
        let navigationChrome = try #require(
            sheet.components(separatedBy: "func tronToolDetailNavigationChrome() -> some View {").dropFirst().first?
                .components(separatedBy: "private struct ToolTechnicalMetadataItem").first
        )
        #expect(navigationChrome.contains("navigationTitle(\"\")"))
        #expect(navigationChrome.contains(".navigationBarTitleDisplayMode(.inline)"))
        #expect(transcript.matches(#"\.tronToolDetailNavigationChrome\(\)"#) == 2)
        #expect(sheet.matches(#"\.tronToolDetailNavigationChrome\(\)"#) == 2)
        #expect(sheet.contains("title: \"Technical details\""))
        #expect(sheet.contains("ToolTechnicalDetailsSheet"))
        #expect(sheet.contains("ToolChipFlowLayout"))
        #expect(sheet.contains("ToolStatusChip"))
        #expect(sheet.contains("ToolMetadataChip"))
        let chipLayout = try #require(
            sheet.components(separatedBy: "private struct ToolChipFlowLayout: Layout {").dropFirst().first?
                .components(separatedBy: "private struct ToolActivityChip: View {").first
        )
        #expect(chipLayout.contains("let ideal = subview.sizeThatFits(.unspecified)"))
        #expect(chipLayout.contains("guard ideal.width > availableWidth else { return ideal }"))
        #expect(chipLayout.contains("sizeThatFits(ProposedViewSize(width: availableWidth, height: nil))"))
        #expect(chipLayout.contains("min(availableWidth, constrained.width)"))
        #expect(!chipLayout.contains(".fixedSize(horizontal: true"))
        #expect(chipLayout.matches(#"\.lineLimit\(2\)"#) >= 3)
        #expect(sheet.contains(".accessibilityLabel(item.accessibilityLabel)"))
        #expect(!sheet.contains(".accessibilityLabel(\"\\(item.label), \\(item.value)\")"))
        #expect(sheet.contains("ToolChangesSheet"))
        #expect(sheet.contains("if diff.showsInline"))
        #expect(sheet.contains("diff.visibleLines(for: density)"))
        #expect(sheet.contains("Text($0).foregroundColor(Color.tronTextSecondary)"))
        #expect(sheet.contains("Text(path.basename).foregroundColor(accent)"))
        let primaryDetail = try #require(
            sheet.components(separatedBy: "@ViewBuilder private func primarySection").dropFirst().first?
                .components(separatedBy: "private func pathText").first
        )
        #expect(primaryDetail.contains("presentation.kind == .bash"))
        #expect(primaryDetail.contains("Text(verbatim: preview.text)"))
        #expect(primaryDetail.contains(".font(TronTypography.codeContent)"))
        #expect(primaryDetail.contains(".fixedSize(horizontal: false, vertical: true)"))
        #expect(!primaryDetail.contains("ScrollView(.horizontal"))
        #expect(primaryDetail.contains("preview.isBounded, presentation.kind != .bash"))
        let resultDetail = try #require(
            sheet.components(separatedBy: "@ViewBuilder private func resultSection").dropFirst().first?
                .components(separatedBy: "private var technicalDetailsButton").first
        )
        #expect(resultDetail.contains(".font(TronTypography.code(size: TronTypography.sizeBodySM))"))
        let technicalDetail = try #require(
            sheet.components(separatedBy: "private struct ToolTechnicalDetailsSheet").dropFirst().first?
                .components(separatedBy: "private struct ToolTechnicalMetadataItem").first
        )
        let requestJSON = try #require(technicalDetail.firstRange(of: "payload(\"Request\", value: tool.request ?? .null)")?.lowerBound)
        let resultJSON = try #require(technicalDetail.firstRange(of: "payload(\"Result\", value: ToolTechnicalResultResolver.resolve(tool))")?.lowerBound)
        #expect(requestJSON < resultJSON)
        #expect(technicalDetail.contains("Text(value.prettyPrinted)"))
        #expect(technicalDetail.contains("ScrollView(.horizontal, showsIndicators: true)"))
        #expect(technicalDetail.contains("ToolTechnicalMetadataItem"))
        #expect(technicalDetail.contains("Command preview"))
        #expect(!technicalDetail.contains("TronSettingsRow"))
        #expect(!technicalDetail.contains("TronStructuredJSONView"))
        #expect(!technicalDetail.contains("readableOutput"))
        #expect(!technicalDetail.contains("Projected fallback"))
        #expect(sheet.contains("Complete available result data is in Technical details; Gateway marked the output truncated."))
        #expect(sheet.contains("Complete result data is available in Technical details."))
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
        #expect(timing.contains("private static let fractionalTimestamp = Date.ISO8601FormatStyle"))
        #expect(timing.contains("private static let wholeSecondTimestamp = Date.ISO8601FormatStyle"))
        #expect(!timing.contains("ISO8601DateFormatter"))
        #expect(structured.contains("showsRawDisclosure: showsRawDisclosure"))
        #expect(structured.contains("StructuredJSONPath.resolve(rootValue, components: selection.components)"))
        #expect(!transcript.contains(".prettyPrinted"))
        for tool in ["read", "write", "edit", "bash", "grep", "find", "ls"] {
            #expect(presentation.contains("case \"\(tool)\""), "missing semantic detail mapping for \(tool)")
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

    @Test("chat transcript controls preserve compact history pills and a glass catch-up control")
    func compactTranscriptPillPresentation() throws {
        let chat = try String(
            contentsOf: packageRoot.appending(path: "Sources/UI/Chat/ChatView.swift"),
            encoding: .utf8
        )
        let transcript = try String(
            contentsOf: packageRoot.appending(path: "Sources/UI/Chat/TranscriptRow.swift"),
            encoding: .utf8
        )
        let scrollCoordinator = try String(
            contentsOf: packageRoot.appending(path: "Sources/UI/Chat/ChatScrollCoordinator.swift"),
            encoding: .utf8
        )
        #expect(chat.contains("Load earlier messages"))
        #expect(!chat.contains("New response"))
        #expect(chat.components(separatedBy: ".chatTranscriptPill()").count - 1 >= 2)
        let catchUpButton = (chat.components(separatedBy: "private var catchUpButton").dropFirst().first ?? "")
            .components(separatedBy: "private var composerTrailingMode").first ?? ""
        #expect(catchUpButton.contains("Image(systemName: \"arrow.down\")"))
        #expect(catchUpButton.contains(".frame(width: 40, height: 40)"))
        #expect(!catchUpButton.contains("composerInputBarHeight"))
        #expect(catchUpButton.contains("in: .circle"))
        #expect(catchUpButton.contains(".glassEffectTransition(.matchedGeometry)"))
        #expect(catchUpButton.contains(".accessibilityLabel(\"Catch up\")"))
        #expect(catchUpButton.contains("catchUpToTail()"))
        #expect(!catchUpButton.contains(".chatTranscriptPill()"))
        #expect(scrollCoordinator.contains(".smooth(duration: 0.30)"))
        #expect(chat.contains("case .smooth(let duration)"))
        #expect(chat.contains("withAnimation(.smooth(duration: duration)"))
        #expect(chat.contains("GlassEffectContainer(spacing: 8)"))
        #expect(chat.contains("if scrollCoordinator.shouldShowCatchUpButton"))
        #expect(scrollCoordinator.contains("var shouldShowCatchUpButton: Bool { userScrolledAway }"))
        #expect(chat.contains("targetRenderedID: installed.timeline.ids.last"))
        #expect(chat.contains("requestOpeningTail(targetRenderedID: targetRenderedID)"))
        #expect(scrollCoordinator.contains("openingTailTargetRenderedID"))
        #expect(scrollCoordinator.contains("semanticFrames[targetRenderedID]"))
        #expect(scrollCoordinator.contains("openingTailPresentation == presentation"))
        #expect(chat.contains("ChatTranscriptPresentationStore"))
        #expect(!chat.contains("ChatTranscriptPresentation.timeline("))
        #expect(transcript.contains("struct ChatTranscriptPillModifier: ViewModifier"))
        #expect(transcript.contains("TronTypography.sizeBodySM"))
        #expect(transcript.contains(".padding(.vertical, 6)"))
        #expect(transcript.contains(".fixedSize(horizontal: false, vertical: true)"))
        #expect(transcript.contains(".frame(minWidth: 44, minHeight: 44)"))
        #expect(transcript.contains(".contentShape(Rectangle())"))
        #expect(!transcript.contains(".fixedSize()"))
        #expect(transcript.contains("detail: item.tokensBefore.map(ChatTokenCountPresentation.beforeCompaction)"))
        #expect(transcript.components(separatedBy: ".chatTranscriptPill()").count - 1 == 1)
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
        #expect(chat.contains("toolbarContainerWidth = ChatToolbarTitleLayout.defaultContainerWidth"))
        #expect(chat.contains(".onGeometryChange(for: CGFloat.self)"))
        #expect(chat.contains("ChatToolbarTitleLayout.width(containerWidth: toolbarContainerWidth)"))
        let toolbarTitle = (chat.components(separatedBy: "Text(chatTitle)").dropFirst().first ?? "")
            .components(separatedBy: "ToolbarItem(placement: .primaryAction)").first ?? ""
        #expect(toolbarTitle.contains(".lineLimit(1)"))
        #expect(toolbarTitle.contains(".truncationMode(.tail)"))
        #expect(toolbarTitle.contains(".frame(width: titleWidth)"))
        #expect(toolbarTitle.contains(".clipped()"))
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
        #expect(shell.contains("HistoricalSessionRow("))
        #expect(shell.contains("activity: model.dashboardActivity(for: session.id)"))
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
        let scrollCoordinator = try String(
            contentsOf: packageRoot.appending(path: "Sources/UI/Chat/ChatScrollCoordinator.swift"),
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
        #expect(transcript.contains(".frame(minWidth: 48, alignment: .trailing)"))
        #expect(transcript.contains(".fixedSize(horizontal: true, vertical: false)"))
        #expect(!transcript.contains(".frame(width: 48, alignment: .trailing)"))
        #expect(chat.contains("SessionContextSheet(sessionID: sessionID, onForkCreated: onForkCreated)"))
        #expect(!chat.contains("ChatTranscriptPresentation.liveToolRun"))
        #expect(chat.contains(".safeAreaInset(edge: .bottom, spacing: 0)"))
        #expect(!chat.contains("composer.fixedSize(horizontal: false, vertical: true)"))
        #expect(!chat.contains("applyViewportAdjustment"))
        let inputBar = (chat.components(separatedBy: "private var composerInputBar").dropFirst().first ?? "")
            .components(separatedBy: "private var attachmentButton").first ?? ""
        #expect(inputBar.contains("attachmentButton"))
        #expect(!inputBar.contains(".overlay(alignment: .bottomLeading)"))
        let attachmentButton = (chat.components(separatedBy: "private var attachmentButton").dropFirst().first ?? "")
            .components(separatedBy: "private var catchUpButton").first ?? ""
        #expect(attachmentButton.contains("Image(systemName: \"plus\")"))
        #expect(attachmentButton.contains(".font(TronTypography.sans(size: TronTypography.sizeBodySM, weight: .semibold))"))
        #expect(attachmentButton.contains(".foregroundStyle(attachmentActionsEnabled ? Color.tronEmerald : Color.tronTextMuted)"))
        #expect(attachmentButton.contains(".allowsHitTesting(false)"))
        #expect(attachmentButton.contains("ComposerAttachmentMenuButton("))
        #expect(!attachmentButton.contains("onTouchDown"))
        #expect(attachmentButton.contains("onSelect: requestAttachmentPresentation"))
        #expect(!attachmentButton.contains("Menu {"))
        #expect(!chat.contains(".contentMargins(.horizontal, 16, for: .scrollContent)"))
        let stableRow = (chat.components(separatedBy: "private func stableTranscriptRow").dropFirst().first ?? "")
            .components(separatedBy: "private var selectedAuthoritativeSnapshot").first ?? ""
        #expect(stableRow.contains(".padding(.horizontal, 16)"))
        #expect(chat.contains("scrollCoordinator.geometryChanged"))
        #expect(chat.contains("geometry.hasViewportChange(from: previous)"))
        #expect(chat.contains("scrollCoordinator.viewportChanged"))
        #expect(chat.contains(".defaultScrollAnchor(.top, for: .alignment)"))
        #expect(!chat.contains(".defaultScrollAnchor(.bottom, for: .alignment)"))
        #expect(!chat.contains(".defaultScrollAnchor(.bottom, for: .sizeChanges)"))
        #expect(scrollCoordinator.contains("publish(.releaseBinding"))
        #expect(!chat.contains("releaseSettledScrollBindingIfNeeded"))
        #expect(chat.contains("transcriptScrollPosition = ScrollPosition(idType: String.self)"))
        #expect(chat.contains("transcriptScrollPosition.isPositionedByUser"))
        #expect(!chat.contains("composerHeight"))
        #expect(!chat.contains("ComposerHeightPreferenceKey"))
        #expect(!chat.contains("scheduleTailFollow"))
        #expect(!chat.contains("tailFollowTask"))
        #expect(!chat.contains(".transition(reduceMotion ? .opacity : .opacity.combined(with: .scale"))
        #expect(chat.contains("ScrollPosition(idType: String.self, edge: .bottom)"))
        #expect(chat.contains("model.authoritativeSnapshot(for: sessionID)"))
        #expect(!chat.contains("ScrollViewReader"))
        #expect(!chat.contains("proxy.scrollTo"))
        let composerStage = (chat.components(separatedBy: ".safeAreaInset(edge: .bottom, spacing: 0)").dropFirst().first ?? "")
            .components(separatedBy: ".overlay(alignment: .top) { topBlur }").first ?? ""
        #expect(!composerStage.contains(".accessibilityHidden(!isTranscriptReady)"))
        #expect(!composerStage.contains(".allowsHitTesting(isTranscriptReady)"))
        #expect(chat.contains("isEditable: ChatComposerPolicy.isTextEditable(isTranscriptReady: isTranscriptReady)"))
        #expect(chat.contains("Color.tronBackground.ignoresSafeArea(.all)"))
        let composerControl = try String(
            contentsOf: packageRoot.appending(path: "Sources/UI/Chat/ComposerControls.swift"),
            encoding: .utf8
        )
        #expect(composerControl.contains("private var layoutRevision: UInt = 0"))
        #expect(composerControl.contains("self.layoutRevision == revision"))
        #expect(chat.contains("Opening conversation…"))
        #expect(chat.contains("Conversation unavailable"))
        #expect(chat.contains("positionLatestTail(epoch:"))
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

    func occurrences(of string: String) -> Int {
        components(separatedBy: string).count - 1
    }
}
