import Foundation

/// Scrubs PII from log lines + Sentry event payloads before they leave
/// the device. All mutation lives here (tests pin the exact output
/// format) so Sentry SDK integration is a one-line `beforeSend` wrapper.
///
/// Redactions applied:
/// - `Authorization: Bearer <token>` and bare `Bearer <token>` →
///   `Bearer [redacted:len=N]`.
/// - JSON-shaped `"token":"..."`, `"authorization":"Bearer ..."`,
///   `"access_token":"..."`, `"api_key":"..."` → value replaced with
///   `[redacted:len=N]`.
/// - `/Users/<username>/...` → `~/...` (home-directory stripping).
/// - `message`, `userMessage`, `chatText`, `prompt`, `messageContent`
///   fields in event payloads are fully replaced with `"[redacted]"`
///   — no chat content can ever reach Sentry.
///
/// The redactor is stateless; create one per send call or share a
/// single instance — both are safe.
struct SentryRedactor {
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
        out = Self.redactHomePaths(out)
        return out
    }

    /// Redacts a top-level Sentry event dict. Applies the full drop-
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

    /// Matches `"key":"<value>"` for a small allowlist of keys known
    /// to carry tokens.
    private static let jsonTokenRegex: NSRegularExpression = {
        // swiftlint:disable:next force_try — static pattern
        try! NSRegularExpression(
            pattern: #""(token|authorization|bearer|access_token|api_key)"\s*:\s*"([^"]{8,})""#,
            options: [.caseInsensitive]
        )
    }()

    /// `/Users/<segment>/` where segment is 1+ non-slash, non-space chars.
    private static let homePathRegex: NSRegularExpression = {
        // swiftlint:disable:next force_try — static pattern
        try! NSRegularExpression(
            pattern: #"/Users/[^/\s"']+/"#,
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

    /// `/Users/<name>/` → `~/` across all occurrences.
    private static func redactHomePaths(_ input: String) -> String {
        let ns = input as NSString
        let fullRange = NSRange(location: 0, length: ns.length)
        return homePathRegex.stringByReplacingMatches(
            in: input,
            options: [],
            range: fullRange,
            withTemplate: "~/"
        )
    }
}
