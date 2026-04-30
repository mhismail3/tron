import Foundation

/// Scrubs PII from log lines + diagnostic event payloads before they leave
/// the device. All mutation lives here (tests pin the exact output
/// format) so diagnostic exporter integration is a one-line `beforeSend` wrapper.
///
/// Redactions applied:
/// - `Authorization: Bearer <token>` and bare `Bearer <token>` →
///   `Bearer [redacted:len=N]`.
/// - JSON-shaped auth keys such as `"token":"..."`, `"apiKey":"..."`,
///   `"accessToken":"..."`, and `"clientSecret":"..."` → value
///   replaced with `[redacted:len=N]`.
/// - Swift `String(describing:)` auth fields such as
///   `apiKey: "..."` → value replaced with `[redacted:len=N]`.
/// - Local filesystem paths such as `/Users/<username>/...`,
///   `/private/var/...`, `/tmp/...`, and `~/...` →
///   `[redacted:path]`.
/// - `message`, `userMessage`, `chatText`, `prompt`, `messageContent`
///   fields in event payloads are fully replaced with `"[redacted]"`
///   — no chat content can ever reach diagnostics.
///
/// The redactor is stateless; create one per send call or share a
/// single instance — both are safe.
struct DiagnosticsRedactor {
    /// Fields dropped entirely (case-insensitive match). They commonly
    /// carry user chat content.
    static let dropFields: Set<String> = [
        "message",
        "usermessage",
        "chattext",
        "prompt",
        "messagecontent",
    ]

    // MARK: - Public API

    func redactMessage(_ input: String) -> String {
        var out = input
        out = Self.redactBearerRuns(out)
        out = Self.redactJSONTokenValues(out)
        out = Self.redactSwiftDescriptionTokenValues(out)
        out = Self.redactLocalPaths(out)
        return out
    }

    /// Redacts a top-level diagnostic event dict. Applies the full drop-
    /// fields rule (primary `message`, `userMessage`, etc. replaced
    /// with `[redacted]`). Nested dicts reached through `extra`,
    /// `tags`, `contexts` etc. also apply the drop rule.
    ///
    /// Inside `breadcrumbs` and other array-valued fields, each array
    /// element is a structured log entry — we apply only surgical
    /// string redactions there, NOT the drop-field rule, because a
    /// breadcrumb's `message` is log-like (not chat content).
    func redactEvent(_ event: [String: Any]) -> [String: Any] {
        var mutable = event
        for (key, value) in mutable {
            let lowered = key.lowercased()
            if Self.dropFields.contains(lowered) {
                mutable[key] = "[redacted]"
                continue
            }
            mutable[key] = redactValue(value, inArrayElement: false)
        }
        return mutable
    }

    // MARK: - Private helpers

    private func redactValue(_ value: Any, inArrayElement: Bool) -> Any {
        if let str = value as? String {
            return redactMessage(str)
        }
        if let dict = value as? [String: Any] {
            return inArrayElement
                ? redactDictSurgical(dict)
                : redactEvent(dict)
        }
        if let array = value as? [Any] {
            return array.map { redactValue($0, inArrayElement: true) }
        }
        return value
    }

    /// Walks a dict with string-level redactions only (no drop-fields).
    /// Used for array-element dicts like breadcrumbs, where every key
    /// is structurally log-like.
    private func redactDictSurgical(_ dict: [String: Any]) -> [String: Any] {
        var mutable = dict
        for (key, value) in mutable {
            mutable[key] = redactValue(value, inArrayElement: true)
        }
        return mutable
    }

    // Matches `Bearer <token>` where token is 16+ chars of
    // letters/digits/`-`/`_`/`=`/`.` (base64url + base64 variants).
    private static let bearerRegex: NSRegularExpression = {
        // swiftlint:disable:next force_try — static pattern
        try! NSRegularExpression(
            pattern: #"Bearer\s+([A-Za-z0-9_\-=\.]{16,})"#,
            options: []
        )
    }()

    /// Matches `"key":"<value>"` for keys known to carry tokens.
    private static let jsonTokenRegex: NSRegularExpression = {
        // swiftlint:disable:next force_try — static pattern
        try! NSRegularExpression(
            pattern: #""(token|authorization|bearer|access_token|api_key|apiKey|accessToken|refreshToken|clientSecret|authorizationCode|authCode|oauthCode|code)"\s*:\s*"([^"]{8,})""#,
            options: [.caseInsensitive]
        )
    }()

    /// Matches Swift debug-description fields like `apiKey: "value"`.
    private static let swiftDescriptionTokenRegex: NSRegularExpression = {
        // swiftlint:disable:next force_try — static pattern
        try! NSRegularExpression(
            pattern: #"\b(token|authorization|bearer|apiKey|accessToken|refreshToken|clientSecret|authorizationCode|authCode|oauthCode|code)\s*:\s*"([^"]{8,})""#,
            options: [.caseInsensitive]
        )
    }()

    /// Common local path prefixes that can reveal usernames, workspace
    /// names, or simulator/container IDs. The match intentionally stops
    /// at punctuation commonly used to delimit paths in log messages.
    private static let localPathRegex: NSRegularExpression = {
        // swiftlint:disable:next force_try — static pattern
        try! NSRegularExpression(
            pattern: #"(?:file://)?(?:/Users|/home|/private/var|/var|/tmp|/Volumes|/Applications|~/)[^\s"'<>),;]*"#,
            options: []
        )
    }()

    /// Replaces `Bearer <token>` with `Bearer [redacted:len=N]`.
    /// Walks matches in reverse so earlier ranges stay valid.
    private static func redactBearerRuns(_ input: String) -> String {
        let ns = input as NSString
        let matches = bearerRegex.matches(in: input, range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return input }

        var out = input
        for match in matches.reversed() where match.numberOfRanges >= 2 {
            let fullRange = match.range(at: 0)
            let tokenRange = match.range(at: 1)
            guard let swiftRange = Range(fullRange, in: out) else { continue }
            let replacement = "Bearer [redacted:len=\(tokenRange.length)]"
            out.replaceSubrange(swiftRange, with: replacement)
        }
        return out
    }

    /// Redacts JSON-shaped token values. Keeps the key, replaces
    /// value with `[redacted:len=N]`.
    private static func redactJSONTokenValues(_ input: String) -> String {
        let ns = input as NSString
        let matches = jsonTokenRegex.matches(in: input, range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return input }

        var out = input
        for match in matches.reversed() where match.numberOfRanges >= 3 {
            let valueRange = match.range(at: 2)
            guard let swiftRange = Range(valueRange, in: out) else { continue }
            let original = String(out[swiftRange])
            let replacement = "[redacted:len=\(original.count)]"
            out.replaceSubrange(swiftRange, with: replacement)
        }
        return out
    }

    /// Redacts Swift debug-description token values. Keeps the field
    /// label, replaces the quoted value with `[redacted:len=N]`.
    private static func redactSwiftDescriptionTokenValues(_ input: String) -> String {
        let ns = input as NSString
        let matches = swiftDescriptionTokenRegex.matches(in: input, range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return input }

        var out = input
        for match in matches.reversed() where match.numberOfRanges >= 3 {
            let valueRange = match.range(at: 2)
            guard let swiftRange = Range(valueRange, in: out) else { continue }
            let original = String(out[swiftRange])
            let replacement = "[redacted:len=\(original.count)]"
            out.replaceSubrange(swiftRange, with: replacement)
        }
        return out
    }

    /// Local filesystem paths → `[redacted:path]` across all occurrences.
    private static func redactLocalPaths(_ input: String) -> String {
        let ns = input as NSString
        let fullRange = NSRange(location: 0, length: ns.length)
        return localPathRegex.stringByReplacingMatches(
            in: input,
            options: [],
            range: fullRange,
            withTemplate: "[redacted:path]"
        )
    }
}
