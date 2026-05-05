import Testing
import Foundation

@testable import TronMobile

@Suite("DiagnosticsRedactor")
struct DiagnosticsRedactorTests {
    // MARK: - Bearer token redaction

    @Test("redacts Authorization: Bearer <token> occurrences in strings")
    func redactsBearerHeader() {
        let redactor = DiagnosticsRedactor()
        let input = "WS upgrade failed: Authorization: Bearer abc123def456GHI789jklmnopqrs header rejected"
        let redacted = redactor.redactMessage(input)
        #expect(!redacted.contains("abc123def456GHI789jklmnopqrs"))
        #expect(redacted.contains("Bearer [redacted:len=28]"))
    }

    @Test("redacts bearer-like JSON values without false positives on short words")
    func redactsJSONBearerValue() {
        let redactor = DiagnosticsRedactor()
        let input = #"{"token":"abc123def456GHI789jklmnopqrs","other":"foo"}"#
        let redacted = redactor.redactMessage(input)
        #expect(!redacted.contains("abc123def456GHI789jklmnopqrs"))
        #expect(redacted.contains("foo"))
    }

    @Test("redacts camelCase auth keys in JSON payloads")
    func redactsCamelCaseAuthJSONValues() {
        let redactor = DiagnosticsRedactor()
        let input = #"{"apiKey":"sk-live-abcdefghijklmnopqrstuvwxyz","accessToken":"access-token-1234567890","refreshToken":"refresh-token-1234567890","clientSecret":"client-secret-1234567890","authorizationCode":"oauth-code-1234567890"}"#
        let redacted = redactor.redactMessage(input)
        #expect(!redacted.contains("sk-live-abcdefghijklmnopqrstuvwxyz"))
        #expect(!redacted.contains("access-token-1234567890"))
        #expect(!redacted.contains("refresh-token-1234567890"))
        #expect(!redacted.contains("client-secret-1234567890"))
        #expect(!redacted.contains("oauth-code-1234567890"))
        #expect(redacted.contains(#""apiKey":"[redacted:len=34]""#))
        #expect(redacted.contains(#""accessToken":"[redacted:len=23]""#))
    }

    @Test("redacts Swift description auth fields")
    func redactsSwiftDescriptionAuthFields() {
        let redactor = DiagnosticsRedactor()
        let input = #"AddNamedApiKeyParams(provider: "openai", apiKey: "sk-test-abcdefghijklmnopqrstuvwxyz", apiKeyLabel: "Work") OAuth(code: "oauth-code-1234567890")"#
        let redacted = redactor.redactMessage(input)
        #expect(!redacted.contains("sk-test-abcdefghijklmnopqrstuvwxyz"))
        #expect(!redacted.contains("oauth-code-1234567890"))
        #expect(redacted.contains(#"apiKey: "[redacted:len=34]""#))
        #expect(redacted.contains(#"code: "[redacted:len=21]""#))
        #expect(redacted.contains("Work"))
    }

    @Test("leaves plain text without tokens untouched")
    func leavesPlainTextAlone() {
        let redactor = DiagnosticsRedactor()
        let input = "Normal log line describing WebSocket state change"
        let redacted = redactor.redactMessage(input)
        #expect(redacted == input)
    }

    // MARK: - Path redaction

    @Test("redacts local file paths to placeholders")
    func stripsHomeDirectoryPaths() {
        let redactor = DiagnosticsRedactor()
        let input = "Failed to open /Users/alice/Downloads/projects/tron/packages/agent/target/debug/tron"
        let redacted = redactor.redactMessage(input)
        #expect(!redacted.contains("/Users/alice"))
        #expect(!redacted.contains("Downloads/projects/tron"))
        #expect(redacted.contains("[redacted:path]"))
    }

    @Test("redacts workspace log-db paths to placeholder")
    func stripsWorkspacePath() {
        let redactor = DiagnosticsRedactor()
        let input = "SQLite open failed: /Users/bob/.tron/internal/database/log.db row not found"
        let redacted = redactor.redactMessage(input)
        #expect(!redacted.contains("/Users/bob"))
        #expect(!redacted.contains(".tron/internal/database/log.db"))
        #expect(redacted.contains("[redacted:path]"))
    }

    @Test("redacts simulator and file-url paths")
    func redactsSimulatorAndFileURLPaths() {
        let redactor = DiagnosticsRedactor()
        let input = "db=file:///private/var/mobile/Containers/Data/Application/ABC/prod.db temp=/tmp/tron/log.txt"
        let redacted = redactor.redactMessage(input)
        #expect(!redacted.contains("/private/var"))
        #expect(!redacted.contains("/tmp/tron"))
        let occurrences = redacted.components(separatedBy: "[redacted:path]").count - 1
        #expect(occurrences == 2)
    }

    @Test("handles multiple occurrences in same string")
    func redactsMultipleOccurrences() {
        let redactor = DiagnosticsRedactor()
        let input = "from /Users/alice/a to /Users/alice/b via /Users/alice/c"
        let redacted = redactor.redactMessage(input)
        #expect(!redacted.contains("/Users/alice"))
        let occurrences = redacted.components(separatedBy: "[redacted:path]").count - 1
        #expect(occurrences == 3)
    }

    // MARK: - Event payload redaction

    @Test("drops message/chat content fields entirely")
    func dropsChatContentFields() {
        let redactor = DiagnosticsRedactor()
        var event: [String: Any] = [
            "message": "User chat content that must never leak",
            "level": "error",
            "extra": [
                "userMessage": "also secret",
                "safeField": "kept"
            ],
        ]
        event = redactor.redactEvent(event)
        #expect(event["message"] as? String == "[redacted]")
        let extra = event["extra"] as? [String: Any]
        #expect(extra?["userMessage"] as? String == "[redacted]")
        #expect(extra?["safeField"] as? String == "kept")
    }

    @Test("redacts bearer tokens inside nested breadcrumbs")
    func redactsNestedBreadcrumbBearer() {
        let redactor = DiagnosticsRedactor()
        var event: [String: Any] = [
            "breadcrumbs": [
                [
                    "message": "Authorization: Bearer tokennnnnnnnnnnnnnnnnnnn1",
                    "level": "info",
                ]
            ]
        ]
        event = redactor.redactEvent(event)
        let crumbs = event["breadcrumbs"] as? [[String: Any]]
        let first = crumbs?.first
        let msg = first?["message"] as? String
        #expect(msg?.contains("tokennnnnnnnnnnnnnnnnnnn1") == false)
        #expect(msg?.contains("[redacted:len=25]") == true)
    }

    @Test("redacts file paths inside the tags section")
    func redactsPathsInTags() {
        let redactor = DiagnosticsRedactor()
        var event: [String: Any] = [
            "tags": [
                "path": "/Users/charlie/Library/Preferences/com.tron.plist"
            ]
        ]
        event = redactor.redactEvent(event)
        let tags = event["tags"] as? [String: Any]
        #expect((tags?["path"] as? String)?.contains("/Users/charlie") == false)
    }

    // MARK: - Idempotence

    @Test("is idempotent — running redactor twice equals running once")
    func isIdempotent() {
        let redactor = DiagnosticsRedactor()
        let input = "Bearer abcdefghijklmnopqrstuvwxyz012 in /Users/alice/x"
        let once = redactor.redactMessage(input)
        let twice = redactor.redactMessage(once)
        #expect(once == twice)
    }
}
