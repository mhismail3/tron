import Testing
import Foundation

@testable import TronMac

@Suite("SentryRedactor (Mac port)")
struct SentryRedactorTests {

    @Test("redacts Bearer <token> occurrences")
    func redactsBearer() {
        let r = SentryRedactor()
        let out = r.redactMessage("Upgrade: Bearer abcdef0123456789abcd failed")
        #expect(!out.contains("abcdef0123456789abcd"))
        #expect(out.contains("Bearer [redacted:len=20]"))
    }

    @Test("redacts /Users/<name>/ to ~/")
    func redactsHomePath() {
        let r = SentryRedactor()
        let out = r.redactMessage("load /Users/alice/.tron/system/settings.json")
        #expect(!out.contains("/Users/alice"))
        #expect(out.contains("~/.tron/system/settings.json"))
    }

    @Test("drops top-level message + userMessage; keeps safeField")
    func dropsChatFields() {
        let r = SentryRedactor()
        var event: [String: Any] = [
            "message": "sensitive",
            "extra": ["userMessage": "also sensitive", "safeField": "kept"],
        ]
        event = r.redactEvent(event)
        #expect(event["message"] as? String == "[redacted]")
        let extra = event["extra"] as? [String: Any]
        #expect(extra?["userMessage"] as? String == "[redacted]")
        #expect(extra?["safeField"] as? String == "kept")
    }

    @Test("breadcrumb message is surgically redacted, not dropped")
    func breadcrumbSurgical() {
        let r = SentryRedactor()
        var event: [String: Any] = [
            "breadcrumbs": [
                ["message": "Bearer tokenaaaaaaaaaaaaaaaaa1", "level": "info"]
            ]
        ]
        event = r.redactEvent(event)
        let crumbs = event["breadcrumbs"] as? [[String: Any]]
        let msg = crumbs?.first?["message"] as? String
        #expect(msg?.contains("tokenaaaaaaaaaaaaaaaaa1") == false)
        #expect(msg?.contains("[redacted:len=") == true)
    }
}
