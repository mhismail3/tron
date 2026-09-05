import Foundation
import Testing

@testable import TronMac

@Suite("FeedbackIssueComposer (Mac)")
struct FeedbackComposerTests {
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

    @Test("prefilled issue body redacts short and escaped credentials and preserves diagnostics")
    func prefilledBodyRedactsCredentials() throws {
        let composer = FeedbackIssueComposer(appVersion: "0.1.0-beta.1", buildNumber: "1", osVersion: "macOS 15.0")
        let plan = try #require(composer.openPlan(
            serverDescription: #"failed (apiKey: "status-secret")"#,
            logs: #"[time] INFO: {"token":"short","clientSecret":"p\"escaped-suffix","safeField":"kept"}"#
        ))
        let components = try #require(URLComponents(url: plan.url, resolvingAgainstBaseURL: false))
        let body = try #require(components.queryItems?.first { $0.name == "body" }?.value)
        #expect(!plan.copiedFullBodyToClipboard)
        #expect(!body.contains("short"))
        #expect(!body.contains("escaped-suffix"))
        #expect(!body.contains("status-secret"))
        #expect(body.contains("[time] INFO:"))
        #expect(body.contains(#""safeField":"kept""#))
        #expect(body.contains("Server: failed"))
        #expect(body.contains("App: v0.1 (Beta 1) (build 1)"))
    }

    @Test("clipboard fallback uses the same sanitized body without changing its route")
    func clipboardBodyRedactsCredentials() throws {
        let composer = FeedbackIssueComposer(appVersion: "0.1.0-beta.1", buildNumber: "1", osVersion: "macOS 15.0")
        let logs = String(repeating: "ordinary diagnostic\n", count: 1_000) + #"{"token":"x","clientSecret":"p\"escaped-suffix"}"#
        let status = "failed from /Users/alice/project"
        let plan = try #require(composer.openPlan(serverDescription: status, logs: logs))
        let body = composer.body(serverDescription: status, logs: logs)
        #expect(plan.copiedFullBodyToClipboard)
        #expect(plan.url.absoluteString.count < FeedbackIssueComposer.maxPrefilledURLLength)
        #expect(plan.url.host == "github.com")
        #expect(!body.contains("escaped-suffix"))
        #expect(!body.contains(#""token":"x""#))
        #expect(!body.contains("/Users/alice"))
        #expect(body.contains("ordinary diagnostic"))
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
