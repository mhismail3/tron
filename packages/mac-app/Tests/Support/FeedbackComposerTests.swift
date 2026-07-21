import Foundation
import Testing

@testable import TronMac

@Suite("FeedbackIssueComposer (Mac)")
struct FeedbackComposerTests {
    @Test("title includes app version and build number")
    func titleFormat() {
        let composer = FeedbackIssueComposer(appVersion: "0.1.0-beta.1", buildNumber: "1", osVersion: "macOS 15.0")
        #expect(composer.title() == "Mac menu bar feedback - v0.1 (Beta 1) (build 1)")
    }

    @Test("body includes environment, status, and redacted logs")
    func bodyRedactsLogs() {
        let composer = FeedbackIssueComposer(appVersion: "0.1.0-beta.1", buildNumber: "1", osVersion: "macOS 15.0")
        let body = composer.body(
            serverDescription: "failed (timeout)",
            logs: "Bearer 1234567890abcdef1234 failed from /Users/alice/project"
        )

        #expect(body.contains("App: v0.1 (Beta 1) (build 1)"))
        #expect(body.contains("macOS: macOS 15.0"))
        #expect(body.contains("Server: failed (timeout)"))
        #expect(!body.contains("1234567890abcdef1234"))
        #expect(!body.contains("/Users/alice"))
        #expect(body.contains("[redacted:len=20]"))
    }

    @Test("issue URL targets GitHub issues, not mail")
    func issueURL() throws {
        let composer = FeedbackIssueComposer(appVersion: "0.1.0-beta.1", buildNumber: "1", osVersion: "macOS 15.0")
        let plan = try #require(composer.openPlan(serverDescription: "running on port 9847, version v0.1 (Beta 1)", logs: "hello"))

        #expect(plan.url.scheme == "https")
        #expect(plan.url.host == "github.com")
        #expect(plan.url.path.hasSuffix("/tron/issues/new"))
        #expect(plan.url.absoluteString.contains("title="))
        #expect(plan.url.absoluteString.contains("body="))
        #expect(!plan.url.absoluteString.hasPrefix("mailto:"))
    }

    @Test("oversized body opens title-only issue and marks body for clipboard")
    func oversizedBodyUsesClipboardPlan() throws {
        let composer = FeedbackIssueComposer(appVersion: "0.1.0-beta.1", buildNumber: "1", osVersion: "macOS 15.0")
        let plan = try #require(composer.openPlan(serverDescription: "running on port 9847, version v0.1 (Beta 1)", logs: String(repeating: "x", count: 20_000)))

        #expect(plan.copiedFullBodyToClipboard)
        #expect(plan.url.absoluteString.count < FeedbackIssueComposer.maxPrefilledURLLength)
    }
}
