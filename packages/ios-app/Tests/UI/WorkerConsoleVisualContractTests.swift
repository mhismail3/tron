import Foundation
import Testing

@Suite("Engine Dashboard Visual Contract Tests")
struct WorkerConsoleVisualContractTests {
    @Test("Engine Dashboard keeps the shared cockpit visual language")
    func sharedCockpitVisualLanguage() throws {
        let source = try dashboardSource()

        #expect(source.contains("SheetTitle(title: \"Engine\""))
        #expect(source.contains("SheetPrimaryActionButton("))
        #expect(source.contains("TronSegmentedControl("))
        #expect(source.contains("case overview = \"Overview\""))
        #expect(source.contains("case core = \"Core\""))
        #expect(source.contains("case workers = \"Workers\""))
        #expect(source.contains("case activity = \"Activity\""))
        #expect(source.contains("EngineComponentCard("))
        #expect(source.contains("EngineSurfaceCard("))
        #expect(source.contains("EngineCoreToolCard("))
        #expect(source.components(separatedBy: "TronTypography").count > 100)
        #expect(source.components(separatedBy: "sectionFill").count > 12)
        #expect(source.contains("WorkerConsoleEmptyState("))
        #expect(source.contains("WorkerConsoleLoadingState("))
        #expect(source.contains("confirmationDialog("))

        #expect(!source.contains(".navigationTitle("))
        #expect(!source.contains(".font(.headline)"))
        #expect(!source.contains(".font(.subheadline)"))
        #expect(!source.contains(".foregroundStyle(.secondary)"))
        #expect(!source.contains("List {"))
    }

    private func dashboardSource() throws -> String {
        let testDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let sourceDirectory = testDirectory
            .appendingPathComponent("../../Sources/UI/WorkerConsole")
            .standardizedFileURL
        return try [
            "WorkerConsoleViews.swift",
            "WorkerDetailSheet.swift",
            "WorkerConsoleComponents.swift",
            "EngineDashboardViews.swift",
        ]
            .map { sourceDirectory.appendingPathComponent($0) }
            .map { try String(contentsOf: $0, encoding: .utf8) }
            .joined(separator: "\n")
    }
}
