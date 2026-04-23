import Testing
import Foundation

@testable import TronMac

@Suite("FeedbackComposer (Mac)")
struct FeedbackComposerTests {

    @Test("subject includes app version + build number")
    func subjectFormat() {
        let c = FeedbackComposer(appVersion: "0.5.0", buildNumber: "12")
        #expect(c.subject() == "Tron feedback — v0.5.0 (12)")
    }

    @Test("formats log entries with iso8601 timestamp + category + level + message")
    func logFormatting() {
        let c = FeedbackComposer(appVersion: "0.5.0", buildNumber: "1")
        let entries = [
            FeedbackComposer.LogEntry(
                timestamp: Date(timeIntervalSince1970: 1_700_000_000),
                category: "server",
                level: "info",
                message: "hello world"
            )
        ]
        let body = c.formatLogs(entries)
        #expect(body.contains("hello world"))
        #expect(body.contains("[server]"))
        #expect(body.contains("info"))
    }

    @Test("log body redacts bearer tokens + home paths")
    func logBodyRedacted() {
        let c = FeedbackComposer(appVersion: "0.5.0", buildNumber: "1")
        let entries = [
            FeedbackComposer.LogEntry(
                timestamp: Date(timeIntervalSince1970: 1),
                category: "auth",
                level: "error",
                message: "Bearer 1234567890abcdef1234 failed from /Users/alice/x"
            )
        ]
        let body = c.formatLogs(entries)
        #expect(!body.contains("1234567890abcdef1234"))
        #expect(!body.contains("/Users/alice"))
        #expect(body.contains("[redacted:len=20]"))
        #expect(body.contains("~/x"))
    }

    @Test("tail limit respected")
    func tailLimit() {
        let c = FeedbackComposer(appVersion: "0.5.0", buildNumber: "1")
        var entries: [FeedbackComposer.LogEntry] = []
        for i in 0..<500 {
            entries.append(FeedbackComposer.LogEntry(
                timestamp: Date(timeIntervalSince1970: TimeInterval(i)),
                category: "g",
                level: "info",
                message: "line \(i)"
            ))
        }
        let body = c.formatLogs(entries, tailLimit: 25)
        let lines = body.split(separator: "\n", omittingEmptySubsequences: false)
        #expect(lines.count == 25)
        #expect(lines.first?.contains("line 475") == true)
        #expect(lines.last?.contains("line 499") == true)
    }

    @Test("assembleBody includes header + log section + user notes")
    func assembleBodyContainsAllSections() {
        let c = FeedbackComposer(appVersion: "0.5.0", buildNumber: "42")
        let entries = [
            FeedbackComposer.LogEntry(
                timestamp: Date(timeIntervalSince1970: 1),
                category: "g",
                level: "info",
                message: "hi"
            )
        ]
        let body = c.assembleBody(userNotes: "observed a bug", logs: entries)
        #expect(body.contains("observed a bug"))
        #expect(body.contains("App version: 0.5.0 (42)"))
        #expect(body.contains("Platform: macOS"))
        #expect(body.contains("Recent logs"))
        #expect(body.contains("hi"))
    }

    @Test("empty logs yields 'no logs captured' note")
    func emptyLogs() {
        let c = FeedbackComposer(appVersion: "0.5.0", buildNumber: "42")
        let body = c.assembleBody(userNotes: "", logs: [])
        #expect(body.contains("no logs captured"))
    }

    @Test("fallback mailto URL encodes subject and body safely")
    func fallbackMailtoEncodesSafely() {
        // Test the URL-building path without actually invoking
        // NSWorkspace.open — we verify the URLComponents produce a
        // well-formed mailto URL with properly encoded arguments.
        var comp = URLComponents()
        comp.scheme = "mailto"
        comp.path = FeedbackComposer.recipient
        comp.queryItems = [
            URLQueryItem(name: "subject", value: "test subject"),
            URLQueryItem(name: "body", value: "hello\nworld & more"),
        ]
        let url = comp.url
        #expect(url != nil)
        let urlString = url?.absoluteString ?? ""
        #expect(urlString.hasPrefix("mailto:\(FeedbackComposer.recipient)"))
        // Space encoding could be `%20` or `+` depending on the
        // encoder; both are valid. Similarly `&` within body is
        // URL-encoded to `%26`.
        #expect(urlString.contains("subject="))
        #expect(urlString.contains("body="))
        #expect(!urlString.contains(" world")) // whitespace is encoded
    }

    @Test("LogEntry decodes shape emitted by tron logs --json")
    func logEntryDecodes() throws {
        let json = #"{"ts":"2025-04-23T12:00:00Z","category":"server","level":"info","message":"ok"}"#
        let data = Data(json.utf8)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let entry = try decoder.decode(FeedbackComposer.LogEntry.self, from: data)
        #expect(entry.category == "server")
        #expect(entry.level == "info")
        #expect(entry.message == "ok")
    }
}
