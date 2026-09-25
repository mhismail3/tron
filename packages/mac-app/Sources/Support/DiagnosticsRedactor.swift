import Foundation

/// Masks known credential fields and local paths in exported feedback text,
/// retaining surrounding diagnostics. This is not a general secret detector.
struct DiagnosticsRedactor {
    func redactMessage(_ input: String) -> String {
        // URL userinfo is a credential in the same position a key/value pair
        // would occupy, so it is masked before the credential and path passes
        // could consume part of the URL instead.
        let urls = Self.redactURLUserinfo(input)
        // Mask complete quoted values first, before a nested Bearer run could
        // replace part of their value and change the reported source length.
        let credentials = Self.redactQuotedCredentials(urls)
        let bearers = Self.redactBearerRuns(credentials)
        let fields = Self.redactUnquotedCredentials(bearers)
        let ns = fields as NSString
        return Self.localPathRegex.stringByReplacingMatches(
            in: fields, range: NSRange(location: 0, length: ns.length),
            withTemplate: "[redacted:path]"
        )
    }

    // RFC 3986 userinfo: everything between the scheme's `//` and the host's
    // separator `@`. The class stops at `/` so a plain text address with no
    // scheme cannot be read as userinfo and the host, port, path and query are
    // left to the other passes.
    private static let urlUserinfoRegex = try! NSRegularExpression(
        pattern: #"\b([A-Za-z][A-Za-z0-9+.\-]*)://([^\s/@]+)@"#
    )

    // A missing token at line end must not consume the next diagnostic line.
    private static let bearerRegex = try! NSRegularExpression(
        pattern: #"\bBearer\h+([^\s,;]+)"#,
        options: [.caseInsensitive]
    )

    // JSON and Swift descriptions share quoted-value syntax. Consume escaped
    // quotes/backslashes as units; length heuristics or stopping at an escaped
    // quote can expose secrets. A bounded Gateway log can end mid-value, so an
    // unterminated value is masked through its line end, never the next record.
    private static let quotedCredentialRegex = try! NSRegularExpression(
        pattern: #"(?<![\w"])("?)(token|authorization|bearer|access[-_ ]?token|api[-_ ]?key|refresh[-_ ]?token|clientSecret|authorizationCode|authCode|oauthCode|password|secret|code)\1\s*:\s*"((?:\\[^\r\n]|[^"\\\r\n])*(?:\\(?=\r?$))?)(?:"|(?=\r?$))"#,
        options: [.caseInsensitive, .anchorsMatchLines]
    )

    private static let unquotedCredentialRegex = try! NSRegularExpression(
        pattern: #"(?<!["'])((?:authorization|api[-_ ]?key|access[-_ ]?token|refresh[-_ ]?token|password|secret|token)\h*[:=]\h*)(?:"((?:\\.|[^"\\\r\n])*)"|'((?:\\.|[^'\\\r\n])*)'|([^\s,;]+))"#,
        options: [.caseInsensitive]
    )

    private static let localPathRegex = try! NSRegularExpression(
        pattern: #"(?:file://)?(?:/Users|/home|/private/var|/var|/tmp|/Volumes|/Applications|~/)[^\s"'<>),;]*"#
    )

    private static func redactURLUserinfo(_ input: String) -> String {
        let ns = input as NSString
        let matches = urlUserinfoRegex.matches(in: input, range: NSRange(location: 0, length: ns.length))
        var out = input
        for match in matches.reversed() {
            guard let range = Range(match.range(at: 2), in: out) else { continue }
            out.replaceSubrange(range, with: "[redacted:userinfo]")
        }
        return out
    }

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

    private static func redactUnquotedCredentials(_ input: String) -> String {
        let ns = input as NSString
        let matches = unquotedCredentialRegex.matches(in: input, range: NSRange(location: 0, length: ns.length))
        var out = input
        for match in matches.reversed() {
            let valueRange = (2...4).map { match.range(at: $0) }.first { $0.location != NSNotFound }
            guard let valueRange, valueRange.length > 0,
                  let range = Range(valueRange, in: out),
                  !out[range].hasPrefix("[redacted:len=") else { continue }
            let length = out[range].count
            out.replaceSubrange(range, with: "[redacted:len=\(length)]")
        }
        return out
    }
}
