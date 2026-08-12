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
            "AgentExtensionSettings.swift", "RuntimeSettingsViews.swift", "SettingsView.swift",
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
        #expect(providers.contains("Button(\"Log Out\", systemImage: \"rectangle.portrait.and.arrow.right\", role: .destructive)"))
        #expect(providers.contains("Image(systemName: \"ellipsis.circle\")"))
    }

    @Test("tool details are tappable and start at the sheet top")
    func toolDetailPresentation() throws {
        let transcript = try String(
            contentsOf: packageRoot.appending(path: "Sources/UI/Chat/TranscriptRow.swift"),
            encoding: .utf8
        )
        #expect(transcript.contains(".sheet(item: $detailPresentation)"))
        #expect(transcript.contains(".defaultScrollAnchor(.top)"))
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
        #expect(transcript.contains("TronFont.body(12)).foregroundStyle(Color.tronTextSecondary).italic()"))
        #expect(chat.contains("ChatTranscriptPresentation.renderItems(in: snapshot)"))
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
