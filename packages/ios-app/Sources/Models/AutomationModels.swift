import Foundation

// Gateway-owned automation projections. These are disposable iOS values; the
// Gateway remains the authority for definitions, occurrences, and run state.
enum AutomationActivation: String, Codable, Hashable, Sendable, CaseIterable {
    case draft, enabled, paused, completed, blocked
    var label: String { rawValue == "enabled" ? "Active" : rawValue.replacingOccurrences(of: "_", with: " ").capitalized }
}

enum AutomationRunState: String, Codable, Hashable, Sendable {
    case queued, waiting, admitting, running, cancelling
    case succeeded, failed, cancelled, skipped, outcomeUnknown
    var isTerminal: Bool { ["succeeded", "failed", "cancelled", "skipped", "outcomeUnknown"].contains(rawValue) }
    var label: String { rawValue == "outcomeUnknown" ? "Needs attention" : rawValue.capitalized }
}

enum AutomationActionKind: String, Codable, Hashable, Sendable, CaseIterable {
    case sessionPrompt, notification
    var label: String { self == .sessionPrompt ? "Prompt" : "Notification" }
    var icon: String { self == .sessionPrompt ? "text.bubble" : "bell" }
}

enum AutomationTriggerKind: String, Codable, Hashable, Sendable, CaseIterable {
    case once, interval, calendar
    var label: String { rawValue.capitalized }
}

struct GatewayAutomationTrigger: Codable, Hashable, Sendable {
    let kind: String
    let at: String?
    let everySeconds: Int?
    let anchorAt: String?
    let timezone: String?
    let localTime: String?
    let weekdays: [Int]?

    var typedKind: AutomationTriggerKind? { AutomationTriggerKind(rawValue: kind) }
    init(kind: String, at: String? = nil, everySeconds: Int? = nil, anchorAt: String? = nil, timezone: String? = nil, localTime: String? = nil, weekdays: [Int]? = nil) {
        self.kind = kind; self.at = at; self.everySeconds = everySeconds; self.anchorAt = anchorAt; self.timezone = timezone; self.localTime = localTime; self.weekdays = weekdays
    }
    var summary: String {
        switch kind {
        case "once": return at.map { "Once · \($0)" } ?? "Once"
        case "interval":
            guard let seconds = everySeconds else { return "Repeating" }
            let unit = seconds % 86_400 == 0 ? "day" : seconds % 3_600 == 0 ? "hour" : "minute"
            let amount = unit == "day" ? seconds / 86_400 : unit == "hour" ? seconds / 3_600 : seconds / 60
            return "Every \(amount) \(unit)\(amount == 1 ? "" : "s")"
        case "calendar": return "Selected days at \(localTime ?? "")"
        default: return "Schedule"
        }
    }
}

struct GatewayAutomationRunSummary: Codable, Hashable, Identifiable, Sendable {
    let runId: String
    let state: AutomationRunState
    let scheduledFor: String
    let startedAt: String?
    let terminalAt: String?
    let reason: String?
    let preAdmissionAttemptCount: Int?
    let notificationAdmissionStatus: String?
    var id: String { runId }
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

    var typedActionKind: AutomationActionKind? { AutomationActionKind(rawValue: actionKind) }
    var isAttentionRequired: Bool { activation == .blocked || currentRun?.state == .outcomeUnknown || consecutiveFailureCount > 0 }
}

struct GatewayAutomationAction: Codable, Hashable, Sendable {
    init(kind: String, text: String? = nil, message: String? = nil, resourceInvocation: ComposerResourceInvocation? = nil) {
        self.kind = kind; self.text = text; self.message = message; self.resourceInvocation = resourceInvocation
    }
    let kind: String
    let text: String?
    let message: String?
    let resourceInvocation: ComposerResourceInvocation?

    var typedKind: AutomationActionKind? { AutomationActionKind(rawValue: kind) }
    var content: String { text ?? message ?? "" }
}

struct GatewayAutomationRecord: Codable, Hashable, Identifiable, Sendable {
    let schemaVersion: Int
    let id: String
    let revision: Int
    let stateRevision: Int
    let name: String
    let description: String?
    let activation: AutomationActivation
    let createdAt: String
    let updatedAt: String
    let provenance: GatewayAutomationProvenance
    let targetSessionId: String
    let trigger: GatewayAutomationTrigger
    let misfirePolicy: String
    let overlapPolicy: String
    let executionDeadlineSeconds: Int
    let action: GatewayAutomationAction
    let nextOccurrenceAt: String?
    let currentRun: GatewayAutomationRun?
    let lastRun: GatewayAutomationRun?
    let consecutiveFailureCount: Int
    let blockedReason: String?
    let history: [GatewayAutomationRun]
}

extension GatewayAutomationTrigger {
    enum CodingKeys: String, CodingKey { case kind, at, everySeconds, anchorAt, timezone, localTime, weekdays }
    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self); try values.encode(kind, forKey: .kind)
        switch kind { case "once": try values.encodeIfPresent(at, forKey: .at); case "interval": try values.encodeIfPresent(everySeconds, forKey: .everySeconds); try values.encodeIfPresent(anchorAt, forKey: .anchorAt); case "calendar": try values.encodeIfPresent(timezone, forKey: .timezone); try values.encodeIfPresent(localTime, forKey: .localTime); try values.encodeIfPresent(weekdays, forKey: .weekdays); default: break }
    }
}
extension GatewayAutomationAction {
    enum CodingKeys: String, CodingKey { case kind, text, message, resourceInvocation }
    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self); try values.encode(kind, forKey: .kind)
        if kind == "sessionPrompt" { try values.encodeIfPresent(text, forKey: .text); try values.encodeIfPresent(resourceInvocation, forKey: .resourceInvocation) }
        else { try values.encodeIfPresent(message, forKey: .message) }
    }
}

struct GatewayAutomationProvenance: Codable, Hashable, Sendable {
    let kind: String
    let sessionId: String?
    let sourceId: String?
}

struct GatewayAutomationRun: Codable, Hashable, Identifiable, Sendable {
    let runId: String
    let occurrenceId: String
    let manual: Bool?
    let automationRevision: Int
    let scheduledFor: String
    let triggerSnapshot: GatewayAutomationTrigger
    let actionSnapshot: GatewayAutomationAction
    let state: AutomationRunState
    let createdAt: String
    let reason: String?
    let claimedAt: String?
    let startedAt: String?
    let terminalAt: String?
    let retryAt: String?
    let preAdmissionAttemptCount: Int
    let hostEpoch: String?
    let claimId: String?
    let operationId: String?
    let invocationId: String?
    let assistantCompletionId: String?
    let notificationAdmissionStatus: String?
    let error: GatewayAutomationError?
    let resolution: GatewayAutomationResolution?
    var id: String { runId }
}

struct GatewayAutomationError: Codable, Hashable, Sendable { let code: String; let message: String; let retryable: Bool }
struct GatewayAutomationResolution: Codable, Hashable, Sendable { let outcome: String; let resolvedAt: String; let provenance: GatewayAutomationProvenance }

struct GatewayAutomationPage: Decodable, Sendable {
    let catalogRevision: Int
    let items: [GatewayAutomationSummary]
    let nextCursor: String?

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        catalogRevision = try values.decode(Int.self, forKey: .catalogRevision)
        items = try values.decode([GatewayAutomationSummary].self, forKey: .items)
        nextCursor = try values.decodeIfPresent(String.self, forKey: .nextCursor)
        guard catalogRevision >= 0, items.count <= AutomationAdmissionPolicy.maximumPageCount,
              Set(items.map(\.id)).count == items.count,
              items.allSatisfy(AutomationAdmissionPolicy.admits),
              nextCursor.map({ !$0.isEmpty && $0.utf8.count <= 64 }) ?? true else {
            throw DecodingError.dataCorruptedError(forKey: .items, in: values, debugDescription: "Automation page is invalid")
        }
    }
    private enum CodingKeys: String, CodingKey { case catalogRevision, items, nextCursor }
}

struct AutomationChanged: Decodable, Hashable, Sendable {
    let catalogRevision: Int
    let automationId: String?
    private enum CodingKeys: String, CodingKey { case catalogRevision, automationId }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        catalogRevision = try values.decode(Int.self, forKey: .catalogRevision)
        automationId = try values.decodeIfPresent(String.self, forKey: .automationId)
        guard catalogRevision >= 0 else { throw DecodingError.dataCorruptedError(forKey: .catalogRevision, in: values, debugDescription: "Invalid automation revision") }
    }
}

struct GatewayAutomationStatus: Codable, Hashable, Sendable {
    let ready: Bool
    let degraded: Bool
    let automationCount: Int
    let aggregateBytes: Int
    let malformedRecordCount: Int
    let catalogRevision: Int
}

struct GatewayAutomationOccurrence: Codable, Hashable, Identifiable, Sendable {
    let kind: String
    let automationId: String
    let automationRevision: Int
    let occurrenceId: String
    let scheduledFor: String
    let dayStart: String?
    let firstAt: String?
    let lastAt: String?
    let count: Int?
    var id: String { occurrenceId }
    var isSeries: Bool { kind == "series" }
}

struct GatewayAutomationTimelinePage: Codable, Hashable, Sendable {
    let catalogRevision: Int
    let items: [GatewayAutomationOccurrence]
    let nextCursor: String?
}

struct GatewayAutomationPreview: Codable, Hashable, Sendable { let occurrences: [String] }
struct GatewayAutomationRuns: Codable, Hashable, Sendable { let runs: [GatewayAutomationRunSummary] }
struct GatewayAutomationDeleteResponse: Codable, Hashable, Sendable { let deleted: Bool }

enum AutomationAdmissionPolicy {
    static let capability = "automations.v1"
    static let timelineCapability = "automations.timeline.v1"
    static let maximumPageCount = 100
    static let maximumTimelinePageCount = 200
    static let maximumRetainedCount = 1_024
    static let maximumAggregateBytes = 2 * 1_048_576
    static func admits(_ summary: GatewayAutomationSummary) -> Bool {
        !summary.id.isEmpty && summary.revision >= 1 && summary.stateRevision >= 1
            && !summary.name.isEmpty && summary.name.utf8.count <= 256
            && AutomationActionKind(rawValue: summary.actionKind) != nil
            && !summary.targetSessionId.isEmpty && summary.consecutiveFailureCount >= 0
            && admits(summary.trigger)
    }
    static func admits(_ trigger: GatewayAutomationTrigger) -> Bool {
        switch trigger.kind {
        case "once": return trigger.at != nil && trigger.everySeconds == nil && trigger.timezone == nil
        case "interval": return trigger.everySeconds.map { (60...31_536_000).contains($0) } == true && trigger.anchorAt != nil
        case "calendar":
            let validTime = trigger.localTime?.range(of: #"^(?:[01]\d|2[0-3]):[0-5]\d$"#, options: .regularExpression) != nil
            return trigger.timezone.flatMap(TimeZone.init(identifier:)) != nil && validTime
                && trigger.weekdays?.isEmpty == false && trigger.weekdays?.allSatisfy { (1...7).contains($0) } == true
        default: return false
        }
    }
    static func admits(_ run: GatewayAutomationRunSummary) -> Bool { !run.runId.isEmpty && !run.scheduledFor.isEmpty }
}

struct AutomationDashboardProfile: Identifiable, Hashable, Sendable {
    let id: String
    let label: String
    let state: DashboardServerConnectionState
    let capabilities: Set<String>
}

struct AutomationProfileCatalog: Identifiable, Hashable, Sendable {
    let profile: AutomationDashboardProfile
    var catalogRevision: Int = 0
    var summaries: [GatewayAutomationSummary] = []
    var failure: String?
    var isStale: Bool { state != .connected }
    var state: DashboardServerConnectionState { profile.state }
    var id: String { profile.id }
}

struct AutomationTimelineItem: Identifiable, Hashable, Sendable {
    let profileID: String
    let occurrence: GatewayAutomationOccurrence
    var id: String { "\(profileID):\(occurrence.occurrenceId)" }
}

struct AutomationAgendaDay: Identifiable, Hashable, Sendable {
    let date: Date
    let items: [AutomationTimelineItem]
    var id: Date { date }
}
