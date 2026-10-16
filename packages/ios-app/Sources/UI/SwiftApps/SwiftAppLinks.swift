import Foundation

/// The only URLs an interpreted program may open (#1160): an over-the-air
/// install manifest or an https page, both on the paired Gateway's host. The
/// host comes from the paired profile when the runner opens, never from the
/// program, so a file cannot widen its own reach. Everything else diagnoses.
struct SwiftAppLinkPolicy {
    /// The selected Gateway profile's host, or nil when no Gateway is paired.
    let host: String?

    /// An admitted link. An install opens directly, because iOS asks before
    /// installing; a page asks first in the runner (`needsConfirmation`).
    struct Link: Identifiable, Equatable {
        let id = UUID()
        let url: URL
        let needsConfirmation: Bool
    }

    func admit(_ text: String) throws -> Link {
        guard let components = URLComponents(string: text), let url = components.url else {
            throw SwiftAppRuntimeError("'\(text)' is not a URL")
        }
        switch components.scheme?.lowercased() {
        case "https":
            try requireGatewayHost(components, text)
            return Link(url: url, needsConfirmation: true)
        case "itms-services":
            let items = components.queryItems ?? []
            guard (components.host ?? "").isEmpty, components.path.isEmpty,
                  items.count == 2, items.contains(URLQueryItem(name: "action", value: "download-manifest")),
                  let manifest = items.first(where: { $0.name == "url" })?.value,
                  let manifestComponents = URLComponents(string: manifest),
                  manifestComponents.scheme?.lowercased() == "https" else {
                throw SwiftAppRuntimeError("Only itms-services download-manifest links with an https manifest can open: '\(text)'")
            }
            try requireGatewayHost(manifestComponents, text)
            return Link(url: url, needsConfirmation: false)
        default:
            throw SwiftAppRuntimeError("Only https and itms-services install links can open: '\(text)'")
        }
    }

    private func requireGatewayHost(_ components: URLComponents, _ text: String) throws {
        guard let host else { throw SwiftAppRuntimeError("Links open only with a paired Gateway: '\(text)'") }
        let target = components.host?.lowercased() ?? ""
        guard components.user == nil, components.password == nil, target == host.lowercased() else {
            throw SwiftAppRuntimeError("Link to \(target.isEmpty ? "'\(text)'" : target) is not allowed; links open only on \(host)")
        }
    }
}
