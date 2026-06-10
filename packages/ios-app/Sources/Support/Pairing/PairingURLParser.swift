import Foundation

/// Pure-value parser for `tron://pair?host=…&port=…&token=…` deep-links.
///
/// Used by:
///   - the iOS Pairing onboarding step (Phase 4) when the QR scanner
///     surfaces a captured payload,
///   - the universal-paste path on every text field of the pairing form
///     (so a user can paste the full link into any field and have it
///     auto-distribute), and
///   - Settings-launched pairing to refresh a stored token when the Mac app
///     rotates one.
///
/// The parser is intentionally strict — every field is required, the
/// scheme must be `tron`, and `port` must be a positive 16-bit integer.
/// Extra query parameters are tolerated, but unrecognized ones are dropped.
///
/// **Why not Codable?** URL query strings aren't JSON; we'd reach for
/// Codable only after building a synthetic dict. The hand-rolled parse
/// is shorter and surfaces classification per-field for the UI.
enum PairingURLParser {

    /// The successfully parsed pairing payload.
    struct PairingPayload: Equatable {
        let host: String
        let port: Int
        let token: String
        /// Optional server name. The URL field is `label`; the UI presents it
        /// as "Server Name."
        let label: String?
    }

    enum ParseError: Error, Equatable {
        case wrongScheme(String)
        case wrongHostComponent(String)   // not `pair`
        case missingHost
        case invalidHost(String)
        case missingPort
        case invalidPort(String)
        case missingToken
        case malformedURL
    }

    /// Try to parse a `tron://pair?…` string. Returns the payload or a
    /// classified error (caller decides UI surfacing).
    static func parse(_ raw: String) -> Result<PairingPayload, ParseError> {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let components = URLComponents(string: trimmed) else {
            return .failure(.malformedURL)
        }
        guard let scheme = components.scheme?.lowercased(), scheme == "tron" else {
            return .failure(.wrongScheme(components.scheme ?? ""))
        }
        // URL has a `host` component (`pair`) — we treat it case-insensitively.
        guard (components.host?.lowercased() ?? "") == "pair" else {
            return .failure(.wrongHostComponent(components.host ?? ""))
        }

        let items = components.queryItems ?? []
        func value(_ key: String) -> String? {
            items.first(where: { $0.name.lowercased() == key })?.value?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .nilIfEmpty
        }

        guard let host = value("host") else { return .failure(.missingHost) }
        guard let canonicalHost = PairingHostValidator.canonicalHost(host) else {
            return .failure(.invalidHost(host))
        }
        guard let portString = value("port") else { return .failure(.missingPort) }
        guard let port = Int(portString), (1...65_535).contains(port) else {
            return .failure(.invalidPort(portString))
        }
        guard let token = value("token") else { return .failure(.missingToken) }

        return .success(.init(
            host: canonicalHost,
            port: port,
            token: token,
            label: value("label")
        ))
    }

    /// Inverse — produce a `tron://pair?…` URL for QR encoding.
    /// Used by the Mac wizard's pairing step to render the QR code AND
    /// by tests that round-trip the parser.
    static func makeURL(host: String, port: Int, token: String, label: String? = nil) -> URL? {
        guard let canonicalHost = PairingHostValidator.canonicalHost(host),
              (1...65_535).contains(port) else {
            return nil
        }
        let trimmedToken = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedToken.isEmpty else { return nil }

        var components = URLComponents()
        components.scheme = "tron"
        components.host = "pair"
        var items: [URLQueryItem] = [
            URLQueryItem(name: "host", value: canonicalHost),
            URLQueryItem(name: "port", value: String(port)),
            URLQueryItem(name: "token", value: trimmedToken),
        ]
        if let label = label?.trimmingCharacters(in: .whitespacesAndNewlines), !label.isEmpty {
            items.append(URLQueryItem(name: "label", value: label))
        }
        components.queryItems = items
        return components.url
    }
}

/// Canonical host validator shared by QR/deep-link parsing and manual pairing.
///
/// Accepted values are a bare DNS hostname, IPv4 address, or unbracketed IPv6
/// address. Full URLs, paths, query strings, userinfo, bracketed IPv6, and any
/// whitespace/control characters are rejected before a pairing probe can build
/// a WebSocket URL from the value.
enum PairingHostValidator {
    static func canonicalHost(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard trimmed.rangeOfCharacter(from: .whitespacesAndNewlines) == nil,
              trimmed.rangeOfCharacter(from: .controlCharacters) == nil else {
            return nil
        }
        guard !trimmed.contains("://"),
              trimmed.rangeOfCharacter(from: CharacterSet(charactersIn: "/\\?#@[]")) == nil else {
            return nil
        }

        if trimmed.contains(":") {
            guard isValidIPv6(trimmed) else { return nil }
            return trimmed.lowercased()
        }

        var host = trimmed
        if host.hasSuffix(".") {
            host.removeLast()
        }
        guard !host.isEmpty, host.count <= 253 else { return nil }

        let labels = host.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        guard !labels.isEmpty,
              labels.allSatisfy(isValidDNSLabel) else {
            return nil
        }

        if labels.count == 4 && labels.allSatisfy(isDigits) {
            guard labels.allSatisfy({ UInt8($0) != nil }) else { return nil }
        }

        return host.lowercased()
    }

    private static func isValidDNSLabel(_ label: String) -> Bool {
        guard !label.isEmpty, label.count <= 63 else { return false }
        let scalars = Array(label.unicodeScalars)
        guard scalars.first?.value != 45, scalars.last?.value != 45 else {
            return false
        }
        return scalars.allSatisfy { scalar in
            isASCIIAlphanumeric(scalar) || scalar.value == 45
        }
    }

    private static func isValidIPv6(_ host: String) -> Bool {
        guard host.unicodeScalars.allSatisfy({ isASCIIHex($0) || $0.value == 58 }) else {
            return false
        }
        guard host.contains(":"),
              !host.contains(":::"),
              occurrenceCount(of: "::", in: host) <= 1 else {
            return false
        }

        if host.contains("::") {
            let parts = host.components(separatedBy: "::")
            guard parts.count == 2 else { return false }
            let left = ipv6Segments(parts[0])
            let right = ipv6Segments(parts[1])
            guard left.valid, right.valid else { return false }
            return left.count + right.count < 8
        }

        let segments = host.split(separator: ":", omittingEmptySubsequences: false)
        guard segments.count == 8 else { return false }
        return segments.allSatisfy(isValidIPv6Segment)
    }

    private static func ipv6Segments(_ side: String) -> (valid: Bool, count: Int) {
        guard !side.isEmpty else { return (true, 0) }
        let segments = side.split(separator: ":", omittingEmptySubsequences: false)
        guard segments.allSatisfy(isValidIPv6Segment) else { return (false, segments.count) }
        return (true, segments.count)
    }

    private static func isValidIPv6Segment(_ segment: Substring) -> Bool {
        (1...4).contains(segment.count) && segment.unicodeScalars.allSatisfy(isASCIIHex)
    }

    private static func isASCIIAlphanumeric(_ scalar: Unicode.Scalar) -> Bool {
        (48...57).contains(scalar.value)
            || (65...90).contains(scalar.value)
            || (97...122).contains(scalar.value)
    }

    private static func isASCIIHex(_ scalar: Unicode.Scalar) -> Bool {
        (48...57).contains(scalar.value)
            || (65...70).contains(scalar.value)
            || (97...102).contains(scalar.value)
    }

    private static func isDigits(_ value: String) -> Bool {
        !value.isEmpty && value.unicodeScalars.allSatisfy { (48...57).contains($0.value) }
    }

    private static func occurrenceCount(of needle: String, in haystack: String) -> Int {
        var count = 0
        var searchStart = haystack.startIndex
        while let range = haystack.range(of: needle, range: searchStart..<haystack.endIndex) {
            count += 1
            searchStart = range.upperBound
        }
        return count
    }
}

extension PairingURLParser.PairingPayload {
    /// Apply this payload to a 4-field pairing form, preserving the user's
    /// server name if they've already customized it.
    ///
    /// The default server name (`"My Mac"`) is treated as the placeholder,
    /// not a user-typed value — so a payload's label can override it. Anything
    /// else the user typed wins over the URL's label.
    ///
    /// Returns the (host, port, token, label) tuple to commit. Used by both
    /// the onboarding pairing step (via `OnboardingState.acceptPairingPayload`)
    /// so the "what counts as user-edited" rule has one source of truth.
    func distributing(
        currentLabel: String,
        defaultLabel: String = "My Mac"
    ) -> (host: String, port: String, token: String, label: String) {
        let resolvedLabel: String
        if currentLabel.isEmpty || currentLabel == defaultLabel,
           let pastedLabel = label, !pastedLabel.isEmpty {
            resolvedLabel = pastedLabel
        } else {
            resolvedLabel = currentLabel
        }
        return (
            host: host,
            port: String(port),
            token: token,
            label: resolvedLabel
        )
    }
}
