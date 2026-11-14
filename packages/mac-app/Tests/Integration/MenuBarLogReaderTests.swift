import Foundation
import Testing
@testable import TronMac

@Suite("MenuBarLogReader — owned Gateway log file boundary")
struct MenuBarLogReaderTests {
    @Test("returns the newest records in order across rotated segments")
    func newestRecordsAcrossSegments() async throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let logs = home.appendingPathComponent("logs", isDirectory: true)
        try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        try (line("two") + line("first")).write(to: logs.appendingPathComponent("gateway.jsonl.1"), atomically: true, encoding: .utf8)
        try (line("three") + "not json\n").write(to: logs.appendingPathComponent("gateway.jsonl"), atomically: true, encoding: .utf8)

        let result = await MenuBarLogReader.fetchRecentLogs(tronHome: home, limit: 2)

        #expect(result == .success("[t] INFO TRON: first\n[t] INFO TRON: three"))
    }

    @Test("a fresh home with no Gateway log yet reads as empty, not a failure")
    func missingLogIsEmpty() async throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }

        #expect(await MenuBarLogReader.fetchRecentLogs(tronHome: home) == .success(""))
    }

    private func line(_ message: String) -> String {
        #"{"timestamp":"t","level":"info","message":"\#(message)"}"# + "\n"
    }

    private func makeHome() throws -> URL {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("tron-menubar-logs-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        return home
    }
}
