import Foundation
import TronMobileCore

enum HomeTaskLifecycle: String, Decodable, Sendable { case pending, active, terminal }
enum HomeTaskOutcome: String, Decodable, Sendable { case progress, needsInput = "needs-input", final, limited, interrupted, unknown }

struct HomeTaskSpendDTO: Decodable, Equatable, Sendable {
    let sourceDigest: String
    let inputTokens: Int
    let outputTokens: Int
    var valid: Bool {
        HomeMemoryPageDTO.isDigest(sourceDigest) && safeHomeCount(inputTokens) && safeHomeCount(outputTokens)
    }
}

struct HomeTaskPageDTO: Decodable, Equatable, Sendable {
    struct Row: Decodable, Equatable, Sendable, Identifiable {
        let taskId: String
        let createdAt: Int
        let updatedAt: Int
        /// The worker's name, else the brief's first line; absent on an older Gateway.
        let title: String?
        /// The target directory's last path component.
        let project: String?
        let workerSessionId: String?
        let target: String
        let lifecycle: HomeTaskLifecycle
        let outcome: HomeTaskOutcome?
        let spend: HomeTaskSpendDTO?
        let attention: Bool
        let pendingGrant: Bool
        var id: String { taskId }
        var valid: Bool {
            homeID(taskId) && safeHomeCount(createdAt) && safeHomeCount(updatedAt) && updatedAt >= createdAt
                && (title.map { $0.unicodeScalars.count <= 160 && homeText($0, bytes: 640) } ?? true)
                && (project.map { homeText($0, bytes: 512) } ?? true)
                && (workerSessionId.map(homeID) ?? true)
                && homeText(target, bytes: 4096)
                && target.hasPrefix("/") && ((lifecycle == .terminal) == (outcome != nil)) && (spend?.valid ?? true)
        }
    }
    let items: [Row]
    let nextCursor: String?
    static func decode(_ value: JSONValue) throws -> Self {
        let page = try value.decode(Self.self)
        guard page.items.count <= 50, page.items.allSatisfy(\.valid), Set(page.items.map(\.id)).count == page.items.count,
              zip(page.items, page.items.dropFirst()).allSatisfy({ $0.createdAt > $1.createdAt || ($0.createdAt == $1.createdAt && $0.id < $1.id) }),
              page.nextCursor.map({ homeText($0, bytes: 1024) && !page.items.isEmpty }) ?? true else { throw invalidHomeTask() }
        return page
    }
}

/// Exact execution/route authority from home.taskStatus, never inferred from a
/// list row. Immutable report bodies remain with the canonical Gateway owner.
struct HomeTaskDTO: Decodable, Equatable, Sendable {
    struct Intent: Decodable, Equatable, Sendable { let text: String }
    struct Terminal: Decodable, Equatable, Sendable {
        let outcome: HomeTaskOutcome
        let reason: String
    }
    struct Wake: Decodable, Equatable, Sendable {
        enum State: String, Decodable, Sendable {
            case pending, claimed, admitted, terminal, acknowledged, blocked, outcomeUnknown = "outcome-unknown"
        }
        let state: State
        let routeGeneration: Int
        let delivery: JSONValue?
        /// An outcome-unknown wake always carries its delivery, so only an unadmitted wake can be redelivered.
        var canRedeliver: Bool {
            delivery == nil && [.pending, .blocked].contains(state)
        }
    }
    let taskId: String
    let homeId: String
    let createdAt: Int
    let updatedAt: Int
    let intent: Intent
    /// The worker's name, else the brief's first line; absent on an older Gateway.
    let title: String?
    let project: String?
    /// The worker chat Home delegated this task to; opened read-only from the task.
    let workerSessionId: String?
    let target: String
    let lifecycle: HomeTaskLifecycle
    /// Stop and steer are fenced by this operation ID alone.
    let operationId: String?
    let spend: HomeTaskSpendDTO?
    let terminalEvidence: Terminal?
    let wake: Wake?
    /// The worker's current model, read by the Gateway; absent on an older Gateway.
    let workerModel: ModelRef?
    let subagents: Subagents?
    let subagentRuns: SubagentRuns?

    /// Subagent launches the task admitted; `stoppedAtEnd` is nil when the Gateway cannot prove it.
    struct Subagents: Decodable, Equatable, Sendable {
        let started: Int
        let stoppedAtEnd: Int?
    }
    /// The worker's live runs, newest first, at most 20 of `total`. Empty once the task settles.
    struct SubagentRuns: Decodable, Equatable, Sendable {
        struct Run: Decodable, Equatable, Sendable, Identifiable {
            let runId: String
            let agent: String
            /// The run's own lifecycle state, shown as the pill's label.
            let state: String
            let startedAt: String
            let lastActivityAt: String?
            var id: String { runId }
        }
        let total: Int
        let runs: [Run]
    }

    static func decode(_ value: JSONValue, taskID: String) throws -> Self {
        let task = try value.decode(Self.self)
        guard task.taskId == taskID, homeID(task.taskId), homeID(task.homeId),
              safeHomeCount(task.createdAt), safeHomeCount(task.updatedAt), task.updatedAt >= task.createdAt,
              homeText(task.intent.text, bytes: 65536), homeText(task.target, bytes: 4096),
              task.target.hasPrefix("/"), task.spend?.valid ?? true,
              task.title.map({ $0.unicodeScalars.count <= 160 && homeText($0, bytes: 640) }) ?? true,
              task.project.map({ homeText($0, bytes: 512) }) ?? true,
              task.workerSessionId.map(homeID) ?? true,
              (task.lifecycle == .terminal) == (task.terminalEvidence != nil),
              (task.lifecycle == .terminal) == (task.wake != nil),
              task.operationId.map(homeID) ?? true, task.lifecycle != .active || task.operationId != nil,
              task.wake.map({ $0.routeGeneration > 0 }) ?? true,
              task.subagents.map({ $0.started >= 0 && ($0.stoppedAtEnd ?? 0) >= 0 }) ?? true,
              task.subagentRuns.map({ $0.total >= 0 && $0.runs.count <= 20 && $0.runs.count <= $0.total }) ?? true,
              task.workerModel.map({ !$0.provider.isEmpty && !$0.id.isEmpty }) ?? true else { throw invalidHomeTask() }
        return task
    }
}

struct HomeTaskPermissionsDTO: Equatable, Sendable {
    struct Binding: Decodable, Equatable, Sendable {
        let intentDigest: String
        let target: String
        let authorizationScope: String
        let restoreEpoch: String
        var valid: Bool {
            homeText(intentDigest, bytes: 128) && homeText(target, bytes: 4096) && target.hasPrefix("/")
                && [authorizationScope, restoreEpoch].allSatisfy(homeID)
        }
    }
    struct Scope: Decodable, Equatable, Sendable, Identifiable {
        enum Kind: String, Decodable, Sendable { case allTrustedProjects = "all-trusted-projects" }
        let id: String
        let kind: Kind
        let active: Bool
        let restoreEpoch: String
        let createdAt: Int
        let revokedAt: Int?
    }
    struct Request: Decodable, Equatable, Sendable, Identifiable { let id: String; let request: Binding }
    struct Decision: Decodable, Equatable, Sendable, Identifiable {
        let id: String
        let decidedAt: Int
        let approved: Bool
        let requestId: String
        let expiresAt: Int
    }
    struct Grant: Decodable, Equatable, Sendable, Identifiable {
        enum State: String, Decodable, Sendable { case available, consumed, revoked }
        let id: String
        let decisionId: String
        let intentDigest: String
        let target: String
        let authorizationScope: String
        let restoreEpoch: String
        let expiresAt: Int
        let state: State
        var binding: Binding {
            .init(intentDigest: intentDigest, target: target, authorizationScope: authorizationScope,
                  restoreEpoch: restoreEpoch)
        }
    }
    let scopes: [Scope]
    let decisions: [Decision]
    let grants: [Grant]
    /// Requests no decision has answered, computed once during admission.
    let pendingRequests: [Request]

    private struct Wire: Decodable {
        let revision: Int
        let scopes: [Scope]
        let requests: [Request]
        let decisions: [Decision]
        let grants: [Grant]
    }

    static func decode(_ value: JSONValue) throws -> Self {
        let wire = try value.decode(Wire.self)
        let allIDs = [wire.scopes.map(\.id), wire.requests.map(\.id), wire.decisions.map(\.id), wire.grants.map(\.id)]
        // Identifiers are unique before any index is built, so the lookups below
        // cannot trap or pick an ambiguous record.
        guard wire.revision > 0, allIDs.allSatisfy({ $0.count <= 10000 && Set($0).count == $0.count && $0.allSatisfy(homeID) }) else {
            throw invalidHomeTask()
        }
        let requestsByID = Dictionary(uniqueKeysWithValues: wire.requests.map { ($0.id, $0) })
        let decisionsByID = Dictionary(uniqueKeysWithValues: wire.decisions.map { ($0.id, $0) })
        let decidedRequestIDs = Set(wire.decisions.map(\.requestId))
        guard decidedRequestIDs.count == wire.decisions.count,
              Set(wire.grants.map(\.decisionId)).count == wire.grants.count,
              wire.scopes.allSatisfy({ homeID($0.restoreEpoch) && safeHomeCount($0.createdAt)
                  && ($0.revokedAt.map { safeHomeCount($0) } ?? true) && ($0.active || $0.revokedAt != nil) }),
              wire.requests.allSatisfy({ $0.request.valid }),
              wire.decisions.allSatisfy({ decision in safeHomeCount(decision.decidedAt) && safeHomeCount(decision.expiresAt)
                  && requestsByID[decision.requestId] != nil }),
              wire.grants.allSatisfy({ grant in
                  guard grant.binding.valid, safeHomeCount(grant.expiresAt),
                        let decision = decisionsByID[grant.decisionId], decision.approved,
                        let request = requestsByID[decision.requestId] else { return false }
                  return grant.expiresAt == decision.expiresAt && grant.binding == request.request
              }) else { throw invalidHomeTask() }
        return Self(
            scopes: wire.scopes,
            decisions: wire.decisions,
            grants: wire.grants,
            pendingRequests: wire.requests.filter { !decidedRequestIDs.contains($0.id) }
        )
    }
}

private func safeHomeCount(_ value: Int) -> Bool { value >= 0 && value <= 9_007_199_254_740_991 }
private func homeText(_ value: String, bytes: Int) -> Bool { !value.isEmpty && !value.contains("\0") && value.utf8.count <= bytes }
private func homeID(_ value: String) -> Bool {
    value.range(of: "^[A-Za-z0-9][A-Za-z0-9._-]{0,159}$", options: .regularExpression) != nil
}
private func invalidHomeTask() -> GatewayFailure {
    GatewayFailure(code: "invalid_response", message: "Home returned invalid task or permission metadata. Reload from the Gateway.", retryable: false, details: nil)
}

/// The task rows' and detail's derived text: one title rule and one state pill,
/// so the list and the detail name a task the same way.
enum HomeTaskPresentation {
    /// The worker's name, else the brief's first non-empty line, else the project.
    static func title(title: String?, briefText: String?, project: String?) -> String {
        if let title, !title.isEmpty { return title }
        if let line = briefText?.split(whereSeparator: \.isNewline).map({ $0.trimmingCharacters(in: .whitespaces) }).first(where: { !$0.isEmpty }) {
            return String(line.prefix(80))
        }
        return project ?? "Untitled task"
    }

    /// Active, Pending, Stopped (interrupted), or Finished with the outcome named.
    static func stateLabel(lifecycle: HomeTaskLifecycle, outcome: HomeTaskOutcome?) -> String {
        switch lifecycle {
        case .pending: return "Pending"
        case .active: return "Active"
        case .terminal:
            if outcome == .interrupted { return "Stopped" }
            return "Finished · \((outcome?.rawValue ?? "unknown").replacingOccurrences(of: "-", with: " ").capitalized)"
        }
    }
}
