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

    // MARK: - Body assembly

    @Test("full body explains attachment with actual included log time range")
    func fullBodyUsesIncludedLogTimeRange() throws {
        let composer = FeedbackComposer(appVersion: "0.1.0-beta.1", buildNumber: "1")
        let first = try #require(ISO8601DateFormatter().date(from: "2026-04-29T21:00:00Z"))
        let last = try #require(ISO8601DateFormatter().date(from: "2026-04-29T21:15:30Z"))
        let summary = DiagnosticsBundleLogSummary(
            iosLogCount: 2,
            serverLogCount: 1,
            earliestLogTimestamp: first,
            latestLogTimestamp: last
        )
        let body = composer.assembleBody(
            userNotes: "Saw a bug",
            attachmentFileName: "tron-diagnostics-20260429-210000Z.json",
            logSummary: summary
        )
        #expect(body.contains("Saw a bug"))
        #expect(body.contains("Attached is a JSON diagnostics bundle with recent Tron logs from 2026-04-29T21:00:00Z to 2026-04-29T21:15:30Z."))
        #expect(body.contains("Included log entries: iOS 2, server 1"))
        #expect(body.contains("App version:"))
        #expect(body.contains("Platform: iOS"))
        #expect(body.contains("Attached diagnostics bundle: tron-diagnostics-20260429-210000Z.json"))
    }

    @Test("body falls back when no parseable log timestamps exist")
    func bodyFallsBackWithoutLogTimeRange() {
        let composer = FeedbackComposer(appVersion: "0.1.0-beta.1", buildNumber: "1")
        let summary = DiagnosticsBundleLogSummary(
            iosLogCount: 0,
            serverLogCount: 1,
            earliestLogTimestamp: nil,
            latestLogTimestamp: nil
        )
        let body = composer.assembleBody(
            userNotes: "",
            attachmentFileName: "tron-diagnostics-20260429-210000Z.json",
            logSummary: summary
        )
        #expect(body.contains("Attached is a JSON diagnostics bundle with recent Tron diagnostics."))
        #expect(body.contains("Included log entries: iOS 0, server 1"))
        #expect(!body.contains("from 2026"))
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

    @Test("delivery is mail-only and reports unavailable states")
    func deliveryIsMailOnly() {
        #expect(
            FeedbackDeliveryPlanner.route(configuredRecipient: nil, canSendMail: true)
                == .mailUnavailable(message: FeedbackDeliveryPlanner.missingRecipientMessage)
        )
        #expect(
            FeedbackDeliveryPlanner.route(configuredRecipient: "feedback@example.invalid", canSendMail: false)
                == .mailUnavailable(message: FeedbackDeliveryPlanner.mailUnavailableMessage)
        )
        #expect(
            FeedbackDeliveryPlanner.route(configuredRecipient: "feedback@example.invalid", canSendMail: true)
                == .mail(recipient: "feedback@example.invalid")
        )
    }
}
