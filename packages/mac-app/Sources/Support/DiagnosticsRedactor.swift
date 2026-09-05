import Foundation

/// Masks known credential fields and local paths in exported feedback text,
/// retaining surrounding diagnostics. This is not a general secret detector.
struct DiagnosticsRedactor {
    func redactMessage(_ input: String) -> String {
        // Mask complete quoted values first, before a nested Bearer run could
        // replace part of their value and change the reported source length.
        let credentials = Self.redactQuotedCredentials(input)
        let bearers = Self.redactBearerRuns(credentials)
        let ns = bearers as NSString
        return Self.localPathRegex.stringByReplacingMatches(
            in: bearers, range: NSRange(location: 0, length: ns.length),
            withTemplate: "[redacted:path]"
        )
    }

    // A missing token at line end must not consume the next diagnostic line.
    private static let bearerRegex = try! NSRegularExpression(
        pattern: #"\bBearer\h+([A-Za-z0-9._~+/\-]+=*)"#,
        options: [.caseInsensitive]
    )

    // JSON and Swift descriptions share quoted-value syntax. Consume escaped
    // quotes/backslashes as units; length heuristics or stopping at an escaped
    // quote can expose secrets. A bounded Gateway log can end mid-value, so an
    // unterminated value is masked through its line end, never the next record.
    private static let quotedCredentialRegex = try! NSRegularExpression(
        pattern: #"(?<![\w"])("?)(token|authorization|bearer|access_token|api_key|apiKey|accessToken|refreshToken|clientSecret|authorizationCode|authCode|oauthCode|code)\1\s*:\s*"((?:\\[^\r\n]|[^"\\\r\n])*(?:\\(?=\r?$))?)(?:"|(?=\r?$))"#,
        options: [.caseInsensitive, .anchorsMatchLines]
    )

    private static let localPathRegex = try! NSRegularExpression(
        pattern: #"(?:file://)?(?:/Users|/home|/private/var|/var|/tmp|/Volumes|/Applications|~/)[^\s"'<>),;]*"#
    )

    private static func redactBearerRuns(_ input: String) -> String {
        let ns = input as NSString
        let matches = bearerRegex.matches(in: input, range: NSRange(location: 0, length: ns.length))
        var out = input
        for match in matches.reversed() {
            guard let range = Range(match.range, in: out) else { continue }
            out.replaceSubrange(range, with: "Bearer [redacted:len=\(match.range(at: 1).length)]")
        }
        return out
    }

    private static func redactQuotedCredentials(_ input: String) -> String {
        let ns = input as NSString
        let matches = quotedCredentialRegex.matches(in: input, range: NSRange(location: 0, length: ns.length))
        var out = input
        for match in matches.reversed() where match.range(at: 3).length > 0 {
            guard let range = Range(match.range(at: 3), in: out) else { continue }
            let length = out[range].count
            out.replaceSubrange(range, with: "[redacted:len=\(length)]")
        }
        return out
    }
}
