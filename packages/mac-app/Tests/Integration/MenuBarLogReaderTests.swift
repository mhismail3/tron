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

    @Test("reads a bounded tail of a segment far larger than the window, newest last")
    func boundedTailOfLargeSegment() async throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let logs = home.appendingPathComponent("logs", isDirectory: true)
        try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        var text = ""
        for index in 0..<8_000 { text += line("filler-\(index)") }
        text += line("newest-a") + line("newest-b")
        try text.write(to: logs.appendingPathComponent("gateway.jsonl"), atomically: true, encoding: .utf8)

        let result = await MenuBarLogReader.fetchRecentLogs(tronHome: home, limit: 2)

        #expect(result == .success("[t] INFO TRON: newest-a\n[t] INFO TRON: newest-b"))
    }

    @Test("keeps reading one segment backwards past the window, so the newest records stay contiguous")
    func contiguousAcrossWindows() async throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let logs = home.appendingPathComponent("logs", isDirectory: true)
        try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        try (line("older-a") + line("older-b")).write(to: logs.appendingPathComponent("gateway.jsonl.1"), atomically: true, encoding: .utf8)
        var text = ""
        for index in 0..<8_000 { text += line("current-\(index)") }
        try text.write(to: logs.appendingPathComponent("gateway.jsonl"), atomically: true, encoding: .utf8)
        #expect(text.utf8.count > MenuBarLogReader.tailBytesPerSegment)

        let result = await MenuBarLogReader.fetchRecentLogs(tronHome: home, limit: 6_000)

        let expected = (2_000..<8_000).map { "[t] INFO TRON: current-\($0)" }.joined(separator: "\n")
        #expect(result == .success(expected))
    }

    @Test("large logs read from the file preserve formatting and fall back to the clipboard for the issue body")
    func largeLogsUseClipboardFallback() async throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let logs = home.appendingPathComponent("logs", isDirectory: true)
        try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        let message = String(repeating: "x", count: 1_990)
        let record = #"{"timestamp":"2026-09-05T00:00:00Z","level":"info","message":"\#(message)"}"# + "\n"
        try String(repeating: record, count: 200).write(to: logs.appendingPathComponent("gateway.jsonl"), atomically: true, encoding: .utf8)

        let result = await MenuBarLogReader.fetchRecentLogs(tronHome: home)

        let expected = Array(repeating: "[2026-09-05T00:00:00Z] INFO TRON: \(message)", count: 200).joined(separator: "\n")
        #expect(result == .success(expected))
        let composer = FeedbackIssueComposer(appVersion: "0.1.0", buildNumber: "1", osVersion: "fixture")
        #expect(composer.openPlan(serverDescription: "running", logs: expected)?.copiedFullBodyToClipboard == true)
    }

    @Test("log-capture failure text reaches only the redacted issue body")
    func failureTextIsRedactedInIssueBody() throws {
        let detail = #"failed {"token":"short-secret"}"#
        let composer = FeedbackIssueComposer(appVersion: "0.1.0", buildNumber: "1", osVersion: "fixture")
        let plan = try #require(composer.openPlan(serverDescription: "running", logs: "Log capture failed: \(detail)"))
        let body = try #require(URLComponents(url: plan.url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "body" }?.value)
        #expect(body.contains("Log capture failed: failed"))
        #expect(!body.contains("short-secret"))
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
