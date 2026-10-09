import Foundation
import TronMobileCore

enum HomeTaskLifecycle: String, Decodable, Sendable { case pending, active, terminal }
enum HomeTaskOutcome: String, Decodable, Sendable { case progress, needsInput = "needs-input", final, limited, interrupted, unknown }

struct HomeTaskSpendDTO: Decodable, Equatable, Sendable {
    let sourceDigest: String
    let inputTokens: Int
    let outputTokens: Int
    let knownCostUSD: Double?
    let pricingProvenance: String?
    let unpriced: Bool
    var valid: Bool {
        HomeMemoryPageDTO.isDigest(sourceDigest) && safeHomeCount(inputTokens) && safeHomeCount(outputTokens)
            && (knownCostUSD.map { $0.isFinite && $0 >= 0 } ?? true)
            && ((knownCostUSD == nil) == (pricingProvenance == nil))
            && (pricingProvenance.map { homeText($0, bytes: 512) } ?? true)
    }
}

struct HomeTaskPageDTO: Decodable, Equatable, Sendable {
    struct Row: Decodable, Equatable, Sendable, Identifiable {
        let taskId: String
        let createdAt: Int
        let updatedAt: Int
        let title: String
        let target: String
        let lifecycle: HomeTaskLifecycle
        let outcome: HomeTaskOutcome?
        let spend: HomeTaskSpendDTO?
        let attention: Bool
        let pendingGrant: Bool
        var id: String { taskId }
        var valid: Bool {
            homeID(taskId) && safeHomeCount(createdAt) && safeHomeCount(updatedAt) && updatedAt >= createdAt
                && title.unicodeScalars.count <= 160 && homeText(title, bytes: 640) && homeText(target, bytes: 4096)
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
    struct Intent: Decodable, Equatable, Sendable { let revision: Int; let text: String }
    struct Terminal: Decodable, Equatable, Sendable {
        let outcome: HomeTaskOutcome
        let reason: String
    }
    struct Wake: Decodable, Equatable, Sendable {
        enum State: String, Decodable, Sendable {
            case pending, claimed, admitted, terminal, acknowledged, blocked
            case cancelledBeforeAdmission = "cancelled-before-admission", outcomeUnknown = "outcome-unknown"
        }
        let state: State
        let routeGeneration: Int
        let delivery: JSONValue?
        var canRedeliver: Bool {
            delivery == nil && [.pending, .blocked, .cancelledBeforeAdmission, .outcomeUnknown].contains(state)
        }
    }
    let taskId: String
    let homeId: String
    let createdAt: Int
    let updatedAt: Int
    let intent: Intent
    let target: String
    let lifecycle: HomeTaskLifecycle
    let operationId: String?
    let controllerGeneration: Int?
    let spend: HomeTaskSpendDTO?
    let terminalEvidence: Terminal?
    let wake: Wake?

    static func decode(_ value: JSONValue, taskID: String) throws -> Self {
        let task = try value.decode(Self.self)
        guard task.taskId == taskID, homeID(task.taskId), homeID(task.homeId),
              safeHomeCount(task.createdAt), safeHomeCount(task.updatedAt), task.updatedAt >= task.createdAt,
              task.intent.revision > 0, homeText(task.intent.text, bytes: 65536), homeText(task.target, bytes: 4096),
              task.target.hasPrefix("/"), task.spend?.valid ?? true,
              (task.lifecycle == .terminal) == (task.terminalEvidence != nil),
              (task.lifecycle == .terminal) == (task.wake != nil),
              task.operationId.map(homeID) ?? true, task.controllerGeneration.map({ $0 > 0 }) ?? true,
              task.lifecycle != .active || (task.operationId != nil && task.controllerGeneration != nil),
              task.wake.map({ $0.routeGeneration > 0 }) ?? true else { throw invalidHomeTask() }
        return task
    }
}

struct HomeTaskPermissionsDTO: Equatable, Sendable {
    struct Binding: Decodable, Equatable, Sendable {
        let intentRevision: Int
        let intentDigest: String
        let target: String
        let authorizationScope: String
        let workerProfile: String
        let policyRevision: Int
        let restoreEpoch: String
        var valid: Bool {
            intentRevision > 0 && homeText(intentDigest, bytes: 128) && homeText(target, bytes: 4096) && target.hasPrefix("/")
                && [authorizationScope, workerProfile, restoreEpoch].allSatisfy(homeID) && policyRevision > 0
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
        let intentRevision: Int
        let intentDigest: String
        let target: String
        let authorizationScope: String
        let workerProfile: String
        let policyRevision: Int
        let restoreEpoch: String
        let expiresAt: Int
        let state: State
        var binding: Binding {
            .init(intentRevision: intentRevision, intentDigest: intentDigest, target: target, authorizationScope: authorizationScope,
                  workerProfile: workerProfile, policyRevision: policyRevision, restoreEpoch: restoreEpoch)
        }
    }
    let revision: Int
    let scopes: [Scope]
    let requests: [Request]
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
            revision: wire.revision,
            scopes: wire.scopes,
            requests: wire.requests,
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
