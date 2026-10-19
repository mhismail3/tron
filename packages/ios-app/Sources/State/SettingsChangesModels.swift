import Foundation
import TronMobileCore

/// Schema-formatted settings audit entry. The Gateway projection is disposable;
/// layer stores remain settings truth. Audit is only history and fenced undo.
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
    struct TierBasis: Decodable, Equatable, Sendable {
        let direction: String
        let floor: String
        let floorSource: String
        let web: Bool
        let risk: String?
        struct Evaluation: Decodable, Equatable, Sendable {
            let status: String
            let rationale: String
        }
        let riskEvaluation: Evaluation?
    }
    struct GitState: Decodable, Equatable, Sendable {
        let staged: Bool
        let reason: String?
        let warning: String?
        let head: String?
        let branch: String?
    }

    let tier: String
    let tierBasis: TierBasis?
    let git: GitState?
    let status: String
    let failure: String?
    let undoOf: String?
    /// A later fact's subject: for an outside change, the Tron change whose value it replaced.
    let refersTo: String?
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
        case .mac: layer == "mac"
        case .project(let cwd): layer == "project" && target.kind == "project" && target.cwd == cwd
        case .home(let sessionID):
            layer == "profile" || (target.kind == "session" && target.sessionId == sessionID)
        case .session(let id, _):
            layer == "chat" && target.kind == "session" && target.sessionId == id
        }
    }
}

extension SettingsApprovalRequest {
    func belongs(to scope: SettingsChangesScope) -> Bool {
        switch scope {
        case .all: true
        case .mac: changes.contains { $0.layer == "mac" }
        case .project(let cwd): target.kind == "project" && target.cwd == cwd && changes.contains { $0.layer == "project" }
        case .home(let sessionID): target.kind == "home" || (target.kind == "session" && target.sessionId == sessionID)
        case .session(let id, _): target.kind == "session" && target.sessionId == id
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
    case mac
    case project(String)
    case home(String)
    case session(String, projectCWD: String?)

    var title: String {
        switch self {
        case .all: "All scopes"
        case .mac: "Mac"
        case .project: "Repository"
        case .home: "Home"
        case .session: "This session"
        }
    }

    var storageKey: String {
        switch self {
        case .all: "all"
        case .mac: "mac"
        case .project(let cwd): "project.\(cwd)"
        case .home: "home"
        case .session(let id, let cwd): "session.\(id).\(cwd ?? "")"
        }
    }
}
