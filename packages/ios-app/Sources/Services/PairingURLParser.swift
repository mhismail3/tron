import Foundation

/// Pure-value parser for `tron://pair?host=…&port=…&token=…` deep-links.
///
/// Used by:
///   - the iOS Pairing onboarding step (Phase 4) when the QR scanner
///     surfaces a captured payload,
///   - the universal-paste path on every text field of the pairing form
///     (so a user can paste the full link into any field and have it
///     auto-distribute), and
///   - the "Re-pair" sheet (Phase 3.6) to refresh a stored token when
///     the Mac app rotates one.
///
/// The parser is intentionally strict — every field is required, the
/// scheme must be `tron`, and `port` must be a positive 16-bit integer.
/// Extra query parameters are tolerated (forward-compat for future
/// fields like `label`) but unrecognized ones are dropped.
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
        /// Optional human label (e.g. `"My Mac"`); the Mac wizard may
        /// embed this in the QR for a friendlier preset name.
        let label: String?
    }

    enum ParseError: Error, Equatable {
        case wrongScheme(String)
        case wrongHostComponent(String)   // not `pair`
        case missingHost
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
        guard let portString = value("port") else { return .failure(.missingPort) }
        guard let port = Int(portString), (1...65_535).contains(port) else {
            return .failure(.invalidPort(portString))
        }
        guard let token = value("token") else { return .failure(.missingToken) }

        return .success(.init(
            host: host,
            port: port,
            token: token,
            label: value("label")
        ))
    }

    /// Inverse — produce a `tron://pair?…` URL for QR encoding.
    /// Used by the Mac wizard's pairing step to render the QR code AND
    /// by tests that round-trip the parser.
    static func makeURL(host: String, port: Int, token: String, label: String? = nil) -> URL? {
        var components = URLComponents()
        components.scheme = "tron"
        components.host = "pair"
        var items: [URLQueryItem] = [
            URLQueryItem(name: "host", value: host),
            URLQueryItem(name: "port", value: String(port)),
            URLQueryItem(name: "token", value: token),
        ]
        if let label, !label.isEmpty {
            items.append(URLQueryItem(name: "label", value: label))
        }
        components.queryItems = items
        return components.url
    }
}

