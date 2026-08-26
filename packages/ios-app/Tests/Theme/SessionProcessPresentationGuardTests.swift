import Foundation
import Testing
@testable import TronMobile

@Suite("Session process presentation policy")
struct SessionProcessPresentationGuardTests {
    private var packageRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    @Test("subagent surfaces use one Tron route with no command or ambient extension presentation")
    func processSurfaces() throws {
        let sheets = try source("Sources/UI/Chat/SessionProcessSheets.swift")
        let composer = try source("Sources/UI/Chat/ChatComposerView.swift")
        let routes = try source("Sources/UI/Chat/ChatRoutes.swift")
        let chat = try source("Sources/UI/Chat/ChatView.swift")

        #expect(sheets.contains(".tronNavigationTitle(\"Subagents\")"))
        #expect(sheets.contains(".tronNavigationTitle(\"Subagent History\")"))
        #expect(!sheets.contains("process.kind == .command"))
        #expect(!sheets.contains("Assistant commands"))
        #expect(composer.contains("$0.kind == .subagent"))
        #expect(sheets.components(separatedBy: ".tronTopBlur(.sheet)").count - 1 == 2)
        #expect(sheets.components(separatedBy: ".tronPresentation()").count - 1 == 2)
        #expect(sheets.contains(".accessibilityAddTraits(.isHeader)"))
        #expect(sheets.contains(".accessibilityValue(accessibilityValue)"))
        #expect(sheets.contains("private struct SessionProcessPlaceholder: View"))
        #expect(sheets.contains("TronGlassCard(accent: .tronSlate)"))
        #expect(sheets.contains(".font(TronTypography.bodySM)"))
        #expect(!sheets.contains("ContentUnavailableView"))
        #expect(sheets.contains("ScrollPosition(idType: String.self)"))
        #expect(!sheets.contains("Image(systemName: \"chevron.right\")"))
        #expect(!sheets.contains(".navigationTitle("))
        #expect(composer.contains("SessionProcessButton("))
        #expect(!composer.contains("ExtensionActivityPill("))
        #expect(routes.contains("SessionProcessesSheet(sessionID: sessionID)"))
        #expect(!chat.contains("ChatExtensionWidgetPolicy.liveGroups"))
    }

    @Test("orb pauses for reduced motion visibility and scene lifecycle")
    func orbLifecycle() throws {
        let orb = try source("Sources/UI/Components/ProcessActivityOrb.swift")
        #expect(orb.contains("var isVisible = true"))
        #expect(orb.contains("reduceMotion || !isVisible || !sceneActive"))
        #expect(orb.contains("ProcessActivityOrbEngine.reducedMotionTime"))
        #expect(orb.contains("Canvas(rendersAsynchronously: true)"))
        #expect(orb.contains("Color.tronEmerald.opacity(opacity)"))
    }

    private func source(_ relativePath: String) throws -> String {
        try String(contentsOf: packageRoot.appending(path: relativePath), encoding: .utf8)
    }
}
