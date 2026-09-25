import Foundation
import Testing

@testable import TronMac

@Suite("FeedbackIssueComposer (Mac)")
struct FeedbackComposerTests {

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
}
