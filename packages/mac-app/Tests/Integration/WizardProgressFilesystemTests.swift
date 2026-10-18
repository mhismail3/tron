import Foundation
import Testing
@testable import TronMac

@Suite("Wizard progress publication", .serialized)
@MainActor
struct WizardProgressFilesystemTests {
    private func records() async throws -> [TronLog.Record] {
        // The scheme isolates the production singleton before the host starts.
        try #require(TronPaths.tronHome.path.contains("TronMacIntegrationTests-home"))
        await TronLog.shared.flush()
        let path = TronPaths.tronHome.appendingPathComponent("logs/mac.jsonl")
        guard FileManager.default.fileExists(atPath: path.path) else { return [] }
        return try String(contentsOf: path, encoding: .utf8).split(separator: "\n").map {
            try JSONDecoder().decode(TronLog.Record.self, from: Data($0.utf8))
        }
    }

    @Test func failedNavigationRetainsBytesAndRecoversWithoutBlockingTheStep() async throws {
        let root = TestTempDir.make()
        defer { TestTempDir.cleanup(root) }
        let parent = root.appendingPathComponent("progress")
        let saved = root.appendingPathComponent("saved-progress")
        let path = parent.appendingPathComponent("wizard-state.json")
        let offset = try await records().count
        let state = WizardState(stateURL: path, initialStep: .tailscale)
        let prior = try Data(contentsOf: path)

        // Move the original private tree intact, then make its publication
        // parent a file. AtomicFileWriter cannot chmod this obstruction away.
        try FileManager.default.moveItem(at: parent, to: saved)
        try Data("obstruction".utf8).write(to: parent)
        state.advance()
        #expect(state.step == .install)
        #expect(try Data(contentsOf: saved.appendingPathComponent("wizard-state.json")) == prior)
        let failed = try await records().dropFirst(offset)
        #expect(failed.contains { $0.event == "wizard.step" && $0.new == "install" && $0.outcome == "success" })
        #expect(failed.contains { $0.event == "wizard.progress-write" && $0.level == "error" && $0.new == "install" && $0.outcome == "failure" && $0.why?.isEmpty == false })

        try FileManager.default.removeItem(at: parent)
        try FileManager.default.moveItem(at: saved, to: parent)
        #expect(try Data(contentsOf: path) == prior)
        #expect(WizardState(stateURL: path).step == .tailscale)
        state.advance()
        #expect(state.step == .permissions)
        let published = try JSONSerialization.jsonObject(with: Data(contentsOf: path)) as? [String: Any]
        #expect(published?["step"] as? String == "permissions")
        // Unsafe cold-start steps still clamp and publish Welcome, not Done.
        #expect(WizardState(stateURL: path).step == .welcome)
        let recovered = try await records().dropFirst(offset)
        #expect(recovered.contains { $0.event == "wizard.progress-write" && $0.new == "permissions" && $0.outcome == "success" })
        let attrs = try FileManager.default.attributesOfItem(atPath: path.path)
        #expect((attrs[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        #expect(try FileManager.default.contentsOfDirectory(atPath: parent.path) == ["wizard-state.json"])
    }

    @Test func initializerFailureIsReportedAndNewerRecordsRemainOwnedByTheirWriter() async throws {
        let root = TestTempDir.make()
        defer { TestTempDir.cleanup(root) }
        let parent = root.appendingPathComponent("progress")
        let path = parent.appendingPathComponent("wizard-state.json")
        try Data("obstruction".utf8).write(to: parent)
        let offset = try await records().count
        let state = WizardState(stateURL: path, initialStep: .install)
        #expect(state.step == .install)
        let failed = try await records().dropFirst(offset)
        #expect(failed.contains { $0.event == "wizard.progress-write" && $0.level == "error" && $0.new == "install" && $0.outcome == "failure" })
        try FileManager.default.removeItem(at: parent)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let future = Data(#"{"version":999,"step":"done","future":"retain"}"#.utf8)
        try future.write(to: path)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path)
        let beforeUnknown = try await records().count
        #expect(WizardState(stateURL: path).step == .welcome)
        #expect(try Data(contentsOf: path) == future)
        #expect(try await records().count == beforeUnknown)
        // Only an explicit override may replace an unknown owner's record.
        #expect(WizardState(stateURL: path, initialStep: .iosBeta).step == .iosBeta)
        #expect(try Data(contentsOf: path) != future)
        #expect(WizardState(stateURL: path).step == .iosBeta)
    }
}
