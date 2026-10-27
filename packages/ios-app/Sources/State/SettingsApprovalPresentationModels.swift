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

/// One approval request as every approval surface lays it out (#2050): the chat
/// sheet (waiting or not), push review, Changes, and the decided state reopened
/// from an outcome or history. All words are Gateway text; `exact` is the
/// request's exact identity or values, shown only behind the technical toggle.
struct SettingsApprovalReview: Equatable, Sendable {
    struct Row: Equatable, Sendable {
        let title: String
        let value: String
        let detail: String?
        let exact: JSONValue?
    }
    let requestID: String
    /// `pending` or the request's terminal status.
    let status: String
    let requester: String
    let reason: String?
    let target: SettingsApprovalRequest.Target
    let expiresAt: Date?
    let heading: String
    let rows: [Row]
    let summary: String?
    let failure: String?
    let digest: String?

    init(request: SettingsApprovalRequest) {
        requestID = request.requestId; status = "pending"; requester = request.requester
        reason = request.reason; target = request.target; expiresAt = request.expiryDate
        heading = request.action?.title ?? (request.changes.count == 1 ? "Change" : "Changes")
        rows = (request.action?.items.map { Row(title: $0.label, value: $0.value, detail: $0.detail, exact: $0.exact.map(Self.exact)) } ?? [])
            + request.changes.map { change in
                Row(title: change.label,
                    value: change.redacted == true ? "New value hidden" : change.display.map { "\($0.before) → \($0.after)" } ?? "Exact values in technical details",
                    detail: [settingsLayerLabel(change.layer), change.confirm].compactMap { $0 }.joined(separator: " · "),
                    exact: change.redacted == true ? nil : .object(["before": change.before ?? .null, "after": change.after ?? .null]))
            }
        summary = nil; failure = nil; digest = request.digest
    }

    init(outcome: SettingsApprovalOutcome) {
        requestID = outcome.requestId; status = outcome.status; requester = outcome.requester.label
        reason = outcome.reason; target = outcome.target; expiresAt = nil
        heading = outcome.action?.title ?? (outcome.items.count == 1 ? "Change" : "Changes")
        rows = outcome.items.map { item in
            Row(title: item.label, value: item.redacted == true ? "Value hidden" : "\(item.before ?? "Not set") → \(item.after ?? "Not set")",
                detail: settingsLayerLabel(item.layer), exact: nil)
        }
        summary = outcome.action?.summary; failure = outcome.failure; digest = nil
    }

    /// The decided state read back from history: the request's terminal facts.
    /// An action's fact records the exact preview the maintainer approved.
    init?(history entries: [SettingsChangeHistoryEntry]) {
        guard let first = entries.first, let requestID = first.requestId else { return nil }
        self.requestID = requestID; status = first.status
        requester = first.presentation?.actor ?? first.actor.kind.capitalized
        reason = first.reason; target = SettingsApprovalRequest.Target(kind: first.target.kind, sessionId: first.target.sessionId, cwd: first.target.cwd)
        expiresAt = nil
        if first.action == true, let preview = try? first.after?.decode(SettingsApprovalRequest.Action.Preview.self) {
            heading = preview.title
            rows = preview.items.map { Row(title: $0.label, value: $0.value, detail: $0.detail, exact: $0.exact.map(Self.exact)) }
        } else {
            heading = entries.count == 1 ? "Change" : "Changes"
            rows = entries.map { entry in
                Row(title: entry.title, value: entry.redacted == true ? "Value hidden" : entry.presentation.map { "\($0.display.before) → \($0.display.after)" } ?? "Recorded outcome",
                    detail: entry.presentation?.layer ?? settingsLayerLabel(entry.layer),
                    exact: entry.redacted == true ? nil : .object(["before": entry.before ?? .null, "after": entry.after ?? .null]))
            }
        }
        summary = nil; failure = first.failure; digest = nil
    }

    private static func exact(_ text: String) -> JSONValue {
        (try? JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))) ?? .string(text)
    }

    var isPending: Bool { status == "pending" }

    /// The status as the sheet's pill and the chip name it.
    static func statusLabel(_ status: String) -> String {
        switch status {
        case "pending": "Waiting for you"
        case "approved": "Applied"
        case "declined": "Declined"
        case "expired": "Expired"
        case "superseded": "Superseded"
        case "failed": "Failed"
        default: "Decided"
        }
    }
}
