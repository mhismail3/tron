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
        #expect(store.contains("preparedText: built.preparedText"))
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
            "AgentDefaultsSettingsView.swift", "AppearanceSettingsView.swift", "ConnectionSettingsView.swift",
            "CustomModelsSettingsView.swift", "GatewayDiagnosticsView.swift", "PackagesSettingsView.swift", "ProviderSettingsView.swift",
            "ResourceSettingsView.swift", "RuntimeBehaviorSettingsView.swift", "SettingsView.swift", "ProjectResourcesView.swift", "ExtensionInteractionSheet.swift",
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
            if !allowedNavigationChevrons {
                #expect(
                    !source.contains("Image(systemName: \"chevron.right\")"),
                    "\(url.lastPathComponent) contains a decorative disclosure chevron"
                )
            }
        }
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
        #expect(blur.contains("@Environment(\\.colorScheme) private var colorScheme"))
        #expect(blur.matches(#"Color\.black\.opacity\(0\.28\)"#) >= 2)
        #expect(chat.contains("TronTopBlurOverlay(style: .chat)"))
        #expect(shell.contains("TronTopBlurOverlay(style: .dashboard)"))
        #expect(blur.contains("struct ChatBottomActivityBlur: View"))
        #expect(blur.contains("static let bottomHeight: CGFloat = 68"))
        #expect(blur.contains("static let keyboardHeight: CGFloat = 80"))
        #expect(blur.contains("static let bottomSafeAreaTranslation: CGFloat = 44"))
        #expect(blur.contains("static let keyboardTranslation: CGFloat = 24"))
        #expect(blur.contains("static let radius: CGFloat = 10"))
        #expect(blur.contains("static let activeTintOpacity = 0.105"))
        #expect(blur.contains("static let lightRestingTintOpacity = 0.045"))
        #expect(blur.contains("static let lightActiveTintOpacity = 0.18"))
        #expect(blur.contains("static let lightReduceMotionTintOpacity = 0.085"))
        #expect(blur.contains("@Environment(\\.colorScheme) private var colorScheme"))
        #expect(blur.contains("colorScheme == .light"))
        #expect(blur.contains(".rotationEffect(.degrees(180))"))
        #expect(blur.contains("TimelineView(.animation("))
        #expect(blur.contains("paused: !isActive || reduceMotion || scenePhase != .active"))
        #expect(blur.contains("struct ChatThinkingWaveform: View"))
        #expect(blur.contains("pulsePhase(at: date)"))
        #expect(blur.contains(".accessibilityLabel(\"Tron is working\")"))
        #expect(blur.contains(".accessibilityHidden(!isActive)"))
        #expect(chat.contains(".background(alignment: .bottom)"))
        #expect(chat.contains("ChatBottomActivityBlur("))
        #expect(chat.contains("isActive: showsAmbientWorkingBlur"))
        #expect(chat.contains("keyboardVisible: composerFocused"))
        #expect(chat.contains(".offset(y: ChatBottomActivityBlurLayout.translation("))
        #expect(chat.contains("keyboardVisible: composerFocused"))
        #expect(chat.contains("value: composerFocused"))
        #expect(chat.contains(".ignoresSafeArea(edges: .bottom)"))
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
        #expect(!chat.contains("Text(\"Tron is working\")"))

        for (url, source) in uiSources {
            let detentCount = source.matches(#"\.presentationDetents\(\[\.medium, \.large\]"#)
            let blurCount = source.matches(#"\.tronTopBlur\(\.sheet\)"#)
            #expect(
                blurCount >= detentCount,
                "\(url.lastPathComponent) has \(detentCount) medium/large sheets but only \(blurCount) sheet blurs"
            )
        }
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
        #expect(sheet.contains(".alert(\"Terminal action failed\""))
        #expect(!sheet.contains("Task { await controller"))
        #expect(!sheet.contains("final class TerminalController"))
        #expect(!sheet.contains("UIViewRepresentable"))
        #expect(presentation.contains("final class TerminalController"))
        #expect(presentation.contains("private var lifecycleFlight: LifecycleFlight?"))
        #expect(presentation.contains("private var pendingLifecycleRequest: LifecycleRequest?"))
        #expect(presentation.contains("var actionError: String?"))
        #expect(presentation.contains("func start(sessionID: String, model: AppModel)"))
        #expect(!presentation.contains("import SwiftTerm"))
        #expect(!presentation.contains("UIViewRepresentable"))
        #expect(renderer.contains("struct NativeTerminal: UIViewRepresentable"))
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
        #expect(shell.contains("NewSessionSheet(onCreated: present)"))
        #expect(!shell.contains("struct NewSessionSheet: View"))
        #expect(newSession.contains("@State private var configurationOwner = NewSessionConfigurationOwner()"))
        #expect(newSession.contains("@State private var creationOwner = NewSessionCreationOwner()"))
        #expect(newSession.contains(".task(id: NewSessionConfigurationLoadID("))
        #expect(newSession.contains(".disabled(creating || !configurationReady)"))
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
        let providerSettings = try String(
            contentsOf: packageRoot.appending(path: "Sources/UI/Settings/ProviderSettingsView.swift"),
            encoding: .utf8
        )
        let providers = try String(
            contentsOf: packageRoot.appending(path: "Sources/UI/Onboarding/SetupComponents.swift"),
            encoding: .utf8
        )
        let globalSheets = try String(
            contentsOf: packageRoot.appending(path: "Sources/UI/Components/GlobalSheets.swift"),
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
        #expect(!appearance.contains("TronSettingsGroup(\"Color Mode\""))
        #expect(!appearance.contains(".pickerStyle(.segmented)"))
        #expect(appearance.contains("icon: \"textformat.size\""))
        #expect(appearance.contains("icon: \"slider.horizontal.3\""))
        let textFontSection = (appearance.components(separatedBy: "TronSettingsGroup(\"Text Font\"").dropFirst().first ?? "")
            .components(separatedBy: "TronSettingsGroup(\"Code Font\"").first ?? ""
        let textSlider = try #require(textFontSection.firstRange(of: "axisSlider(")?.lowerBound)
        let textPreview = try #require(textFontSection.firstRange(of: "The quick brown fox")?.lowerBound)
        #expect(textSlider < textPreview)
        let codeFontSection = (appearance.components(separatedBy: "TronSettingsGroup(\"Code Font\"").dropFirst().first ?? "")
            .components(separatedBy: "TronSettingsGroup(\"About Fonts\"").first ?? ""
        let codeSlider = try #require(codeFontSection.firstRange(of: "axisSlider(")?.lowerBound)
        let codePreview = try #require(codeFontSection.firstRange(of: "let result = await tron.run()")?.lowerBound)
        #expect(codeSlider < codePreview)
        #expect(connections.contains("struct ConnectionsSettingsView"))
        #expect(connections.contains("struct ImportSettingsView"))
        #expect(providerSettings.contains("struct ProvidersSettingsView"))
        #expect(defaults.contains("struct AgentDefaultsSettingsView"))
        #expect(settings.contains(".sheet(isPresented: $isPresented)"))
        #expect(!settings.contains("Button(\"Log Out\""))
        #expect(settings.contains("enum Scope { case dashboard, project }"))
        #expect(settings.contains("if scope == .project"))
        #expect(settings.contains("ImportSettingsView(onImported: onImported)"))
        #expect(settings.contains("VStack(spacing: 16)"))
        #expect(!settings.contains("LazyVStack(spacing: 16)"))
        #expect(!settings.contains("Import Legacy Sessions"))
        #expect(providerSettings.contains(".providerAuthPresenter()"))
        #expect(providerSettings.contains("currently visible provider"))
        #expect(globalSheets.contains("@State private var presentedOperationID: String?"))
        #expect(globalSheets.contains("cancelAuth(operationID: closingOperationID)"))
        #expect(!globalSheets.contains("Task { await model.cancelAuth() }"))
        #expect(providers.contains("Button(\"Log Out\", systemImage: \"rectangle.portrait.and.arrow.right\", role: .destructive)"))
        #expect(providers.contains("Image(systemName: \"ellipsis\")"))
        #expect(providers.contains("size: TronTypography.sizeBody, weight: .bold"))
        #expect(providers.contains("provider.configured ? 0.14 : 0.08"))
        #expect(providers.contains("return \"Connected - "))
        #expect(!providers.contains("Label(\"Connected\""))
        #expect(providers.contains(".lineLimit(1)"))
        #expect(!providers.contains("glassEffect"))
        #expect(defaults.contains("TronInlineMenu(draft.trust.capitalized, accent: .tronAmber)"))
        #expect(defaults.contains("TronSettingsGroup(\"Project Resources\", accent: .tronAmber)"))
        #expect(defaults.contains("Text(\"Trust controls project resource loading; it is not a sandbox.\")"))
        #expect(!defaults.contains("accessibilityLabel(\"Default Trust:"))
        #expect(!defaults.contains("Menu {"))
        #expect(defaults.contains("TronSaveToolbarButton"))
        #expect(defaults.contains("isEnabled: hasUnsavedChanges"))
        #expect(defaults.contains("drafts.install(draft, for: target)"))
        #expect(!defaults.contains("Save Defaults"))
        #expect(runtime.contains("TronSaveToolbarButton"))
        #expect(runtime.contains("isEnabled: hasUnsavedChanges"))
        #expect(runtime.contains(".padding(.horizontal, 14)"))
        #expect(runtime.contains(".padding(.bottom, 12)"))
        #expect(runtime.contains("TronInlineField(numeric: true)"))
        #expect(runtime.contains("drafts.install(draft, for: target)"))
        #expect(!runtime.contains("Save Runtime Settings"))
        #expect(resources.contains("TronSaveToolbarButton"))
        #expect(resources.contains("isEnabled: hasUnsavedChanges"))
        #expect(resources.contains("pathEditor(value)"))
        #expect(resources.contains(".multilineTextAlignment(.leading)"))
        #expect(resources.contains("minHeight: value.acceptsMultipleLines ? 120 : 52"))
        #expect(resources.contains("drafts.install(draft, for: target)"))
        #expect(!resources.contains("Save Changes"))
        #expect(customModels.contains("TronSaveToolbarButton"))
        #expect(customModels.contains("isEnabled: canSave"))
        #expect(!customModels.contains("Save and Restart"))
        #expect(connections.contains("Button(importing ? \"Importing…\" : \"Import Legacy Sessions\")"))
        #expect(trust.contains("summary.stateIcon"))
        #expect(trust.contains("frame(width: 38, height: 38)"))
        let saveToolbarButton = (presentation.components(separatedBy: "struct TronSaveToolbarButton").dropFirst().first ?? "")
            .components(separatedBy: "struct TronReloadToolbarButton").first ?? ""
        #expect(saveToolbarButton.contains(".tronToolbarAction()"))
        #expect(saveToolbarButton.contains("Color.tronTextMuted"))
        #expect(saveToolbarButton.contains("private var actionColor"))
        #expect(saveToolbarButton.contains(".tint(actionColor)"))
        #expect(!saveToolbarButton.contains(".buttonStyle(.glass)"))
        #expect(!saveToolbarButton.contains(".buttonBorderShape(.capsule)"))
        #expect(presentation.contains("static var numericValue"))
        #expect(presentation.contains("static var codeJSON"))
        #expect(structuredJSON.contains("TronTypography.codeJSON"))
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
            contentsOf: packageRoot.appending(path: "Sources/UI/Settings/GatewayDiagnosticsView.swift"),
            encoding: .utf8
        )
        let packages = try String(
            contentsOf: packageRoot.appending(path: "Sources/UI/Settings/PackagesSettingsView.swift"),
            encoding: .utf8
        )
        #expect(context.contains("ProjectResourcesView(sessionID: sessionID)"))
        #expect(context.contains("case agentContext, projectResources, history, terminal"))
        #expect(context.contains("destination = .projectResources"))
        #expect(context.contains("TronSettingsGroup(\"Configuration\""))
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
        #expect(history.components(separatedBy: ".frame(width: SessionHistoryCardMetrics.iconWidth)").count - 1 == 4)
        let eventRows = (history.components(separatedBy: "private struct TreeNodeRow").dropFirst().first ?? "")
            .components(separatedBy: "private struct HistoryEntryDetailsSheet").first ?? ""
        #expect(eventRows.contains("Text(title)\n                                .font(TronTypography.body)"))
        #expect(!eventRows.contains("Text(title)\n                                .font(TronTypography.headline)"))
        #expect(!history.contains(".glassEffect(.regular.tint(accent.opacity(0.14)).interactive(), in: .circle)"))
        #expect(history.contains(".frame(width: 44, height: 44)\n                    .contentShape(Rectangle())"))
        let detailActions = (history.components(separatedBy: "TronSettingsGroup(\"Actions\"").dropFirst().first ?? "")
            .components(separatedBy: "private func actionRow").first ?? ""
        let bookmarkAction = try #require(detailActions.firstRange(of: "Add Bookmark")?.lowerBound)
        let forkAction = try #require(detailActions.firstRange(of: "Fork New Session")?.lowerBound)
        #expect(bookmarkAction < forkAction)
        #expect(resources.contains("Text(\"Reload\")"))
        #expect(resources.contains("try await model.reloadResources(sessionID: sessionID)"))
        let reloadOwner = (resources.components(separatedBy: "private func reload()").dropFirst().first ?? "")
            .components(separatedBy: "private func load()").first ?? ""
        #expect(!reloadOwner.contains("await model.loadResources("))
        #expect(resources.contains("@State private var reloading = false"))
        #expect(resources.contains("@State private var loadGeneration = 0"))
        #expect(resources.contains("guard generation == loadGeneration else { return }"))
        #expect(resources.contains("loading || reloading"))
        #expect(resources.contains("ToolbarItem(placement: .topBarLeading)"))
        #expect(resources.contains("TronSheetTitle(title: \"Project Resources\")"))
        #expect(context.contains("snapshot.stats.latestCacheHitRate"))
        #expect(context.contains("ProgressView(value: percent, total: 100)"))
        #expect(context.contains(".accessibilityLabel(usage.accessibilityLabel)"))
        #expect(context.contains("Context usage: "))
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
        #expect(structuredJSON.contains("ScrollView(.vertical, showsIndicators: true)"))
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
        #expect(context.contains("exportError = error.localizedDescription"))
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
        #expect(resources.contains("TronSettingsGroup(\"At a Glance\""))
        #expect(resources.contains("private func capabilityCollection("))
        #expect(resources.contains("LazyVGrid("))
        #expect(resources.contains("presentation.tools"))
        #expect(resources.contains("presentation.commands"))
        #expect(resources.contains("TronTechnicalJSONRow("))
        #expect(resources.contains(".fixedSize(horizontal: false, vertical: true)"))
        #expect(terminalSheet.contains(".alert(\"Quit Terminal?\""))
        #expect(!terminalSheet.contains(".confirmationDialog(\"Quit this terminal?\""))
        let diagnostics = try String(
            contentsOf: packageRoot.appending(path: "Sources/State/GatewayDiagnosticsService.swift"),
            encoding: .utf8
        )
        #expect(settings.contains("private extension GatewayLogRecord"))
        #expect(settings.contains("Newest entries first"))
        #expect(settings.contains("await model.requestGatewayRestart()"))
        #expect(settings.contains("records = try await model.gatewayDiagnostics.logs(limit: 300)"))
        #expect(!settings.contains("try? await model."))
        #expect(context.contains("model.gatewayDiagnostics.inspectGit"))
        #expect(context.contains("SessionGitPresentation"))
        #expect(context.contains("gitPresentation = .loading"))
        #expect(context.contains("SessionGitLoadAdmission.admits"))
        #expect(context.contains("gitLoadGeneration &+= 1"))
        #expect(context.contains("case .failed"))
        #expect(!context.contains("await model.refreshSessions()"))
        let gitTask = (context.components(separatedBy: ".task(id: model.authoritativeSnapshot(for: sessionID)?.cwd)").dropFirst().first ?? "")
            .components(separatedBy: ".task(id: model.sessionContextRevision").first ?? ""
        #expect(gitTask.contains("await loadGit("))
        #expect(!gitTask.contains("loadContext("))
        #expect(!gitTask.contains("loadResources("))
        #expect(context.contains(".task(id: model.sessionContextRevision(for: sessionID))"))
        #expect(resources.contains(".task(id: model.sessionResourceRevision(for: sessionID))"))
        let presentationStore = try String(
            contentsOf: packageRoot.appending(path: "Sources/State/SessionPresentationStore.swift"),
            encoding: .utf8
        )
        for owner in ["contextLoadGeneration", "treeLoadGeneration", "resourceLoadGeneration"] {
            #expect(presentationStore.contains(owner))
        }
        #expect(presentationStore.contains("prepareSecondaryProjectionForRuntimeInstallation(installed)"))
        #expect(presentationStore.contains("ownsSubscription(sessionID: sessionID, requestedToken: token)"))
        #expect(settings.contains("model.gatewayDiagnostics.logs"))
        #expect(!context.contains("model.client"))
        #expect(!settings.contains("model.client"))
        #expect(diagnostics.contains("request(\"git.inspect\""))
        #expect(diagnostics.contains("request(\"system.logs\""))
        #expect(customModels.contains("Advanced JSON"))
        #expect(customModels.contains("private var providersSection: some View"))
        #expect(!customModels.contains("TronSettingsGroup(\"Providers\""))
        #expect(customModels.contains("CustomModelProviderRow("))
        #expect(customModels.contains("private struct CustomModelProviderRow"))
        #expect(customModels.contains("private func providerEditorSheet("))
        #expect(customModels.contains("fieldLabel(\"Provider identifier\")"))
        #expect(customModels.contains("TronTechnicalJSONRow("))
        #expect(customModels.contains("titleColor: .tronEmerald"))
        #expect(customModels.contains("TronTypography.code(size: TronTypography.sizeBody2)"))
        #expect(customModels.contains("Button { isPresented = true }"))
        #expect(customModels.contains("Image(systemName: \"ellipsis\")"))
        #expect(!customModels.contains("chevron.right"))
        let providerSummary = (customModels.components(separatedBy: "private func providerSummary").dropFirst().first ?? "")
            .components(separatedBy: "private func providerEditorSheet").first ?? ""
        #expect(!providerSummary.contains("tronGlassSurface"))
        let providerEditor = (customModels.components(separatedBy: "private func providerEditorSheet").dropFirst().first ?? "")
            .components(separatedBy: "private func fieldLabel").first ?? ""
        #expect(providerEditor.contains("editorSectionHeader(\n                    \"Connection\""))
        #expect(providerEditor.contains("editorSectionHeader(\n                    \"Models\""))
        #expect(providerEditor.contains("editorSectionHeader(\n                    \"Protocol\""))
        #expect(!providerEditor.contains("Identify the provider and choose the endpoint."))
        #expect(providerEditor.contains("dense: true"))
        #expect(providerEditor.contains("surfaceTint: Color.tronEmerald.opacity(0.14)"))
        #expect(providerEditor.contains("TronValueRow(icon: \"network\", title: \"API format\""))
        #expect(providerEditor.components(separatedBy: "TronSettingsGroup").count - 1 == 0)
        #expect(providerEditor.components(separatedBy: "tronGlassSurface").count - 1 == 1)
        #expect(!customModels.contains("expandedProviderIDs"))
        #expect(!customModels.contains("DisclosureGroup(isExpanded: isExpanded)"))
        #expect(trust.contains("VStack(spacing: 10)"))
        #expect(trust.contains("Text(\"Decision\")"))
        #expect(!trust.contains("TronSettingsGroup(\"Decision\""))
        #expect(!trust.contains("VStack(spacing: 0)"))
        let packageOverview = packages.components(separatedBy: "struct PackageResolvedResourcesView").first ?? ""
        let packageDetail = packages.components(separatedBy: "struct PackageResolvedResourcesView").dropFirst().first ?? ""
        #expect(packageOverview.contains("TronProgressiveSheetLink("))
        #expect(packageOverview.contains("accessibilityLabel: \"Inspect resolved resources, \\(summary)\""))
        #expect(packageOverview.contains("Inspect Resolved Resources"))
        #expect(packageOverview.contains("private var packageInstallSheet: some View"))
        #expect(packageOverview.contains("presentationDetents([.medium, .large])"))
        #expect(packageOverview.contains("await model.checkPackageUpdates(target: target"))
        #expect(!packageOverview.contains("TronSettingsGroup(\"Updates\""))
        #expect(!packageOverview.contains("Update All"))
        #expect(!packageOverview.contains("Check for Updates"))
        #expect(!packageOverview.contains("TronStructuredJSONView"))
        #expect(packageDetail.contains("TronStructuredJSONView"))
        let runtimeSettings = try String(
            contentsOf: packageRoot.appending(path: "Sources/UI/Settings/ResourceSettingsView.swift"),
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

        let runtimeProjectionCount = productionSources.reduce(0) { count, source in
            count + source.1.occurrences(of: "ChatNotificationPresentation.runtime(in:")
        }
        #expect(runtimeProjectionCount == 1)
        #expect(productionSources.contains { $0.1.contains("let runtimeItems: [ChatTranscriptRenderItem]") })

        let chat = try #require(productionSources.first { $0.0.lastPathComponent == "ChatView.swift" }?.1)
        #expect(!chat.contains("snapshot.extensionPresentation.semanticState.widgets.filter"))
        #expect(chat.occurrences(of: "ChatExtensionWidgetPolicy.mergedItems") == 2)
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
        let attachmentPresentation = try String(
            contentsOf: packageRoot.appending(path: "Sources/UI/Chat/ChatAttachmentPresentation.swift"),
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
            attachmentPresentation.components(separatedBy: "struct ComposerAttachmentMenuButton").dropFirst().first?
                .components(separatedBy: "struct PendingAttachmentChip").first
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
        #expect(attachmentButton.contains("UIColor(Color.tronEmerald)"))
        #expect(attachmentButton.contains("renderingMode: .alwaysOriginal"))
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
        let pendingStrip = (chat.components(separatedBy: "if !pendingAttachments.isEmpty").dropFirst().first ?? "")
            .components(separatedBy: "GlassEffectContainer(spacing: 8)").first ?? ""
        #expect(pendingStrip.contains("ScrollView(.horizontal, showsIndicators: false)"))
        #expect(pendingStrip.contains(".scrollClipDisabled()"))
        let pendingChip = attachmentPresentation.components(separatedBy: "struct PendingAttachmentChip").dropFirst().first ?? ""
        let imagePreview = (pendingChip.components(separatedBy: "private var imagePreview").dropFirst().first ?? "")
            .components(separatedBy: "private var imageBase").first ?? ""
        let imageBase = (pendingChip.components(separatedBy: "private var imageBase").dropFirst().first ?? "")
            .components(separatedBy: "private var decodedPreviewImage").first ?? ""
        let fileChip = (pendingChip.components(separatedBy: "private var fileChip").dropFirst().first ?? "")
        #expect(imagePreview.contains("PendingAttachmentImagePreviewSheet("))
        #expect(pendingChip.contains("AttachmentImagePreviewSheet(image: image)"))
        #expect(pendingChip.contains("model.chatMedia.prepareLocalFullPreview"))
        #expect(pendingChip.contains("await prepareFullPreview(fullPreviewData)"))
        #expect(imagePreview.contains(".overlay(alignment: .topTrailing)"))
        #expect(imagePreview.contains("PendingPhotoRemoveLayoutPolicy.visibleDiameter"))
        #expect(imagePreview.contains("PendingPhotoRemoveLayoutPolicy.touchTarget"))
        #expect(imagePreview.contains("PendingPhotoRemoveLayoutPolicy.centerOnTopTrailingCornerOffset"))
        #expect(imagePreview.contains("size: TronTypography.sizeCaption"))
        #expect(imagePreview.contains("weight: .bold"))
        #expect(!imagePreview.contains(".glassEffect("))
        #expect(!imagePreview.contains(".clipShape("))
        #expect(imageBase.contains("PendingPhotoRemoveLayoutPolicy.previewSide"))
        #expect(imageBase.contains(".regular.tint(Color.tronBlue.opacity(0.18)),"))
        #expect(imageBase.contains(".clipShape(RoundedRectangle(cornerRadius: 14"))
        #expect(!imageBase.contains("Color.tronBlue.opacity(0.18)).interactive()"))
        #expect(fileChip.contains(".frame(width: 28, height: 28)"))
        #expect(fileChip.contains(".padding(.vertical, 5)"))
        #expect(preview.contains(".presentationDetents([.medium])"))
        #expect(preview.contains("ConcentricRectangle("))
        #expect(preview.contains("maximumZoomScale = 5"))
        let sentImageChip = (transcript.components(separatedBy: "private struct TranscriptImageChip").dropFirst().first ?? "")
            .components(separatedBy: "private struct TranscriptFileChip").first ?? ""
        #expect(!sentImageChip.isEmpty)
        #expect(sentImageChip.contains(".frame(width: 64, height: 64)"))
        #expect(sentImageChip.contains(".sheet(item: $previewRequest)"))
        #expect(sentImageChip.contains("AttachmentImagePreviewSheet(image: previewImage ?? request.initialImage)"))
        #expect(sentImageChip.contains("model.chatMedia.thumbnail(for: identity)"))
        #expect(sentImageChip.contains("model.chatMedia.fullPreview("))
        let sentAttachmentStrip = try #require(
            transcript.components(separatedBy: "private var attachmentStrip: some View").dropFirst().first?
                .components(separatedBy: "private struct UserPromptGlassModifier").first
        )
        #expect(sentAttachmentStrip.contains(".padding(.vertical, item.role == .user ? 3 : 0)"))
        #expect(sentImageChip.contains("leaseID: request.leaseID"))
        #expect(!sentImageChip.contains(".sheet(isPresented:"))
        #expect(!sentImageChip.contains("model.client.blob"))
        #expect(!sentImageChip.contains(".presentationDetents([.medium, .large])"))
        #expect(!transcript.contains("private struct ZoomableAttachmentImage"))
        #expect(transcript.contains("private struct TranscriptFileChip"))
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
        #expect(runOwner.contains("@State private var resolvedDetail: ChatToolPresentation?"))
        #expect(runOwner.contains("@State private var resolvedGroup: [ChatToolPresentation]?"))
        #expect(runOwner.contains("@State private var detailDetent: PresentationDetent = .medium"))
        #expect(runOwner.contains("if let tool = run.tools.first, run.tools.count == 1"))
        #expect(runOwner.contains("resolveDetails([toolID], installationTag)"))
        #expect(runOwner.contains("resolveDetails(detailToolIDs, installationTag)"))
        #expect(runOwner.contains("tool: resolvedDetail"))
        let statePosition = try #require(runOwner.firstRange(of: "@State private var detailRoute")?.lowerBound)
        let branchPosition = try #require(runOwner.firstRange(of: "if let tool = run.tools.first")?.lowerBound)
        let hostPosition = try #require(runOwner.firstRange(of: ".toolDetailSheet(")?.lowerBound)
        #expect(statePosition < branchPosition)
        #expect(branchPosition < hostPosition)
        #expect(sheet.contains(".defaultScrollAnchor(.top, for: .initialOffset)"))
        #expect(sheet.contains(".defaultScrollAnchor(.top, for: .alignment)"))
        #expect(navigationChrome.contains("navigationTitle(\"\")"))
        #expect(navigationChrome.contains(".navigationBarTitleDisplayMode(.inline)"))
        #expect(transcript.matches(#"\.tronToolDetailNavigationChrome\(\)"#) == 2)
        #expect(detailSheets.matches(#"\.tronToolDetailNavigationChrome\(\)"#) == 3)
        #expect(sheet.contains("title: \"Technical details\""))
        #expect(sheet.contains("ToolTechnicalDetailsSheet"))
        #expect(sheet.contains("ToolChipFlowLayout"))
        #expect(sheet.contains("ToolStatusChip"))
        #expect(sheet.contains("ToolMetadataChip"))
        let chipLayout = try #require(
            sheet.components(separatedBy: "struct ToolChipFlowLayout: Layout {").dropFirst().first?
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
        #expect(changesSheet.contains("ToolDiffView(lines: diff.lines)"))
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
            technicalSheet.components(separatedBy: "struct ToolTechnicalDetailsSheet").dropFirst().first?
                .components(separatedBy: "private struct ToolTechnicalMetadataItem").first
        )
        let requestJSON = try #require(technicalDetail.firstRange(of: "payload(\"Request\", value: tool.request ?? .null)")?.lowerBound)
        let resultJSON = try #require(technicalDetail.firstRange(of: "payload(\"Result\", value: ToolTechnicalResultResolver.resolve(tool))")?.lowerBound)
        #expect(requestJSON < resultJSON)
        #expect(!technicalDetail.contains("Text(value.prettyPrinted)"))
        #expect(!technicalDetail.contains("ScrollView(.horizontal, showsIndicators: true)"))
        #expect(technicalDetail.contains("TronTechnicalJSONRow("))
        #expect(!technicalDetail.contains(".sheet(item: $selectedPayload)"))
        #expect(technicalDetail.contains("ToolTechnicalMetadataItem"))
        #expect(technicalDetail.contains("sheetSectionHeader"))
        #expect(technicalDetail.contains("sizeBodySM"))
        #expect(technicalDetail.contains("sizeBody3"))
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
        let transcriptEvents = try String(
            contentsOf: packageRoot.appending(path: "Sources/UI/Chat/ChatTranscriptEventViews.swift"),
            encoding: .utf8
        )
        let compactPill = try String(
            contentsOf: packageRoot.appending(path: "Sources/UI/Chat/ChatCompactPill.swift"),
            encoding: .utf8
        )
        let transcriptPresentation = try String(
            contentsOf: packageRoot.appending(path: "Sources/UI/Chat/ChatTranscriptPresentation.swift"),
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
        #expect(catchUpButton.contains("width: ComposerControlMetrics.hitTarget"))
        #expect(catchUpButton.contains("height: ComposerControlMetrics.hitTarget"))
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
        #expect(chat.contains("physicalOpeningTailID(for: installed)"))
        #expect(chat.contains("scrollCoordinator.positionOpeningTail("))
        #expect(chat.contains("targetRenderedID: targetRenderedID"))
        #expect(scrollCoordinator.contains("openingTailTargetRenderedID"))
        #expect(scrollCoordinator.contains("semanticFrames[targetRenderedID]"))
        #expect(scrollCoordinator.contains("openingTailPresentation == presentation"))
        #expect(chat.contains("ChatTranscriptPresentationStore"))
        #expect(!chat.contains("ChatTranscriptPresentation.timeline("))
        #expect(transcriptEvents.contains("struct ChatTranscriptPillModifier: ViewModifier"))
        #expect(transcriptEvents.contains("TronTypography.sizeBodySM"))
        #expect(compactPill.contains("static let verticalPadding: CGFloat = 6"))
        #expect(compactPill.contains("static let errorCornerRadius: CGFloat = 18"))
        #expect(compactPill.contains("tone == .error ? errorCornerRadius : capsuleCornerRadius"))
        #expect(compactPill.occurrences(of: ".padding(.vertical, ChatCompactPillLayoutPolicy.verticalPadding)") == 2)
        #expect(transcriptEvents.contains(".fixedSize(horizontal: false, vertical: true)"))
        #expect(transcriptEvents.contains(".frame(minWidth: 44, minHeight: 44)"))
        #expect(transcriptEvents.contains(".contentShape(Rectangle())"))
        #expect(!transcriptEvents.contains(".fixedSize()"))
        #expect(transcriptPresentation.contains("item.tokensBefore.map(ChatTokenCountPresentation.beforeCompaction)"))
        #expect(compactPill.contains("struct ChatCompactPillSurface"))
        #expect(compactPill.contains("case .glass:"))
        #expect(compactPill.contains("case .flat:"))
        #expect(compactPill.contains(".background(tone.surfaceColor.opacity(0.10), in: shape)"))
        #expect(compactPill.contains("Color(lightHex: \"#0369A1\", darkHex: \"#38BDF8\")"))
        #expect(compactPill.contains("Color(lightHex: \"#92400E\", darkHex: \"#FBBF24\")"))
        #expect(compactPill.contains("Color(lightHex: \"#475569\", darkHex: \"#CBD5E1\")"))
        #expect(compactPill.contains("tone.secondaryColor"))
        #expect(!compactPill.contains("tone.color.opacity"))
        #expect(!transcriptEvents.contains("tone.color.opacity"))
        #expect(compactPill.contains("paragraph.baseWritingDirection = .natural"))
        #expect(compactPill.contains("func sizeThatFits("))
        let userPrompt = (transcript.components(separatedBy: "UserPromptText(text:").dropFirst().first ?? "")
            .components(separatedBy: "} else {").first ?? ""
        #expect(!userPrompt.contains(".padding(.leading"))
        #expect(!userPrompt.contains(".frame(maxWidth: .infinity"))
        #expect(transcript.contains("UserPromptTextLayoutPolicy.maximumWidth"))
        #expect(userPrompt.contains(".modifier(UserPromptGlassModifier())"))
        let messageBody = (transcript.components(separatedBy: "@ViewBuilder private var message").dropFirst().first ?? "")
            .components(separatedBy: "private var displayedMessageParts").first ?? ""
        let attachmentPosition = try #require(messageBody.firstRange(of: "attachmentStrip")?.lowerBound)
        let promptPosition = try #require(messageBody.firstRange(of: "UserPromptText(text:")?.lowerBound)
        #expect(attachmentPosition < promptPosition)
        #expect(transcript.contains("ViewThatFits(in: .horizontal)"))
        #expect(transcript.contains(".fixedSize(horizontal: true, vertical: false)"))
        #expect(transcript.contains("ChatPromptContainerStyle.userPromptBottomPadding"))
        #expect(transcript.contains("Color.tronEmerald.opacity(ChatPromptContainerStyle.tintOpacity)"))
        #expect(compactPill.contains("static let fontScale: CGFloat = 1"))
        #expect(!compactPill.contains(".justified"))
        #expect(!userPrompt.contains("minHeight: 44"))
        #expect(transcript.components(separatedBy: ".chatTranscriptPill()").count - 1 == 0)
        let earlierMessagesChip = (chat.components(separatedBy: "private func earlierMessagesChip").dropFirst().first ?? "")
            .components(separatedBy: "private var composer").first ?? ""
        #expect(!earlierMessagesChip.contains("TronActionButtonStyle(expands: false)"))
        #expect(earlierMessagesChip.contains("scrollCoordinator.isPrependingHistory"))
        #expect(earlierMessagesChip.contains(".disabled(isLoadingEarlierMessages)"))
        #expect(chat.contains("layoutEpoch: scrollCoordinator.layoutEpoch"))
    }

    @Test("send-to-chat motion stays role-aware, authoritative, and accessible")
    func sendToChatMotion() throws {
        let chat = try String(
            contentsOf: packageRoot.appending(path: "Sources/UI/Chat/ChatView.swift"),
            encoding: .utf8
        )
        let entranceRows = try String(
            contentsOf: packageRoot.appending(path: "Sources/UI/Chat/ChatEntranceRows.swift"),
            encoding: .utf8
        )
        let motion = try String(
            contentsOf: packageRoot.appending(path: "Sources/UI/Chat/ChatContentTransition.swift"),
            encoding: .utf8
        )
        let composer = try String(
            contentsOf: packageRoot.appending(path: "Sources/UI/Chat/ComposerControls.swift"),
            encoding: .utf8
        )
        #expect(chat.contains("kind: .classify(item)"))
        #expect(chat.contains("ChatQueuedMessageEntranceRow"))
        #expect(!chat.contains("struct ChatTranscriptEntranceRow"))
        #expect(entranceRows.contains("struct ChatTranscriptEntranceRow"))
        #expect(entranceRows.contains("struct ChatTranscriptRenderRow"))
        // One production structural measurement plus the HOSTED_TEST driver seam.
        #expect(chat.occurrences(of: "composerViewportTransitionBegan()") == 2)
        #expect(chat.contains("ChatComposerLayoutSignalPolicy.shouldSignal"))
        #expect(!chat.contains(".onChange(of: composerTextHeight)"))
        #expect(!chat.contains(".onChange(of: pendingAttachments.map"))
        #expect(motion.contains("case userPrompt"))
        #expect(motion.contains("case queuedPrompt"))
        #expect(motion.contains("guard !reduceMotion else { return .identity }"))
        #expect(composer.contains("ComposerTrailingButtonPressStyle"))
        #expect(composer.contains("isSending ? \"Sending message\" : \"Send message\""))
        #expect(!motion.contains("Task.sleep"))
        #expect(!motion.contains("DispatchQueue"))
    }

    @Test("queued messages remain visible and individually manageable in chat")
    func queuedMessagePresentation() throws {
        let chat = try String(
            contentsOf: packageRoot.appending(path: "Sources/UI/Chat/ChatView.swift"),
            encoding: .utf8
        )
        let queue = try String(
            contentsOf: packageRoot.appending(path: "Sources/UI/Chat/QueuedMessagePresentation.swift"),
            encoding: .utf8
        )
        let composer = try String(
            contentsOf: packageRoot.appending(path: "Sources/UI/Chat/ComposerControls.swift"),
            encoding: .utf8
        )
        #expect(chat.contains("queuedMessageRows(installed)"))
        #expect(chat.contains("let messages = installed.queuedMessages"))
        #expect(chat.contains("QueuedMessageManagementPolicy.availability("))
        #expect(chat.contains("model.replaceQueue("))
        #expect(queue.contains("struct QueuedMessageRow"))
        #expect(queue.contains("struct QueuedMessageEditorSheet"))
        #expect(queue.contains("ViewThatFits(in: .horizontal)"))
        #expect(queue.contains("card.fixedSize(horizontal: true, vertical: false)"))
        #expect(queue.contains(".frame(maxWidth: UserPromptTextLayoutPolicy.maximumWidth, alignment: .trailing)"))
        #expect(queue.contains("Button(action: onEdit)"))
        #expect(queue.contains(".glassEffect("))
        #expect(queue.contains(".interactive()"))
        #expect(queue.contains(".contentShape(shape)"))
        #expect(queue.contains(".padding(.top, ChatPromptContainerStyle.topPadding)"))
        #expect(!queue.contains("queueActionButton"))
        #expect(!queue.contains("label: \"Edit queued message\""))
        #expect(!queue.contains("label: \"Remove from queue\""))
        #expect(queue.contains("Update Tron on Mac to edit or remove queued messages"))
        #expect(queue.contains("Move earlier"))
        #expect(queue.contains("Move later"))
        #expect(queue.contains("ToolbarItem(placement: .topBarLeading)"))
        #expect(queue.contains(".accessibilityLabel(\"Remove queued message\")"))
        #expect(!queue.contains("Remove from Queue"))
        #expect(queue.contains("Clear entire queue"))
        #expect(queue.contains("Attachments stay with this queued message."))
        #expect(composer.contains("Steer after current turn"))
        #expect(composer.contains("Follow up after current work"))
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
        let transcriptEvents = try String(
            contentsOf: packageRoot.appending(path: "Sources/UI/Chat/ChatTranscriptEventViews.swift"),
            encoding: .utf8
        )
        let toolRuns = try String(
            contentsOf: packageRoot.appending(path: "Sources/UI/Chat/ChatToolRunViews.swift"),
            encoding: .utf8
        )
        let chat = try String(
            contentsOf: packageRoot.appending(path: "Sources/UI/Chat/ChatView.swift"),
            encoding: .utf8
        )
        let composerControls = try String(
            contentsOf: packageRoot.appending(path: "Sources/UI/Chat/ComposerControls.swift"),
            encoding: .utf8
        )
        let entranceRows = try String(
            contentsOf: packageRoot.appending(path: "Sources/UI/Chat/ChatEntranceRows.swift"),
            encoding: .utf8
        )
        let scrollCoordinator = try String(
            contentsOf: packageRoot.appending(path: "Sources/UI/Chat/ChatScrollCoordinator.swift"),
            encoding: .utf8
        )
        let compactPill = try String(
            contentsOf: packageRoot.appending(path: "Sources/UI/Chat/ChatCompactPill.swift"),
            encoding: .utf8
        )
        let projectionKernel = try String(
            contentsOf: packageRoot.appending(path: "Sources/UI/Chat/ChatTranscriptProjectionKernel.swift"),
            encoding: .utf8
        )
        let notification = (transcriptEvents.components(separatedBy: "struct ChatNotificationView").dropFirst().first ?? "")
            .components(separatedBy: "struct TranscriptNotice").first ?? ""
        let toolCard = (toolRuns.components(separatedBy: "struct ToolCard").dropFirst().first ?? "")
            .components(separatedBy: "struct ToolRunView").first ?? ""
        let toolCardLabel = (toolCard.components(separatedBy: "var body: some View").dropFirst().first ?? "")
            .components(separatedBy: ".buttonStyle(.plain)").first ?? ""
        let toolRunChip = (toolRuns.components(separatedBy: "private struct ToolRunChip").dropFirst().first ?? "")
            .components(separatedBy: "private struct ToolElapsedText").first ?? ""
        let toolRunLabel = (toolRunChip.components(separatedBy: "var body: some View").dropFirst().first ?? "")
            .components(separatedBy: ".buttonStyle(.plain)").first ?? ""
        let toolElapsed = (toolRuns.components(separatedBy: "private struct ToolElapsedText").dropFirst().first ?? "")
            .components(separatedBy: "private struct ToolRunElapsedText").first ?? ""
        let toolRunElapsed = (toolRuns.components(separatedBy: "private struct ToolRunElapsedText").dropFirst().first ?? "")
            .components(separatedBy: "struct ToolDetailRoute").first ?? ""
        #expect(transcriptEvents.contains("struct TranscriptNotice: View"))
        #expect(transcriptEvents.contains("struct ChatNotificationView: View"))
        #expect(toolRuns.contains("struct ToolRunView: View"))
        #expect((transcriptEvents + toolRuns).components(separatedBy: "ChatCompactPillSurface(tone: tone, material: .glass").count - 1 >= 2)
        #expect(notification.contains("pill.frame(minWidth: 44, minHeight: 44)"))
        #expect(notification.contains(".frame(maxWidth: .infinity, minHeight: 44, alignment: .center)"))
        #expect(chat.contains("LazyVStack(alignment: .leading, spacing: 8)"))
        for label in [toolCardLabel, toolRunLabel] {
            #expect(label.contains("ChatCompactPillSurface"))
            #expect(!label.contains("minHeight"))
            #expect(!label.contains("Spacer("))
            #expect(!label.contains("maxWidth"))
        }
        #expect(!(transcriptEvents + toolRuns).contains("value: visualState"))
        #expect(!notification.contains(".contentTransition(.opacity)"))
        #expect(!toolRuns.contains(".contentTransition(.opacity)"))
        #expect(chat.contains(".chatStableTranscriptUpdates()"))
        #expect(!toolRuns.contains("value: detailTool"))
        #expect(!toolRuns.contains("value: presentation)"))
        #expect(!toolRuns.contains("value: run)"))
        #expect(compactPill.contains("struct ChatCompactPillVisualState: Hashable"))
        #expect(compactPill.contains("static let verticalPadding: CGFloat = 6"))
        #expect(compactPill.contains("static let itemSpacing: CGFloat = 7"))
        #expect(compactPill.contains("static let toolIconSize: CGFloat = 11"))
        #expect(compactPill.contains("HStack(spacing: ChatCompactPillLayoutPolicy.itemSpacing)"))
        #expect(toolRuns.occurrences(of: "iconSize: ChatCompactPillLayoutPolicy.toolIconSize") == 2)
        #expect(compactPill.contains("ProgressView().controlSize(.small)"))
        #expect(composerControls.contains("static let hitTarget: CGFloat = 40"))
        #expect(composerControls.contains("static let symbolSize: CGFloat = 16"))
        #expect(composerControls.contains("static let contextRingDiameter: CGFloat = 16"))
        #expect(composerControls.occurrences(of: "width: ComposerControlMetrics.hitTarget") == 2)
        #expect(composerControls.occurrences(of: "height: ComposerControlMetrics.hitTarget") == 2)
        #expect(composerControls.occurrences(of: "size: ComposerControlMetrics.symbolSize") == 2)
        #expect(transcript.contains(".font(TronFont.body(12))"))
        #expect(transcript.contains(".foregroundStyle(Color.tronTextSecondary)"))
        #expect(transcript.contains(".italic()"))
        #expect(toolRuns.contains("run.reverseChronologicalTools.map(\\.id)"))
        #expect(toolElapsed.contains("TimelineView(.animation(minimumInterval: 0.1))"))
        #expect(toolRunElapsed.contains("TimelineView(.animation(minimumInterval: 0.1))"))
        #expect(!toolRuns.contains(".periodic(from:"))
        for elapsed in [toolElapsed, toolRunElapsed] {
            #expect(elapsed.contains(".monospacedDigit()"))
            #expect(elapsed.contains(".lineLimit(1)"))
            #expect(elapsed.contains(".fixedSize(horizontal: true, vertical: false)"))
            #expect(!elapsed.contains("minWidth: 48"))
            #expect(!elapsed.contains("Spacer("))
        }
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
        #expect(attachmentButton.contains("size: ComposerControlMetrics.symbolSize"))
        #expect(attachmentButton.occurrences(of: "ComposerControlMetrics.hitTarget") == 4)
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
        #expect(stableRow.contains("entranceState == .pending ? installedTag : nil"))
        #expect(stableRow.contains("ChatEntranceGeometryAdmissionPolicy.admits"))
        #expect(stableRow.contains("installationTag: entranceTag"))
        #expect(!stableRow.contains("transcriptProjectionSource"))
        #expect(chat.contains("scrollCoordinator.installedTranscriptChanged(installed)"))
        #expect(!chat.contains("discreteContentSuperseded"))
        #expect(scrollCoordinator.contains("discreteFollowRenderedIDs"))
        #expect(scrollCoordinator.contains("installed.containsDisplayedID"))
        #expect(!projectionKernel.contains("specialBeforeStreaming"))
        #expect(!projectionKernel.contains("unanchoredBeforeStreaming"))
        #expect(projectionKernel.contains("appendFragment(streamingFragment, tools: streamingTools, streaming: true)"))
        #expect(projectionKernel.contains("appendTools(unanchoredLive)"))
        #expect(chat.contains("scrollCoordinator.geometryChanged"))
        #expect(chat.contains("ChatScrollGeometryObservation"))
        #expect(chat.contains("presentationEpoch: openPresentation.epoch"))
        #expect(chat.contains("phase: openPresentation.phase"))
        #expect(chat.contains("observation.presentationEpoch == openPresentation.epoch"))
        #expect(chat.contains("observation.phase == openPresentation.phase"))
        #expect(chat.contains("geometry.hasViewportChange(from: previousGeometry)"))
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
        let composerOwner = (chat.components(separatedBy: "private var composer: some View").dropFirst().first ?? "")
            .components(separatedBy: "private var composerInputBar").first ?? ""
        #expect(!composerStage.contains("ChatBottomActivityBlur"))
        #expect(composerOwner.contains(".background(alignment: .bottom)"))
        #expect(!composerOwner.contains(".overlay(alignment: .bottom)"))
        #expect(composerOwner.contains("ChatBottomActivityBlur("))
        #expect(composerOwner.contains("isActive: showsAmbientWorkingBlur"))
        #expect(composerOwner.contains(".offset(y: ChatBottomActivityBlurLayout.translation("))
        #expect(composerOwner.contains("keyboardVisible: composerFocused"))
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
        #expect(entranceRows.contains("case .notification(let notification)"))
        #expect(entranceRows.contains("ChatNotificationView(presentation: notification)"))
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
                || (source.contains("Text(\"Reload\")") && source.contains("Button(action: reload)"))
            #expect(hasReloadAction, "\(path) is missing an explicit reload action")
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
