import Foundation
import TronMobileCore

extension HomeTaskSummarySpend {
    var valid: Bool {
        HomeMemoryEvidence.isDigest(sourceDigest) && safeHomeCount(inputTokens) && safeHomeCount(outputTokens)
            && (cacheReadTokens == nil) == (cacheWriteTokens == nil)
            && [cacheReadTokens, cacheWriteTokens].compactMap { $0 }.allSatisfy(safeHomeCount)
    }
}

extension HomeTaskCheckin {
    var valid: Bool {
        [id, taskId, sessionId, operationId].allSatisfy(homeID)
            && GatewayTimestamp.parse(at) != nil && homeText(step, bytes: 256)
            && homeText(done, bytes: 512) && homeText(next, bytes: 512)
            && (blocker.map { homeText($0, bytes: 512) } ?? true)
            && (needsAttention != true || blocker != nil)
            && [refs?.branch, refs?.commit, refs?.issue].compactMap { $0 }.allSatisfy { homeText($0, bytes: 256) }
    }
    static func valid(_ values: [Self]) -> Bool {
        values.count <= 3 && values.allSatisfy(\.valid) && Set(values.map(\.id)).count == values.count
    }
}

extension HomeTaskSummary: Identifiable {
    package var id: String { taskId }
    var valid: Bool {
        homeID(taskId) && safeHomeCount(createdAt) && safeHomeCount(updatedAt) && updatedAt >= createdAt
            && homeDisplay(title: title, project: project)
            && (sessionId.value.map(homeID) ?? true)
            && HomeTaskCheckin.valid(checkins)
            && homeText(target, bytes: 4096)
            && target.hasPrefix("/") && ((lifecycle == .terminal) == (outcome != .null)) && (spend.value?.valid ?? true)
    }
}

extension HomeTaskPage {
    static func validated(_ value: JSONValue) throws -> Self {
        let page = try value.decodeWire(Self.decode)
        guard page.items.count <= 50, page.items.allSatisfy(\.valid), Set(page.items.map(\.id)).count == page.items.count,
              zip(page.items, page.items.dropFirst()).allSatisfy({ $0.createdAt > $1.createdAt || ($0.createdAt == $1.createdAt && $0.id < $1.id) }),
              page.nextCursor.map({ homeText($0, bytes: 1024) && !page.items.isEmpty }) ?? true else { throw invalidHomeTask() }
        return page
    }
}

extension HomeTaskWake {
    var canRedeliver: Bool {
        delivery == .null && [.pending, .blocked].contains(state)
    }
}

extension HomeTaskStatusResult {
    static func validated(_ value: JSONValue, taskID: String) throws -> Self {
        let task = try value.decodeWire(Self.decode)
        guard task.taskId == taskID, homeID(task.taskId), homeID(task.homeId),
              safeHomeCount(task.createdAt), safeHomeCount(task.updatedAt), task.updatedAt >= task.createdAt,
              homeText(task.intent.text, bytes: 65536), homeText(task.target, bytes: 4096),
              task.target.hasPrefix("/"), task.spend.value?.valid ?? true,
              homeDisplay(title: task.title, project: task.project),
              HomeTaskCheckin.valid(task.checkins),
              task.sessionId.value.map(homeID) ?? true,
              (task.lifecycle == .terminal) == (task.terminalEvidence != .null),
              (task.lifecycle == .terminal) == (task.wake != .null),
              task.operationId.value.map(homeID) ?? true, task.lifecycle != .active || task.operationId != .null,
              task.wake.value.map({ $0.routeGeneration > 0 }) ?? true,
              task.subagents.started >= 0 && (task.subagents.stoppedAtEnd.value ?? 0) >= 0,
              task.subagentRuns.total >= 0 && task.subagentRuns.runs.count <= 20 && task.subagentRuns.runs.count <= task.subagentRuns.total,
              task.workerModel.value.map({ !$0.provider.isEmpty && !$0.id.isEmpty }) ?? true else { throw invalidHomeTask() }
        return task
    }
}

extension HomeTaskWorkerModel {
    var displayName: String { ModelDisplayFormatting.model(id) }
}

extension HomeTaskSubagentRun: Identifiable {
    package var id: String { runId }
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
    let needsReconfirmation: Bool
    let scopes: [Scope]
    let decisions: [Decision]
    let grants: [Grant]

    private struct Wire: Decodable {
        let revision: Int
        let needsReconfirmation: Bool?
        let scopes: [Scope]
        let requests: [Request]
        let decisions: [Decision]
        let grants: [Grant]
    }

    static func decode(_ value: JSONValue) throws -> Self {
        let wire = try value.decode(Wire.self)
        let allIDs = [wire.scopes.map(\.id), wire.requests.map(\.id), wire.decisions.map(\.id), wire.grants.map(\.id)]
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
            needsReconfirmation: wire.needsReconfirmation ?? false,
            scopes: wire.scopes,
            decisions: wire.decisions,
            grants: wire.grants
        )
    }
}

private func safeHomeCount(_ value: Int) -> Bool { value >= 0 && value <= 9_007_199_254_740_991 }
private func homeText(_ value: String, bytes: Int) -> Bool { !value.isEmpty && !value.contains("\0") && value.utf8.count <= bytes }
private func homeDisplay(title: String, project: String) -> Bool {
    (title.isEmpty || (title.unicodeScalars.count <= 160 && homeText(title, bytes: 640)))
        && (project.isEmpty || homeText(project, bytes: 512))
}
private func homeID(_ value: String) -> Bool {
    value.range(of: "^[A-Za-z0-9][A-Za-z0-9._-]{0,159}$", options: .regularExpression) != nil
}
private func invalidHomeTask() -> GatewayFailure {
    GatewayFailure(code: "invalid_response", message: "Home returned invalid task or permission metadata. Reload from the Gateway.", retryable: false, details: nil)
}

enum HomeTaskPresentation {
    static func spendText(_ spend: HomeTaskSummarySpend) -> String {
        func count(_ value: Int) -> String { value.formatted(.number.notation(.compactName)) }
        guard let read = spend.cacheReadTokens, let write = spend.cacheWriteTokens else {
            return "\(count(spend.inputTokens)) in incl. cached · \(count(spend.outputTokens)) out"
        }
        return (["\(count(spend.inputTokens)) in", "\(count(read)) cached"] + (write > 0 ? ["\(count(write)) cache write"] : [])
            + ["\(count(spend.outputTokens)) out"]).joined(separator: " · ")
    }

    static func checkinText(_ checkin: HomeTaskCheckin) -> String {
        [HomeSheetTime.relative(checkin.at), checkin.step, "Done: \(checkin.done)", "Next: \(checkin.next)",
         checkin.blocker.map { "Blocker: \($0)" }].compactMap { $0 }.joined(separator: "\n")
    }

    static func title(title: String, briefText: String?, project: String) -> String {
        if !title.isEmpty { return title }
        if let line = briefText?.split(whereSeparator: \.isNewline).map({ $0.trimmingCharacters(in: .whitespaces) }).first(where: { !$0.isEmpty }) {
            return String(line.prefix(80))
        }
        return project.isEmpty ? "Untitled task" : project
    }

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
