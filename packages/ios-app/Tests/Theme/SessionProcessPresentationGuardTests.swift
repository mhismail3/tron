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
        #expect(sheets.components(separatedBy: ".tronTopBlur(.sheet)").count - 1 == 3)
        #expect(sheets.components(separatedBy: ".tronPresentation()").count - 1 == 3)
        #expect(sheets.components(separatedBy: "@State private var detent: PresentationDetent = .medium").count - 1 == 1)
        #expect(sheets.components(separatedBy: "@State private var detent: PresentationDetent = .large").count - 1 == 2)
        #expect(sheets.components(separatedBy: ".presentationDetents([.medium, .large], selection: $detent)").count - 1 == 3)
        #expect(sheets.components(separatedBy: ".sheet(item: $selectedProcess)").count - 1 == 2)
        #expect(sheets.contains("Button(action: openTranscript)"))
        #expect(!sheets.contains("NavigationLink"))
        #expect(!sheets.contains(".navigationDestination"))
        #expect(!sheets.contains("SessionProcessDestination"))
        #expect(sheets.contains(".accessibilityAddTraits(.isHeader)"))
        #expect(sheets.contains(".accessibilityValue(accessibilityValue)"))
        #expect(sheets.contains("private struct SessionProcessPlaceholder: View"))
        #expect(sheets.contains("TronGlassCard(accent: .tronSlate)"))
        #expect(sheets.contains("SessionProcessRow(process: process, accent: accent, surfaceStyle: .glass)"))
        #expect(sheets.contains("SessionProcessRow(process: process, accent: accent, surfaceStyle: .scrollOptimized)"))
        #expect(sheets.contains("TronGlassCard(accent: cardAccent, cornerRadius: 14"))
        #expect(sheets.contains(".tronScrollSurface(accent: cardAccent, cornerRadius: 12"))
        #expect(sheets.contains("size: 30"))
        #expect(sheets.contains("durationSpeedScale(durationMs: process.durationMs)"))
        #expect(sheets.contains("process.lifecycle.state.isActive ? .solving : .thinking"))
        #expect(sheets.contains("private var executionModePill: some View"))
        #expect(sheets.contains("Text(ToolTiming.format(milliseconds: durationMs))"))
        #expect(!sheets.contains("Canonical transcript ready"))
        #expect(sheets.contains("LIVE OUTPUT"))
        #expect(sheets.contains("process.lifecycle.state == .completed ? \"Completed\" : process.lifecycle.state.displayName"))
        #expect(sheets.contains(".font(TronTypography.bodySM)"))
        #expect(!sheets.contains("ContentUnavailableView"))
        #expect(sheets.contains("ScrollPosition(idType: String.self)"))
        #expect(!sheets.contains("Image(systemName: \"chevron.right\")"))
        #expect(!sheets.contains(".navigationTitle("))
        #expect(composer.contains("SessionProcessButton("))
        let processButton = try source("Sources/UI/Chat/SessionProcessButton.swift")
        #expect(processButton.contains("value: isVisible"))
        #expect(processButton.contains(".spring(response: 0.32, dampingFraction: 0.82)"))
        #expect(!composer.contains("ExtensionActivityPill("))
        #expect(routes.contains("SessionProcessesSheet(sessionID: sessionID)"))
        #expect(!chat.contains("ChatExtensionWidgetPolicy.liveGroups"))
    }

    @Test("child transcript keeps tail intent while aligning short content to the top")
    func childTranscriptScrollPolicy() throws {
        let sheets = try source("Sources/UI/Chat/SessionProcessSheets.swift")
        let child = try #require(
            sheets.components(separatedBy: "struct ReadOnlySubagentSessionSheet: View").dropFirst().first
        )
        #expect(child.contains(".defaultScrollAnchor(.bottom, for: .initialOffset)"))
        #expect(child.contains(".defaultScrollAnchor(.top, for: .alignment)"))
        #expect(child.contains(".defaultScrollAnchor(.top, for: .sizeChanges)"))
        #expect(child.contains("title: isActive ? \"Transcript starting\" : \"No transcript recorded\""))
        #expect(!child.contains("ScrollViewReader"))
        #expect(!child.contains(".onAppear"))
    }

    @Test("read-only transcript conflicts reopen the canonical tail")
    func childTranscriptConflictRecovery() throws {
        let store = try source("Sources/State/ReadOnlySubagentSessionStore.swift")
        #expect(store.contains("private func reopenCanonicalTail(ownedGeneration: Int)"))
        #expect(store.components(separatedBy: "self.reopenCanonicalTail(ownedGeneration: ownedGeneration)").count - 1 == 3)
        #expect(store.contains("open(\n            parentSessionID: parentSessionID,"))
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
