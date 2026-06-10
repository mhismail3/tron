import Foundation

/// Builds and parses `tron://pair?host=...&port=...&token=...&label=...`
/// URLs. Mirrors the iOS `PairingURLParser` in
/// `packages/ios-app/Sources/Support/Pairing/PairingURLParser.swift` so the
/// QR codes the Mac wrapper emits round-trip cleanly through iOS.
enum PairingURLBuilder {
    static let scheme = "tron"
    static let host = "pair"

    /// Builds a `tron://pair?host=…&port=…&token=…[&label=…]` URL.
    /// The optional `label` value is the iOS server name.
    /// Returns nil if any required field is empty or malformed after trimming.
    static func makeURL(_ payload: PairingPayload) -> URL? {
        guard let canonicalHost = PairingHostValidator.canonicalHost(payload.host),
              (1...65_535).contains(payload.port) else {
            return nil
        }
        let trimmedToken = payload.token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedToken.isEmpty else {
            return nil
        }

        var components = URLComponents()
        components.scheme = scheme
        components.host = host
        var items: [URLQueryItem] = [
            URLQueryItem(name: "host", value: canonicalHost),
            URLQueryItem(name: "port", value: String(payload.port)),
            URLQueryItem(name: "token", value: trimmedToken),
        ]
        if let label = payload.label?.trimmingCharacters(in: .whitespacesAndNewlines), !label.isEmpty {
            items.append(URLQueryItem(name: "label", value: label))
        }
        components.queryItems = items
        return components.url
    }

    /// Parses a URL of the form `tron://pair?host=…&port=…&token=…[&label=…]`.
    /// Returns nil on any malformed input. Used by `Tests/Support/Pairing/PairingURLBuilderTests`
    /// to verify round-trip with iOS.
    static func parse(_ url: URL) -> PairingPayload? {
        guard url.scheme == scheme,
              url.host == host,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return nil
        }

        let items = components.queryItems ?? []
        guard let host = items.value(for: "host"),
              let canonicalHost = PairingHostValidator.canonicalHost(host),
              let portString = items.value(for: "port"),
              let port = Int(portString),
              (1...65_535).contains(port),
              let token = items.value(for: "token")?.trimmingCharacters(in: .whitespacesAndNewlines),
              !token.isEmpty
        else {
            return nil
        }

        let label = items.value(for: "label")?.trimmingCharacters(in: .whitespacesAndNewlines)
        return PairingPayload(host: canonicalHost, port: port, token: token, label: label?.isEmpty == false ? label : nil)
    }
}

/// Mirrors the iOS host contract: a pairing host is a bare DNS hostname, IPv4
/// address, or unbracketed IPv6 address, never a full URL/path/query/userinfo.
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

private extension Array where Element == URLQueryItem {
    func value(for name: String) -> String? {
        first(where: { $0.name == name })?.value
    }
}
