import Foundation
import TronMobileCore

/// Schema-formatted settings audit entry. The Gateway projection is disposable;
/// the append-only record remains the source of truth.
struct SettingsChangeHistoryEntry: Decodable, Equatable, Sendable, Identifiable {
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

    struct Presentation: Decodable, Equatable, Sendable {
        let label: String
        let section: String?
        let actor: String
        let layer: String
        let display: Display
    }

    struct Display: Decodable, Equatable, Sendable {
        let before: String
        let after: String
    }

    let changeId: String
    let at: String
    let actor: Actor
    let target: Target
    let layer: String
    let key: String
    let qualifiers: [String: String]?
    let op: String
    let before: JSONValue?
    let after: JSONValue?
    let redacted: Bool?
    let reason: String?
    let tier: String
    let status: String
    let failure: String?
    let undoOf: String?
    let applyAgainOf: String?
    let presentation: Presentation?

    var id: String { changeId }
    var title: String { presentation?.label ?? key }
    var date: Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: at) ?? ISO8601DateFormatter().date(from: at)
    }

    func belongs(to scope: SettingsChangesScope) -> Bool {
        switch scope {
        case .all:
            true
        case .home:
            actor.kind == "home" || actor.kind == "worker"
        case .session(let id, let projectCWD):
            actor.sessionId == id || (target.kind == "session" && target.sessionId == id)
                || (target.kind == "project" && target.cwd == projectCWD && projectCWD != nil)
        }
    }
}

extension SettingsApprovalRequest {
    func belongs(to scope: SettingsChangesScope) -> Bool {
        switch scope {
        case .all: true
        case .home: actor.kind == "home" || actor.kind == "worker"
        case .session(let id, let projectCWD): actor.sessionId == id || (target.kind == "session" && target.sessionId == id)
            || (target.kind == "project" && target.cwd == projectCWD && projectCWD != nil)
        }
    }
}

struct SettingsChangeHistoryPage: Decodable, Sendable {
    let entries: [SettingsChangeHistoryEntry]
    let nextCursor: String?
}

/// Native entry point ownership: global Settings, Home, or one chat.
enum SettingsChangesScope: Hashable, Sendable {
    case all
    case home
    case session(String, projectCWD: String?)
}
