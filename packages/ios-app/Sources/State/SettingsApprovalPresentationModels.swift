import Foundation
import TronMobileCore

/// Compact canonical tool fact, not a cached approval. Opening it re-reads the owner.
struct SettingsApprovalReference: Equatable, Hashable, Sendable {
    let requestID: String
    let changeIDs: [String]

    init(requestID: String, changeIDs: [String]) {
        self.requestID = requestID; self.changeIDs = changeIDs
    }

}

struct SettingsApprovalOutcome: Decodable, Equatable, Sendable, Identifiable {
    struct Requester: Decodable, Equatable, Sendable {
        let kind: String
        let taskId: String?
        var label: String {
            switch kind {
            case "home": "Home"
            case "worker": "Worker"
            case "ui": "You"
            case "agent": "Agent"
            default: kind
            }
        }
    }
    struct Item: Decodable, Equatable, Sendable {
        let key: String
        let label: String
        let qualifiers: [String: String]?
        let layer: String
        let before: String?
        let after: String?
        let redacted: Bool?
    }
    struct Action: Decodable, Equatable, Sendable {
        let subject: String
        let title: String
        let summary: String?
    }
    let requestId: String
    let status: String
    let requester: Requester
    let target: SettingsApprovalRequest.Target
    let createdAt: String
    let decidedAt: String?
    let reason: String?
    let failure: String?
    let items: [Item]
    let action: Action?
    var id: String { requestId }
    var title: String {
        switch status {
        case "approved": "Applied"
        case "declined": "Declined"
        case "expired": "Expired"
        case "superseded": "Superseded"
        case "failed": "Failed"
        default: "Outcome unavailable"
        }
    }
    var itemCount: Int { max(1, items.count) }
    static let terminalStatuses: Set<String> = ["approved", "declined", "expired", "superseded", "failed"]

    /// Only an authoritative decision receipt supplies this status. No tap or
    /// transport failure is treated as proof that a change applied or failed.
    init(request: SettingsApprovalRequest, status: String) {
        requestId = request.requestId; self.status = status
        requester = Requester(kind: request.actor.kind, taskId: request.actor.taskId)
        target = request.target; createdAt = request.createdAt; decidedAt = nil
        reason = request.reason; failure = nil
        items = request.changes.map { Item(key: $0.key, label: $0.label, qualifiers: $0.qualifiers,
            layer: $0.layer, before: $0.display?.before, after: $0.display?.after, redacted: $0.redacted) }
        action = request.action.map { Action(subject: $0.subject, title: $0.title, summary: nil) }
    }
}

/// Unknown versions and malformed envelopes stay in the ordinary context viewer.
struct SettingsApprovalOutcomeMessage: Equatable, Sendable {
    private struct Payload: Decodable {
        let version: Int
        let eventId: String
        let requests: [SettingsApprovalOutcome]
    }
    let eventID: String
    let requests: [SettingsApprovalOutcome]
    let raw: JSONValue

    init?(details: JSONValue?) {
        guard let details, let payload = try? details.decode(Payload.self), payload.version == 1,
              !payload.eventId.isEmpty, !payload.requests.isEmpty,
              Set(payload.requests.map(\.requestId)).count == payload.requests.count,
              payload.requests.allSatisfy({ !$0.requestId.isEmpty && SettingsApprovalOutcome.terminalStatuses.contains($0.status) }) else { return nil }
        eventID = payload.eventId; requests = payload.requests; raw = details
    }
    var title: String {
        let statuses = Set(requests.map(\.status))
        return statuses.count == 1 ? requests[0].title : "Outcomes"
    }
    var itemCount: Int { requests.reduce(0) { $0 + $1.itemCount } }
}

enum SettingsApprovalSelection: Equatable, Identifiable {
    case request(SettingsApprovalReference)
    case session(String)
    case outcomes(SettingsApprovalOutcomeMessage)

    var id: String {
        switch self {
        case .request(let value): "request:\(value.requestID)"
        case .session(let sessionID): "session:\(sessionID)"
        case .outcomes(let value): "outcomes:\(value.eventID)"
        }
    }
}
