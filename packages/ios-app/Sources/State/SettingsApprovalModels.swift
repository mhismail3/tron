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
    let kind: String
    let label: String
    let detail: String?
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

    var id: String {
        ([key] + (qualifiers ?? [:]).sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }).joined(separator: "|")
    }

    func badge(_ kind: String) -> SettingsBadge? { badges.first { $0.kind == kind } }
}

struct SettingsResolution: Decodable, Sendable {
    let keys: [ResolvedSetting]
}

/// A dry run of the maintainer's own change: the tier it would get and, for an
/// approve-tier change, the key's `confirm` text his row shows first (doc 5.4).
struct SettingsChangePreview: Equatable, Sendable {
    let tier: String
    let confirm: String?
}
