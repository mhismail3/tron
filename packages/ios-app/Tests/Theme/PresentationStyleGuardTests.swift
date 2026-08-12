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
