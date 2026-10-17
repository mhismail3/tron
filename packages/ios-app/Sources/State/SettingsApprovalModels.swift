import Foundation
import TronMobileCore

/// One pending settings change as `settings.approvals` serves it (gateway
/// docs/settings-model.md 5.5). Every word a row shows is Gateway text: who
/// asked (`requester`), each key's `label`, its `display` strings and `confirm`.
/// The raw `before` and `after` are the exact values the decision binds to.
struct SettingsApprovalRequest: Decodable, Equatable, Sendable, Identifiable {
    struct Actor: Decodable, Equatable, Sendable {
        let kind: String
        let sessionId: String?
        let taskId: String?
    }

    struct Target: Decodable, Equatable, Sendable {
        let kind: String
        let sessionId: String?
        let cwd: String?
    }

    struct Change: Decodable, Equatable, Sendable, Identifiable {
        struct Display: Decodable, Equatable, Sendable {
            let before: String
            let after: String
        }

        let changeId: String
        let key: String
        let label: String
        let qualifiers: [String: String]?
        let layer: String
        let op: String
        let tier: String
        let before: JSONValue?
        let after: JSONValue?
        let redacted: Bool?
        let display: Display?
        let confirm: String?

        var id: String { changeId }
    }

    let requestId: String
    let digest: String
    let createdAt: String
    let expiresAt: String
    let target: Target
    let actor: Actor
    let requester: String
    let reason: String?
    let changes: [Change]

    var id: String { requestId }

    var expiryDate: Date? { Self.date(expiresAt) }

    private static func date(_ text: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: text) ?? ISO8601DateFormatter().date(from: text)
    }
}

/// Which pending changes a surface shows (docs/settings-model.md 7.4 scopes):
/// Manage Home shows Home's and its task workers'; Manage Session shows the
/// ones this chat asked for or that would change this chat.
enum SettingsApprovalScope: Hashable, Sendable {
    case home
    case session(String)

    func includes(_ request: SettingsApprovalRequest) -> Bool {
        switch self {
        case .home:
            return request.actor.kind == "home" || request.actor.kind == "worker"
        case .session(let sessionID):
            return request.actor.sessionId == sessionID
                || (request.target.kind == "session" && request.target.sessionId == sessionID)
        }
    }
}

struct SettingsApprovalsResponse: Decodable, Sendable {
    let requests: [SettingsApprovalRequest]
}

/// One badge as the resolver returns it; iOS maps `kind` to a style only.
struct SettingsBadge: Decodable, Hashable, Sendable {
    struct Action: Decodable, Hashable, Sendable {
        let kind: String
        let label: String
        /// The record entry an action applies to (Apply again names its outside change).
        var changeId: String? = nil
    }
    let kind: String
    let label: String
    let detail: String?
    let action: Action?

    init(kind: String, label: String, detail: String?, action: Action? = nil) {
        self.kind = kind; self.label = label; self.detail = detail; self.action = action
    }
}

/// One resolved key instance from `settings.resolve` (docs/settings-model.md 3.1).
struct ResolvedSetting: Decodable, Equatable, Sendable, Identifiable {
    let key: String
    let qualifiers: [String: String]?
    let group: String
    let subgroup: String?
    let value: JSONValue?
    let display: String
    let layer: String
    let applied: Bool
    let badges: [SettingsBadge]
    struct Layer: Decodable, Equatable, Sendable {
        let layer: String
        /// This layer's own stored value; absent when the layer holds none.
        let value: JSONValue?
        /// Redacted settings still expose whether this layer holds a value.
        let display: String?
    }
    let layers: [Layer]
    /// Absent from a Gateway that predates the renderer contract: the row is then read-only.
    let presentation: SettingsKeyPresentation?

    var id: String { settingIdentity(key: key, qualifiers: qualifiers) }

    func badge(_ kind: String) -> SettingsBadge? { badges.first { $0.kind == kind } }

    /// The served value, or one layer's own value for a surface that edits that
    /// layer and must not show what a higher layer overrides.
    func value(at layer: String) -> JSONValue? { layers.first { $0.layer == layer }?.value }
}

/// `settings.resolve`: the key instances and, when the request negotiated the
/// renderer contract, the sections that summarize them in the Gateway's order.
struct SettingsResolution: Decodable, Sendable {
    let keys: [ResolvedSetting]
    let sections: [SettingsRendererSection]

    private enum CodingKeys: String, CodingKey { case keys, sections }

    /// The row for an unqualified schema key, when the Gateway served it for this target.
    func setting(_ key: String) -> ResolvedSetting? { keys.first { $0.key == key } }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        keys = try container.decode([ResolvedSetting].self, forKey: .keys)
        sections = try container.decodeIfPresent([SettingsRendererSection].self, forKey: .sections) ?? []
    }
}
