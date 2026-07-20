import Foundation
import Testing

@Suite("Worker Console Visual Contract Tests")
struct WorkerConsoleVisualContractTests {
    @Test("Worker Console keeps the shared cockpit visual language")
    func sharedCockpitVisualLanguage() throws {
        let source = try workerConsoleSource()

        #expect(source.contains("SheetTitle(title: \"Worker Console\""))
        #expect(source.contains("SheetPrimaryActionButton("))
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

    private func workerConsoleSource() throws -> String {
        let testDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let sourceURL = testDirectory
            .appendingPathComponent("../../../Sources/UI/WorkerConsole/WorkerConsoleViews.swift")
            .standardizedFileURL
        return try String(contentsOf: sourceURL, encoding: .utf8)
    }
}
