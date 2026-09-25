import Foundation

/// Builds `tron://pair?host=...&port=...&code=...&label=...` URLs for
/// the iOS `PairingInvitationParser` to consume.
enum PairingURLBuilder {
    private static let scheme = "tron"
    private static let host = "pair"

    /// Builds a `tron://pair?host=…&port=…&code=…[&label=…]` URL.
    /// The optional `label` value is the iOS server name.
    /// Returns nil if any required field is empty or malformed after trimming.
    static func makeURL(_ payload: PairingPayload) -> URL? {
        guard let canonicalHost = PairingHostValidator.canonicalHost(payload.host),
              (1...65_535).contains(payload.port) else {
            return nil
        }
        let trimmedCode = payload.code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (8...32).contains(trimmedCode.count) else {
            return nil
        }

        var components = URLComponents()
        components.scheme = scheme
        components.host = host
        var items: [URLQueryItem] = [
            URLQueryItem(name: "host", value: canonicalHost),
            URLQueryItem(name: "port", value: String(payload.port)),
            URLQueryItem(name: "code", value: trimmedCode),
        ]
        if let label = payload.label?.trimmingCharacters(in: .whitespacesAndNewlines), !label.isEmpty {
            items.append(URLQueryItem(name: "label", value: label))
        }
        components.queryItems = items
        return components.url
    }
}

/// Mirrors the iOS host contract: a pairing host is a bare DNS hostname, IPv4
/// address, or unbracketed IPv6 address, never a full URL/path/query/userinfo.
private enum PairingHostValidator {
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
            // Preserve the old host grammar: inet_pton also accepts embedded
            // IPv4 and scoped addresses, though the pairing contract did not.
            guard !trimmed.contains("."), !trimmed.contains("%"), TailscaleProbe.isIPv6(trimmed) else { return nil }
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

    private static func isASCIIAlphanumeric(_ scalar: Unicode.Scalar) -> Bool {
        (48...57).contains(scalar.value)
            || (65...90).contains(scalar.value)
            || (97...122).contains(scalar.value)
    }

    private static func isDigits(_ value: String) -> Bool {
        !value.isEmpty && value.unicodeScalars.allSatisfy { (48...57).contains($0.value) }
    }

}
