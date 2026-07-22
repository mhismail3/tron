import Foundation
import Testing
@testable import TronMobile

struct WorkerConsoleInteractionTests {
    @Test("Unbounded worker detail uses sheets instead of inline disclosure")
    func unboundedWorkerDetailUsesSheets() throws {
        let root = iosAppRoot()
        let workerRoot = root.appendingPathComponent("Sources/UI/WorkerConsole")
        let files = try FileManager.default.contentsOfDirectory(
            at: workerRoot,
            includingPropertiesForKeys: nil
        ).filter { $0.pathExtension == "swift" }

        for file in files {
            let source = try String(contentsOf: file, encoding: .utf8)
            #expect(
                !source.contains("DisclosureGroup"),
                "\(file.lastPathComponent) must route unbounded detail to a sheet"
            )
        }

        let detail = try String(
            contentsOf: workerRoot.appendingPathComponent("WorkerDetailSheet.swift"),
            encoding: .utf8
        )
        let components = try String(
            contentsOf: workerRoot.appendingPathComponent("WorkerConsoleComponents.swift"),
            encoding: .utf8
        )
        #expect(detail.contains("WorkerJSONDetailSheet(title: \"Input Schema\""))
        #expect(components.contains("WorkerRunDetailSheet("))
        #expect(components.contains("WorkerJSONDetailSheet("))
    }

    @Test("Worker tabs and execution actions share liquid glass components")
    func workerControlsUseSharedLiquidGlass() throws {
        let root = iosAppRoot()
        let tabs = try String(
            contentsOf: root.appendingPathComponent("Sources/UI/Components/TronSegmentedControl.swift"),
            encoding: .utf8
        )
        let action = try String(
            contentsOf: root.appendingPathComponent("Sources/UI/Components/TronPrimaryActionButton.swift"),
            encoding: .utf8
        )
        let workerDetail = try String(
            contentsOf: root.appendingPathComponent("Sources/UI/WorkerConsole/WorkerDetailSheet.swift"),
            encoding: .utf8
        )
        let delegation = try String(
            contentsOf: root.appendingPathComponent("Sources/UI/WorkerConsole/DelegationSheet.swift"),
            encoding: .utf8
        )

        #expect(tabs.contains("GlassEffectContainer"))
        #expect(tabs.contains(".glassEffect("))
        #expect(action.contains(".glassEffect("))
        #expect(workerDetail.contains("TronPrimaryActionButton("))
        #expect(delegation.contains("TronPrimaryActionButton("))
        #expect(!workerDetail.contains(".background(Color.tronEmerald"))
        #expect(!delegation.contains(".background(Color.tronPurple"))
    }

    @Test("Worker sessions stay read only and inside dashboard sheets")
    func workerSessionsUseReadOnlySheets() throws {
        let root = iosAppRoot()
        let details = try String(
            contentsOf: root.appendingPathComponent("Sources/UI/WorkerConsole/WorkerConsoleDetailSheets.swift"),
            encoding: .utf8
        )
        let chat = try String(
            contentsOf: root.appendingPathComponent("Sources/UI/Chat/Shell/ChatView.swift"),
            encoding: .utf8
        )
        let sidebar = try String(
            contentsOf: root.appendingPathComponent("Sources/UI/Chat/Shell/SessionSidebar.swift"),
            encoding: .utf8
        )
        let content = try String(
            contentsOf: root.appendingPathComponent("Sources/UI/Chat/Shell/ContentView.swift"),
            encoding: .utf8
        )

        #expect(details.contains("WorkerAuditSessionSheet"))
        #expect(details.contains("presentationMode: .workerAudit"))
        #expect(chat.contains("reconstructReadOnlyTranscript"))
        #expect(chat.contains("if presentationMode == .interactiveSession"))
        #expect(!sidebar.contains("openWorkerAuditSession"))
        #expect(!content.contains("openWorkerAuditSession"))
    }

    private func iosAppRoot(filePath: String = #filePath) -> URL {
        URL(fileURLWithPath: filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}
