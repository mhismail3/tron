import Foundation

enum AutomationActivation: String, Codable, Hashable, Sendable {
    case draft, enabled, paused, completed, blocked
}

enum AutomationRunState: String, Codable, Hashable, Sendable {
    case queued, waiting, admitting, running, cancelling
    case succeeded, failed, cancelled, skipped
    case outcomeUnknown
}

struct GatewayAutomationTrigger: Codable, Hashable, Sendable {
    let kind: String
    let at: String?
    let everySeconds: Int?
    let anchorAt: String?
    let timezone: String?
    let localTime: String?
    let weekdays: [Int]?
}

struct GatewayAutomationRunSummary: Codable, Hashable, Sendable {
    let runId: String
    let state: AutomationRunState
    let scheduledFor: String
    let startedAt: String?
    let terminalAt: String?
    let reason: String?
}

struct GatewayAutomationSummary: Codable, Hashable, Identifiable, Sendable {
    let id: String
    let revision: Int
    let stateRevision: Int
    let name: String
    let activation: AutomationActivation
    let actionKind: String
    let targetSessionId: String
    let trigger: GatewayAutomationTrigger
    let nextOccurrenceAt: String?
    let currentRun: GatewayAutomationRunSummary?
    let lastRun: GatewayAutomationRunSummary?
    let consecutiveFailureCount: Int
    let blockedReason: String?
    let createdAt: String
    let updatedAt: String
}

struct GatewayAutomationPage: Decodable, Sendable {
    let catalogRevision: Int
    let items: [GatewayAutomationSummary]
    let nextCursor: String?

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let revision = try values.decode(Int.self, forKey: .catalogRevision)
        let items = try values.decode([GatewayAutomationSummary].self, forKey: .items)
        let nextCursor = try values.decodeIfPresent(String.self, forKey: .nextCursor)
        guard revision >= 0,
              items.count <= AutomationAdmissionPolicy.maximumPageCount,
              Set(items.map(\.id)).count == items.count,
              items.allSatisfy(AutomationAdmissionPolicy.admits),
              nextCursor.map({ !$0.isEmpty && $0.utf8.count <= 64 }) ?? true else {
            throw DecodingError.dataCorruptedError(
                forKey: .items,
                in: values,
                debugDescription: "Automation page is invalid"
            )
        }
        catalogRevision = revision
        self.items = items
        self.nextCursor = nextCursor
    }

    private enum CodingKeys: String, CodingKey { case catalogRevision, items, nextCursor }
}

struct AutomationChanged: Decodable, Hashable, Sendable {
    let catalogRevision: Int
    let automationId: String?

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let revision = try values.decode(Int.self, forKey: .catalogRevision)
        let automationId = try values.decodeIfPresent(String.self, forKey: .automationId)
        guard revision >= 0,
              automationId.map(AutomationAdmissionPolicy.opaqueID) ?? true else {
            throw DecodingError.dataCorruptedError(
                forKey: .catalogRevision,
                in: values,
                debugDescription: "Automation invalidation is invalid"
            )
        }
        catalogRevision = revision
        self.automationId = automationId
    }

    private enum CodingKeys: String, CodingKey { case catalogRevision, automationId }
}

enum AutomationAdmissionPolicy {
    static let capability = "automations.v1"
    static let maximumPageCount = 100
    static let maximumRetainedCount = 1_024
    static let maximumAggregateBytes = 2 * 1_048_576

    static func admits(_ summary: GatewayAutomationSummary) -> Bool {
        guard opaqueID(summary.id),
              summary.revision >= 1,
              summary.stateRevision >= 1,
              bounded(summary.name, maximum: 256),
              ["sessionPrompt", "notification"].contains(summary.actionKind),
              sessionID(summary.targetSessionId),
              admits(summary.trigger),
              summary.consecutiveFailureCount >= 0,
              summary.blockedReason.map({ bounded($0, maximum: 256) }) ?? true,
              GatewayTimestamp.parse(summary.createdAt) != nil,
              GatewayTimestamp.parse(summary.updatedAt) != nil,
              summary.nextOccurrenceAt.map({ GatewayTimestamp.parse($0) != nil }) ?? true,
              summary.currentRun.map(admits) ?? true,
              summary.lastRun.map(admits) ?? true else { return false }
        return true
    }

    static func admits(_ run: GatewayAutomationRunSummary) -> Bool {
        opaqueID(run.runId)
            && GatewayTimestamp.parse(run.scheduledFor) != nil
            && (run.startedAt.map({ GatewayTimestamp.parse($0) != nil }) ?? true)
            && (run.terminalAt.map({ GatewayTimestamp.parse($0) != nil }) ?? true)
            && (run.reason.map({ bounded($0, maximum: 256) }) ?? true)
    }

    static func admits(_ trigger: GatewayAutomationTrigger) -> Bool {
        switch trigger.kind {
        case "once":
            return trigger.at.map({ GatewayTimestamp.parse($0) != nil }) == true
                && trigger.everySeconds == nil && trigger.anchorAt == nil
                && trigger.timezone == nil && trigger.localTime == nil && trigger.weekdays == nil
        case "interval":
            return trigger.at == nil
                && trigger.everySeconds.map({ (60...(365 * 24 * 60 * 60)).contains($0) }) == true
                && trigger.anchorAt.map({ GatewayTimestamp.parse($0) != nil }) == true
                && trigger.timezone == nil && trigger.localTime == nil && trigger.weekdays == nil
        case "calendar":
            guard trigger.at == nil, trigger.everySeconds == nil, trigger.anchorAt == nil,
                  let timezone = trigger.timezone, bounded(timezone, maximum: 128),
                  let localTime = trigger.localTime,
                  localTime.range(of: #"^(?:[01]\d|2[0-3]):[0-5]\d$"#, options: .regularExpression) != nil,
                  let weekdays = trigger.weekdays,
                  (1...7).contains(weekdays.count),
                  Set(weekdays).count == weekdays.count,
                  weekdays.allSatisfy({ (1...7).contains($0) }) else { return false }
            return true
        default:
            return false
        }
    }

    static func opaqueID(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 64 && value.unicodeScalars.allSatisfy {
            CharacterSet.alphanumerics.contains($0) || "-_".unicodeScalars.contains($0)
        }
    }

    private static func sessionID(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 200 && value.unicodeScalars.allSatisfy {
            CharacterSet.alphanumerics.contains($0) || "-_:".unicodeScalars.contains($0)
        }
    }

    private static func bounded(_ value: String, maximum: Int) -> Bool {
        !value.isEmpty && value.utf8.count <= maximum
            && value.unicodeScalars.allSatisfy { !CharacterSet.controlCharacters.contains($0) }
    }
}
