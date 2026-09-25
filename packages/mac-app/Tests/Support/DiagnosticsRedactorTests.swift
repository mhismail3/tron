import Testing
import Foundation

@testable import TronMac

@Suite("Feedback diagnostics redaction")
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

    @Test("redacts short and escaped JSON credentials without consuming safe fields", arguments: [
        #"{"token":"x","safeField":"kept"}"#,
        #"{"token":"prefix\"escaped-suffix","safeField":"kept"}"#,
        #"{"token":"ends-in-slash\\","safeField":"kept"}"#,
        #"{"token":"\\\"escaped-suffix","safeField":"kept"}"#,
        #"{"token":"\u0061","safeField":"kept"}"#,
        #"{"token":"🔑","safeField":"kept"}"#,
    ])
    func redactsQuotedCredentials(input: String) throws {
        let output = DiagnosticsRedactor().redactMessage(input)
        let decoded = try #require(JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: String])
        let token = try #require(decoded["token"])
        #expect(token.hasPrefix("[redacted:len="))
        #expect(token.hasSuffix("]"))
        #expect(!output.contains("escaped-suffix"))
        #expect(!output.contains("ends-in-slash"))
        #expect(decoded["safeField"] == "kept")
    }

    @Test("redacts complete short and encoded bearer runs", arguments: [
        "Bearer x", "bearer short", "BEARER abc+def/ghi~jkl==", "Bearer a.b_c-d",
    ])
    func redactsCompleteBearer(input: String) {
        let token = input.split(separator: " ").last!
        #expect(DiagnosticsRedactor().redactMessage(input) == "Bearer [redacted:len=\(token.count)]")
    }

    @Test("Bearer masking preserves line boundaries", arguments: [
        "Bearer \nabc", "Bearer\t\r\nabc", "Bearer\nabcdefghijklmnopqr",
        "Bearer\u{2028}abc",
    ])
    func preservesBearerLineBoundary(input: String) {
        #expect(DiagnosticsRedactor().redactMessage(input) == input)
    }

    @Test("horizontal Bearer whitespace still masks the credential")
    func redactsHorizontalBearerWhitespace() {
        #expect(DiagnosticsRedactor().redactMessage("Bearer\tx") == "Bearer [redacted:len=1]")
        #expect(DiagnosticsRedactor().redactMessage("Bearer\u{00A0}short") == "Bearer [redacted:len=5]")
    }

    @Test("Swift description escapes cannot reveal a credential suffix")
    func redactsEscapedSwiftDescription() {
        let input = #"Request(apiKey: "p\"escaped-suffix", apiKeyLabel: "Project", statusCode: "safe-code")"#
        let output = DiagnosticsRedactor().redactMessage(input)
        #expect(!output.contains("escaped-suffix"))
        #expect(output.contains(#"apiKeyLabel: "Project", statusCode: "safe-code""#))
    }

    @Test("truncated credential lines do not leak or consume the following diagnostic", arguments: [
        #"{"token":"truncated-secret"#,
        #"{"token":"truncated-secret\"#,
    ])
    func redactsTruncatedLine(input: String) {
        let nextLine = "\n[time] INFO: retry count=3"
        let output = DiagnosticsRedactor().redactMessage(input + nextLine)
        #expect(!output.contains("truncated-secret"))
        #expect(output.hasSuffix(nextLine))
    }

    @Test("ordinary diagnostics and empty credentials remain unchanged")
    func preservesNonSensitiveText() {
        let input = #"{"token":"","tokenCount":3,"apiKeyLabel":"Project","statusCode":"safe-code","message":"retry"} notBearer hello"#
        #expect(DiagnosticsRedactor().redactMessage(input) == input)
    }

    @Test("redacts local paths to placeholders")
    func redactsHomePath() {
        let r = DiagnosticsRedactor()
        let out = r.redactMessage("load /Users/alice/.tron/settings.toml")
        #expect(!out.contains("/Users/alice"))
        #expect(!out.contains(".tron/settings.toml"))
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

    @Test("masks URL userinfo and keeps scheme, host, port, path and query", arguments: [
        (input: "https://alice:s3cret@example.test/callback?state=ok",
         expected: "https://[redacted:userinfo]@example.test/callback?state=ok"),
        (input: "https://alice@example.test/callback",
         expected: "https://[redacted:userinfo]@example.test/callback"),
        (input: "https://alice:p%40ss%2Fword@example.test/inbox",
         expected: "https://[redacted:userinfo]@example.test/inbox"),
        (input: "https://alice:s3cret@[fd7a:115c:a1e0::1]:9847/v1/socket?limit=10",
         expected: "https://[redacted:userinfo]@[fd7a:115c:a1e0::1]:9847/v1/socket?limit=10"),
    ])
    func masksURLUserinfo(input: String, expected: String) {
        #expect(DiagnosticsRedactor().redactMessage(input) == expected)
    }

    @Test("leaves addresses without userinfo unchanged", arguments: [
        "https://example.test/callback?state=ok",
        "https://[fd7a:115c:a1e0::1]:9847/v1/socket",
        "contact=alice@example.test",
        "mailto:alice@example.test",
    ])
    func preservesAddressesWithoutUserinfo(input: String) {
        #expect(DiagnosticsRedactor().redactMessage(input) == input)
    }

    @Test("a URL path is still masked without damaging the userinfo placeholder")
    func userinfoPlaceholderSurvivesThePathPass() {
        #expect(
            DiagnosticsRedactor().redactMessage("https://alice:s3cret@example.test/tmp/state.json")
                == "https://[redacted:userinfo]@example.test[redacted:path]"
        )
    }

}
