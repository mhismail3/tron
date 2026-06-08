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
    /// Returns nil if any required field is empty after trimming.
    static func makeURL(_ payload: PairingPayload) -> URL? {
        let trimmedHost = payload.host.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedToken = payload.token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedHost.isEmpty, !trimmedToken.isEmpty, payload.port > 0 else {
            return nil
        }

        var components = URLComponents()
        components.scheme = scheme
        components.host = host
        var items: [URLQueryItem] = [
            URLQueryItem(name: "host", value: trimmedHost),
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
        guard let host = items.value(for: "host")?.trimmingCharacters(in: .whitespacesAndNewlines),
              !host.isEmpty,
              let portString = items.value(for: "port"),
              let port = Int(portString),
              port > 0,
              let token = items.value(for: "token")?.trimmingCharacters(in: .whitespacesAndNewlines),
              !token.isEmpty
        else {
            return nil
        }

        let label = items.value(for: "label")?.trimmingCharacters(in: .whitespacesAndNewlines)
        return PairingPayload(host: host, port: port, token: token, label: label?.isEmpty == false ? label : nil)
    }
}

private extension Array where Element == URLQueryItem {
    func value(for name: String) -> String? {
        first(where: { $0.name == name })?.value
    }
}
