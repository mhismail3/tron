import Testing
import Foundation

@testable import TronMac

@Suite("DiagnosticsRedactor (Mac port)")
struct DiagnosticsRedactorTests {

    @Test("redacts Bearer <token> occurrences")
    func redactsBearer() {
        let r = DiagnosticsRedactor()
        let out = r.redactMessage("Upgrade: Bearer abcdef0123456789abcd failed")
        #expect(!out.contains("abcdef0123456789abcd"))
        #expect(out.contains("Bearer [redacted:len=20]"))
    }

    @Test("redacts camelCase auth keys in JSON payloads")
    func redactsCamelCaseAuthJSONValues() {
        let r = DiagnosticsRedactor()
        let input = #"{"apiKey":"sk-live-abcdefghijklmnopqrstuvwxyz","accessToken":"access-token-1234567890","refreshToken":"refresh-token-1234567890","clientSecret":"client-secret-1234567890","authorizationCode":"oauth-code-1234567890"}"#
        let out = r.redactMessage(input)

        #expect(!out.contains("sk-live-abcdefghijklmnopqrstuvwxyz"))
        #expect(!out.contains("access-token-1234567890"))
        #expect(!out.contains("refresh-token-1234567890"))
        #expect(!out.contains("client-secret-1234567890"))
        #expect(!out.contains("oauth-code-1234567890"))
        #expect(out.contains(#""apiKey":"[redacted:len=34]""#))
        #expect(out.contains(#""accessToken":"[redacted:len=23]""#))
    }

    @Test("redacts Swift description auth fields")
    func redactsSwiftDescriptionAuthFields() {
        let r = DiagnosticsRedactor()
        let input = #"AddNamedApiKeyParams(provider: "openai", apiKey: "sk-test-abcdefghijklmnopqrstuvwxyz", apiKeyLabel: "Project") OAuth(code: "oauth-code-1234567890")"#
        let out = r.redactMessage(input)

        #expect(!out.contains("sk-test-abcdefghijklmnopqrstuvwxyz"))
        #expect(!out.contains("oauth-code-1234567890"))
        #expect(out.contains(#"apiKey: "[redacted:len=34]""#))
        #expect(out.contains(#"code: "[redacted:len=21]""#))
        #expect(out.contains("Project"))
    }

    @Test("redacts local paths to placeholders")
    func redactsHomePath() {
        let r = DiagnosticsRedactor()
        let out = r.redactMessage("load /Users/alice/.tron/profiles/user/profile.toml")
        #expect(!out.contains("/Users/alice"))
        #expect(!out.contains(".tron/profiles/user/profile.toml"))
        #expect(out.contains("[redacted:path]"))
    }

    @Test("redacts simulator and file-url paths")
    func redactsSimulatorAndFileURLPaths() {
        let r = DiagnosticsRedactor()
        let out = r.redactMessage("db=file:///private/var/mobile/Containers/Data/Application/ABC/prod.db tmp=/tmp/tron/log.txt")
        #expect(!out.contains("/private/var"))
        #expect(!out.contains("/tmp/tron"))
        let occurrences = out.components(separatedBy: "[redacted:path]").count - 1
        #expect(occurrences == 2)
    }

    @Test("drops top-level message + userMessage; keeps safeField")
    func dropsChatFields() {
        let r = DiagnosticsRedactor()
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
        let r = DiagnosticsRedactor()
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
