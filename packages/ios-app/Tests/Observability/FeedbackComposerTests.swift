import Testing
import Foundation

@testable import TronMobile

@Suite("FeedbackComposer")
struct FeedbackComposerTests {

    // MARK: - Subject line

    @Test("subject includes app version + build number")
    func subjectIncludesVersion() {
        let composer = FeedbackComposer(appVersion: "0.1.0-beta.1", buildNumber: "1")
        #expect(composer.subject() == "Tron feedback — v0.1 (Beta 1) (build 1)")
    }

    // MARK: - Log attachment formatting

    @Test("formats log lines oldest-first, one per line, with iso8601 timestamp + category + level")
    func logLinesFormattedCorrectly() {
        let composer = FeedbackComposer(appVersion: "0.1.0-beta.1", buildNumber: "1")
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

    @Test("log body redacts bearer tokens + local paths via DiagnosticsRedactor")
    func logBodyRedacted() {
        let composer = FeedbackComposer(appVersion: "0.1.0-beta.1", buildNumber: "1")
        let entries: [(Date, LogCategory, LogLevel, String)] = [
            (Date(timeIntervalSince1970: 1), .network, .info,
             "Authorization: Bearer 1234567890abcdef1234567890 /Users/alice/x"),
        ]
        let body = composer.formatLogs(entries)
        #expect(!body.contains("1234567890abcdef1234567890"))
        #expect(!body.contains("/Users/alice"))
        #expect(body.contains("[redacted:len=26]"))
        #expect(body.contains("[redacted:path]"))
    }

    @Test("tail limit respected — returns at most N entries")
    func tailLimitRespected() {
        let composer = FeedbackComposer(appVersion: "0.1.0-beta.1", buildNumber: "1")
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

    @Test("full body has header + attachment note")
    func fullBodyHasAllSections() {
        let composer = FeedbackComposer(appVersion: "0.1.0-beta.1", buildNumber: "1")
        let entries: [(Date, LogCategory, LogLevel, String)] = [
            (Date(timeIntervalSince1970: 1), .general, .info, "hi")
        ]
        let body = composer.assembleBody(
            userNotes: "Saw a bug",
            attachmentFileName: "tron-diagnostics-20260429-210000Z.json",
            logs: entries
        )
        #expect(body.contains("Saw a bug"))
        #expect(body.contains("App version:"))
        #expect(body.contains("Attached diagnostics bundle: tron-diagnostics-20260429-210000Z.json"))
        #expect(body.contains("hi"))
    }

    @Test("empty log tail yields a short body with no inline log section")
    func emptyLogsHandledGracefully() {
        let composer = FeedbackComposer(appVersion: "0.1.0-beta.1", buildNumber: "1")
        let body = composer.assembleBody(userNotes: "", attachmentFileName: nil, logs: [])
        #expect(body.contains("No diagnostics attachment was generated."))
        #expect(!body.contains("Recent logs preview"))
    }

    // MARK: - Recipient

    @Test("recipient is read from Info.plist-style runtime configuration")
    func recipientConfiguredAtRuntime() {
        #expect(FeedbackComposer.configuredRecipient(infoDictionary: [:]) == nil)
        #expect(FeedbackComposer.configuredRecipient(infoDictionary: [
            FeedbackComposer.recipientInfoPlistKey: "$(TRON_FEEDBACK_EMAIL)"
        ]) == nil)
        #expect(FeedbackComposer.configuredRecipient(infoDictionary: [
            FeedbackComposer.recipientInfoPlistKey: "feedback@example.invalid"
        ]) == "feedback@example.invalid")
    }

    @Test("delivery falls back to share sheet without configured Mail route")
    func deliveryFallsBackWithoutMailRoute() {
        #expect(FeedbackDeliveryPlanner.route(configuredRecipient: nil, canSendMail: true) == .shareSheet)
        #expect(FeedbackDeliveryPlanner.route(configuredRecipient: "feedback@example.invalid", canSendMail: false) == .shareSheet)
    }
}
