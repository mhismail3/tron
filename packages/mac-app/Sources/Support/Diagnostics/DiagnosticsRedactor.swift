import Foundation

/// Mac port of the iOS `DiagnosticsRedactor` (see
/// `packages/ios-app/Sources/Support/Diagnostics/DiagnosticsRedactor.swift`).
///
/// Kept as a direct copy rather than a shared module because the iOS
/// and Mac projects don't currently share a Swift package. If this
/// drifts, update both files or extract a common SPM package.
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
///   top-level dict keys → `"[redacted]"`.
struct DiagnosticsRedactor {
    static let dropFields: Set<String> = [
        "message",
        "usermessage",
        "chattext",
        "prompt",
        "messagecontent",
    ]

    func redactMessage(_ input: String) -> String {
        var out = input
        out = Self.redactBearerRuns(out)
        out = Self.redactJSONTokenValues(out)
        out = Self.redactSwiftDescriptionTokenValues(out)
        out = Self.redactLocalPaths(out)
        return out
    }

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

    private func redactValue(_ value: Any, inArrayElement: Bool) -> Any {
        if let str = value as? String {
            return redactMessage(str)
        }
        if let dict = value as? [String: Any] {
            return inArrayElement ? redactDictSurgical(dict) : redactEvent(dict)
        }
        if let array = value as? [Any] {
            return array.map { redactValue($0, inArrayElement: true) }
        }
        return value
    }

    private func redactDictSurgical(_ dict: [String: Any]) -> [String: Any] {
        var mutable = dict
        for (key, value) in mutable {
            mutable[key] = redactValue(value, inArrayElement: true)
        }
        return mutable
    }

    // MARK: - Regexes (shared with iOS port)

    private static let bearerRegex: NSRegularExpression = {
        // swiftlint:disable:next force_try
        try! NSRegularExpression(pattern: #"Bearer\s+([A-Za-z0-9_\-=\.]{16,})"#, options: [])
    }()

    private static let jsonTokenRegex: NSRegularExpression = {
        // swiftlint:disable:next force_try
        try! NSRegularExpression(
            pattern: #""(token|authorization|bearer|access_token|api_key|apiKey|accessToken|refreshToken|clientSecret|authorizationCode|authCode|oauthCode|code)"\s*:\s*"([^"]{8,})""#,
            options: [.caseInsensitive]
        )
    }()

    private static let swiftDescriptionTokenRegex: NSRegularExpression = {
        // swiftlint:disable:next force_try
        try! NSRegularExpression(
            pattern: #"\b(token|authorization|bearer|apiKey|accessToken|refreshToken|clientSecret|authorizationCode|authCode|oauthCode|code)\s*:\s*"([^"]{8,})""#,
            options: [.caseInsensitive]
        )
    }()

    private static let localPathRegex: NSRegularExpression = {
        // swiftlint:disable:next force_try
        try! NSRegularExpression(
            pattern: #"(?:file://)?(?:/Users|/home|/private/var|/var|/tmp|/Volumes|/Applications|~/)[^\s"'<>),;]*"#,
            options: []
        )
    }()

    private static func redactBearerRuns(_ input: String) -> String {
        let ns = input as NSString
        let matches = bearerRegex.matches(in: input, range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return input }

        var out = input
        for match in matches.reversed() where match.numberOfRanges >= 2 {
            let fullRange = match.range(at: 0)
            let tokenRange = match.range(at: 1)
            guard let swiftRange = Range(fullRange, in: out) else { continue }
            out.replaceSubrange(swiftRange, with: "Bearer [redacted:len=\(tokenRange.length)]")
        }
        return out
    }

    private static func redactJSONTokenValues(_ input: String) -> String {
        let ns = input as NSString
        let matches = jsonTokenRegex.matches(in: input, range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return input }

        var out = input
        for match in matches.reversed() where match.numberOfRanges >= 3 {
            let valueRange = match.range(at: 2)
            guard let swiftRange = Range(valueRange, in: out) else { continue }
            let original = String(out[swiftRange])
            out.replaceSubrange(swiftRange, with: "[redacted:len=\(original.count)]")
        }
        return out
    }

    private static func redactSwiftDescriptionTokenValues(_ input: String) -> String {
        let ns = input as NSString
        let matches = swiftDescriptionTokenRegex.matches(in: input, range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return input }

        var out = input
        for match in matches.reversed() where match.numberOfRanges >= 3 {
            let valueRange = match.range(at: 2)
            guard let swiftRange = Range(valueRange, in: out) else { continue }
            let original = String(out[swiftRange])
            out.replaceSubrange(swiftRange, with: "[redacted:len=\(original.count)]")
        }
        return out
    }

    private static func redactLocalPaths(_ input: String) -> String {
        let ns = input as NSString
        let fullRange = NSRange(location: 0, length: ns.length)
        return localPathRegex.stringByReplacingMatches(
            in: input, options: [], range: fullRange, withTemplate: "[redacted:path]"
        )
    }
}
