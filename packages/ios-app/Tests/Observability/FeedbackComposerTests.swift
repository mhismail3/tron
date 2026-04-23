import Testing
import Foundation

@testable import TronMobile

@Suite("FeedbackComposer")
struct FeedbackComposerTests {

    // MARK: - Subject line

    @Test("subject includes app version + build number")
    func subjectIncludesVersion() {
        let composer = FeedbackComposer(appVersion: "0.5.0", buildNumber: "42")
        #expect(composer.subject() == "Tron feedback — v0.5.0 (42)")
    }

    // MARK: - Log attachment formatting

    @Test("formats log lines oldest-first, one per line, with iso8601 timestamp + category + level")
    func logLinesFormattedCorrectly() {
        let composer = FeedbackComposer(appVersion: "0.5.0", buildNumber: "1")
        let ts1 = Date(timeIntervalSince1970: 1_700_000_000)
        let ts2 = Date(timeIntervalSince1970: 1_700_000_001)
        let entries: [(Date, LogCategory, LogLevel, String)] = [
            (ts1, .network, .info, "connected"),
            (ts2, .rpc, .error, "session.create failed"),
        ]
        let body = composer.formatLogs(entries)
        let lines = body.split(separator: "\n", omittingEmptySubsequences: false)
        #expect(lines.count >= 2)
        #expect(lines[0].contains("connected"))
        #expect(lines[0].contains("Network"))
        #expect(lines[0].contains("INFO"))
        #expect(lines[1].contains("session.create failed"))
        #expect(lines[1].contains("RPC"))
        #expect(lines[1].contains("ERROR"))
    }

    @Test("log body redacts bearer tokens + home paths via SentryRedactor")
    func logBodyRedacted() {
        let composer = FeedbackComposer(appVersion: "0.5.0", buildNumber: "1")
        let entries: [(Date, LogCategory, LogLevel, String)] = [
            (Date(timeIntervalSince1970: 1), .network, .info,
             "Authorization: Bearer 1234567890abcdef1234567890 /Users/alice/x"),
        ]
        let body = composer.formatLogs(entries)
        #expect(!body.contains("1234567890abcdef1234567890"))
        #expect(!body.contains("/Users/alice"))
        #expect(body.contains("[redacted:len=26]"))
        #expect(body.contains("~/x"))
    }

    @Test("tail limit respected — returns at most N entries")
    func tailLimitRespected() {
        let composer = FeedbackComposer(appVersion: "0.5.0", buildNumber: "1")
        var entries: [(Date, LogCategory, LogLevel, String)] = []
        for i in 0..<500 {
            entries.append((Date(timeIntervalSince1970: TimeInterval(i)), .general, .info, "line \(i)"))
        }
        let body = composer.formatLogs(entries, tailLimit: 50)
        let lines = body.split(separator: "\n", omittingEmptySubsequences: false)
        #expect(lines.count == 50)
        // Should be the LAST 50 (450..499), not the first.
        #expect(lines.first?.contains("line 450") == true)
        #expect(lines.last?.contains("line 499") == true)
    }

    // MARK: - Body assembly

    @Test("full body has header + log section + footer")
    func fullBodyHasAllSections() {
        let composer = FeedbackComposer(appVersion: "0.5.0", buildNumber: "42")
        let entries: [(Date, LogCategory, LogLevel, String)] = [
            (Date(timeIntervalSince1970: 1), .general, .info, "hi")
        ]
        let body = composer.assembleBody(userNotes: "Saw a bug", logs: entries)
        #expect(body.contains("Saw a bug"))
        #expect(body.contains("App version:"))
        #expect(body.contains("Recent logs"))
        #expect(body.contains("hi"))
    }

    @Test("empty log tail yields a short body with 'no logs captured' note")
    func emptyLogsHandledGracefully() {
        let composer = FeedbackComposer(appVersion: "0.5.0", buildNumber: "42")
        let body = composer.assembleBody(userNotes: "", logs: [])
        #expect(body.contains("no logs captured"))
    }

    // MARK: - Recipient

    @Test("recipient is feedback@tron.computer — pinned for privacy-policy compliance")
    func recipientPinned() {
        #expect(FeedbackComposer.recipient == "feedback@tron.computer")
    }
}
