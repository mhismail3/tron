import Foundation

private struct AutomationCodingKey: CodingKey {
    let stringValue: String
    let intValue: Int?
    init?(stringValue: String) { self.stringValue = stringValue; self.intValue = nil }
    init?(intValue: Int) { self.stringValue = String(intValue); self.intValue = intValue }
}

// Gateway-owned automation projections. These are disposable iOS values; the
// Gateway remains the authority for definitions, occurrences, and run state.
enum AutomationActivation: String, Codable, Hashable, Sendable, CaseIterable {
    case draft, enabled, paused, completed, blocked
    var label: String {
        switch self {
        case .draft: "Draft"
        case .enabled: "Active"
        case .paused: "Paused"
        case .completed: "Completed"
        case .blocked: "Needs attention"
        }
    }
}

enum AutomationRunState: String, Codable, Hashable, Sendable {
    case queued, waiting, admitting, running, cancelling
    case succeeded, failed, cancelled, skipped, outcomeUnknown
    var isTerminal: Bool { ["succeeded", "failed", "cancelled", "skipped", "outcomeUnknown"].contains(rawValue) }
    var label: String {
        switch self {
        case .queued, .waiting: "Waiting"
        case .admitting: "Starting"
        case .running: "Running"
        case .cancelling: "Cancelling"
        case .succeeded: "Succeeded"
        case .failed: "Failed"
        case .cancelled: "Cancelled"
        case .skipped: "Skipped"
        case .outcomeUnknown: "Outcome unknown"
        }
    }
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
        case "once":
            guard let at, let date = GatewayTimestamp.parse(at) else { return "Once" }
            return "Once · \(date.formatted(date: .abbreviated, time: .shortened))"
        case "interval":
            guard let seconds = everySeconds else { return "Repeating" }
            let unit: String
            let amount: Int
            if seconds.isMultiple(of: 604_800) { unit = "week"; amount = seconds / 604_800 }
            else if seconds.isMultiple(of: 86_400) { unit = "day"; amount = seconds / 86_400 }
            else if seconds.isMultiple(of: 3_600) { unit = "hour"; amount = seconds / 3_600 }
            else { unit = "minute"; amount = seconds / 60 }
            return "Every \(amount) \(unit)\(amount == 1 ? "" : "s")"
        case "calendar":
            let days = (weekdays ?? []).map(Self.weekdayLabel).joined(separator: ", ")
            return "\(days.isEmpty ? "Selected days" : days) at \(localTime ?? "")"
        default:
            return "Schedule"
        }
    }

    private static func weekdayLabel(_ isoDay: Int) -> String {
        let symbols = Calendar.current.shortWeekdaySymbols
        guard (1...7).contains(isoDay), symbols.count == 7 else { return "Day \(isoDay)" }
        return symbols[isoDay % 7]
    }
}

enum GatewayAutomationTarget: Codable, Hashable, Sendable {
    enum SessionPolicy: String, Codable, Hashable, Sendable { case newPerRun }

    case existingSession(sessionID: String)
    case workspace(cwd: String, sessionPolicy: SessionPolicy)

    var sessionID: String? {
        if case let .existingSession(sessionID) = self { return sessionID }
        return nil
    }

    var cwd: String? {
        if case let .workspace(cwd, _) = self { return cwd }
        return nil
    }

    var sessionPolicy: SessionPolicy? {
        if case let .workspace(_, sessionPolicy) = self { return sessionPolicy }
        return nil
    }

    var isWorkspace: Bool { if case .workspace = self { return true }; return false }

    var displayName: String {
        switch self {
        case let .existingSession(sessionID): return "Session \(sessionID)"
        case let .workspace(cwd, _):
            let name = URL(fileURLWithPath: cwd).lastPathComponent
            return name.isEmpty ? "Workspace" : name
        }
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: AutomationCodingKey.self)
        let keys = Set(values.allKeys.map(\.stringValue))
        let kind = try values.decode(String.self, forKey: AutomationCodingKey(stringValue: "kind")!)
        switch kind {
        case "existingSession":
            guard keys == ["kind", "sessionId"] else { throw Self.invalid() }
            let sessionID = try values.decode(String.self, forKey: AutomationCodingKey(stringValue: "sessionId")!)
            guard AutomationAdmissionPolicy.validSessionID(sessionID) else { throw Self.invalid() }
            self = .existingSession(sessionID: sessionID)
        case "workspace":
            guard keys == ["kind", "cwd", "sessionPolicy"] else { throw Self.invalid() }
            let cwd = try values.decode(String.self, forKey: AutomationCodingKey(stringValue: "cwd")!)
            let policy = try values.decode(SessionPolicy.self, forKey: AutomationCodingKey(stringValue: "sessionPolicy")!)
            guard AutomationAdmissionPolicy.validWorkspacePath(cwd) else { throw Self.invalid() }
            self = .workspace(cwd: cwd, sessionPolicy: policy)
        default:
            throw Self.invalid()
        }
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .existingSession(sessionID):
            try values.encode("existingSession", forKey: .kind)
            try values.encode(sessionID, forKey: .sessionId)
        case let .workspace(cwd, policy):
            try values.encode("workspace", forKey: .kind)
            try values.encode(cwd, forKey: .cwd)
            try values.encode(policy, forKey: .sessionPolicy)
        }
    }

    private static func invalid() -> DecodingError {
        DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "Invalid Automation target"))
    }

    private enum CodingKeys: String, CodingKey { case kind, sessionId, cwd, sessionPolicy }
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
    let target: GatewayAutomationTarget
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
    let target: GatewayAutomationTarget
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

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: AutomationCodingKey.self)
        let kind = try values.decode(String.self, forKey: AutomationCodingKey(stringValue: "kind")!)
        let keys = Set(values.allKeys.map(\.stringValue))
        switch kind {
        case "sessionPrompt":
            guard keys.isSubset(of: ["kind", "text", "resourceInvocation"]), !keys.contains("message") else { throw Self.invalid() }
            self.init(kind: kind, text: try values.decodeIfPresent(String.self, forKey: AutomationCodingKey(stringValue: "text")!), resourceInvocation: try values.decodeIfPresent(ComposerResourceInvocation.self, forKey: AutomationCodingKey(stringValue: "resourceInvocation")!))
        case "notification":
            guard keys.isSubset(of: ["kind", "message"]), !keys.contains("text") else { throw Self.invalid() }
            self.init(kind: kind, message: try values.decodeIfPresent(String.self, forKey: AutomationCodingKey(stringValue: "message")!))
        default:
            throw Self.invalid()
        }
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self); try values.encode(kind, forKey: .kind)
        if kind == "sessionPrompt" { try values.encodeIfPresent(text, forKey: .text); try values.encodeIfPresent(resourceInvocation, forKey: .resourceInvocation) }
        else { try values.encodeIfPresent(message, forKey: .message) }
    }

    private static func invalid() -> DecodingError {
        DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "Invalid Automation action"))
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
    let targetSnapshot: GatewayAutomationTarget
    let executionSessionId: String
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
        guard catalogRevision >= 0,
              automationId.map(AutomationAdmissionPolicy.opaqueID) ?? true else {
            throw DecodingError.dataCorruptedError(
                forKey: .catalogRevision,
                in: values,
                debugDescription: "Invalid automation revision"
            )
        }
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

struct GatewayAutomationOccurrence: Decodable, Hashable, Identifiable, Sendable {
    enum Kind: String, Decodable, Sendable { case occurrence, series }

    let kind: Kind
    let automationId: String
    let automationRevision: Int
    let occurrenceId: String?
    let scheduledFor: String?
    let dayStart: String?
    let firstAt: String?
    let lastAt: String?
    let count: Int?

    var id: String {
        if let occurrenceId { return occurrenceId }
        return "series:\(automationId):\(dayStart ?? firstAt ?? "invalid")"
    }
    var isSeries: Bool { kind == .series }
    var presentationTimestamp: String { scheduledFor ?? firstAt ?? "" }

    init(
        kind: Kind,
        automationId: String,
        automationRevision: Int,
        occurrenceId: String? = nil,
        scheduledFor: String? = nil,
        dayStart: String? = nil,
        firstAt: String? = nil,
        lastAt: String? = nil,
        count: Int? = nil
    ) {
        self.kind = kind
        self.automationId = automationId
        self.automationRevision = automationRevision
        self.occurrenceId = occurrenceId
        self.scheduledFor = scheduledFor
        self.dayStart = dayStart
        self.firstAt = firstAt
        self.lastAt = lastAt
        self.count = count
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try values.decode(Kind.self, forKey: .kind)
        let automationId = try values.decode(String.self, forKey: .automationId)
        let automationRevision = try values.decode(Int.self, forKey: .automationRevision)
        let occurrenceId = try values.decodeIfPresent(String.self, forKey: .occurrenceId)
        let scheduledFor = try values.decodeIfPresent(String.self, forKey: .scheduledFor)
        let dayStart = try values.decodeIfPresent(String.self, forKey: .dayStart)
        let firstAt = try values.decodeIfPresent(String.self, forKey: .firstAt)
        let lastAt = try values.decodeIfPresent(String.self, forKey: .lastAt)
        let count = try values.decodeIfPresent(Int.self, forKey: .count)
        let commonIsValid = AutomationAdmissionPolicy.opaqueID(automationId) && automationRevision >= 1
        let shapeIsValid: Bool = switch kind {
        case .occurrence:
            occurrenceId.map(AutomationAdmissionPolicy.opaqueID) == true
                && scheduledFor.flatMap(GatewayTimestamp.parse) != nil
                && dayStart == nil && firstAt == nil && lastAt == nil && count == nil
        case .series:
            occurrenceId == nil && scheduledFor == nil
                && dayStart.flatMap(GatewayTimestamp.parse) != nil
                && firstAt.flatMap(GatewayTimestamp.parse) != nil
                && lastAt.flatMap(GatewayTimestamp.parse) != nil
                && count.map { $0 > 12 && $0 <= 10_080 } == true
                && (firstAt.flatMap(GatewayTimestamp.parse) ?? .distantFuture)
                    <= (lastAt.flatMap(GatewayTimestamp.parse) ?? .distantPast)
        }
        guard commonIsValid, shapeIsValid else {
            throw DecodingError.dataCorruptedError(
                forKey: .kind,
                in: values,
                debugDescription: "Automation timeline item is invalid"
            )
        }
        self.init(
            kind: kind,
            automationId: automationId,
            automationRevision: automationRevision,
            occurrenceId: occurrenceId,
            scheduledFor: scheduledFor,
            dayStart: dayStart,
            firstAt: firstAt,
            lastAt: lastAt,
            count: count
        )
    }

    private enum CodingKeys: String, CodingKey {
        case kind, automationId, automationRevision, occurrenceId, scheduledFor, dayStart, firstAt, lastAt, count
    }
}

struct GatewayAutomationTimelinePage: Decodable, Hashable, Sendable {
    let catalogRevision: Int
    let items: [GatewayAutomationOccurrence]
    let nextCursor: String?

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        catalogRevision = try values.decode(Int.self, forKey: .catalogRevision)
        items = try values.decode([GatewayAutomationOccurrence].self, forKey: .items)
        nextCursor = try values.decodeIfPresent(String.self, forKey: .nextCursor)
        guard catalogRevision >= 0,
              items.count <= AutomationAdmissionPolicy.maximumTimelinePageCount,
              Set(items.map(\.id)).count == items.count,
              nextCursor.map({ !$0.isEmpty && $0.utf8.count <= 64 }) ?? true else {
            throw DecodingError.dataCorruptedError(
                forKey: .items,
                in: values,
                debugDescription: "Automation timeline page is invalid"
            )
        }
    }

    private enum CodingKeys: String, CodingKey { case catalogRevision, items, nextCursor }
}

struct GatewayAutomationPreview: Decodable, Hashable, Sendable {
    let occurrences: [String]

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        occurrences = try values.decode([String].self, forKey: .occurrences)
        guard (0...20).contains(occurrences.count),
              occurrences.allSatisfy({ GatewayTimestamp.parse($0) != nil }),
              occurrences == occurrences.sorted(),
              Set(occurrences).count == occurrences.count else {
            throw DecodingError.dataCorruptedError(
                forKey: .occurrences,
                in: values,
                debugDescription: "Automation preview is invalid"
            )
        }
    }

    private enum CodingKeys: String, CodingKey { case occurrences }
}
struct GatewayAutomationRuns: Codable, Hashable, Sendable { let runs: [GatewayAutomationRunSummary] }
struct GatewayAutomationDeleteResponse: Codable, Hashable, Sendable {
    let automationId: String
    let deleted: Bool
}

enum AutomationAdmissionPolicy {
    static let capability = "automations.v2"
    static let minimumNewSessionIntervalSeconds = 86_400
    static let timelineCapability = "automations.timeline.v1"
    static let maximumPageCount = 100
    static let maximumTimelinePageCount = 200
    static let maximumRetainedCount = 1_024
    static let maximumTimelineRetainedCount = 8_192
    static let maximumAggregateBytes = 2 * 1_048_576

    static func admits(_ summary: GatewayAutomationSummary) -> Bool {
        opaqueID(summary.id)
            && summary.revision >= 1 && summary.stateRevision >= 1
            && bounded(summary.name, maximum: 256)
            && AutomationActionKind(rawValue: summary.actionKind) != nil
            && admits(summary.target)
            && admitsActionTarget(actionKind: summary.typedActionKind, target: summary.target)
            && admits(summary.trigger)
            && summary.consecutiveFailureCount >= 0
            && (summary.blockedReason.map({ bounded($0, maximum: 256) }) ?? true)
            && GatewayTimestamp.parse(summary.createdAt) != nil
            && GatewayTimestamp.parse(summary.updatedAt) != nil
            && (summary.nextOccurrenceAt.map({ GatewayTimestamp.parse($0) != nil }) ?? true)
            && (summary.currentRun.map(admits) ?? true)
            && (summary.lastRun.map(admits) ?? true)
    }

    static func admits(_ trigger: GatewayAutomationTrigger) -> Bool {
        switch trigger.kind {
        case "once":
            return trigger.at.flatMap(GatewayTimestamp.parse) != nil
                && trigger.everySeconds == nil && trigger.anchorAt == nil
                && trigger.timezone == nil && trigger.localTime == nil && trigger.weekdays == nil
        case "interval":
            return trigger.at == nil
                && trigger.everySeconds.map { (60...31_536_000).contains($0) } == true
                && trigger.anchorAt.flatMap(GatewayTimestamp.parse) != nil
                && trigger.timezone == nil && trigger.localTime == nil && trigger.weekdays == nil
        case "calendar":
            guard trigger.at == nil, trigger.everySeconds == nil, trigger.anchorAt == nil,
                  let timezone = trigger.timezone, bounded(timezone, maximum: 128),
                  TimeZone(identifier: timezone) != nil,
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

    static func admits(_ run: GatewayAutomationRunSummary) -> Bool {
        opaqueID(run.runId)
            && GatewayTimestamp.parse(run.scheduledFor) != nil
            && (run.startedAt.map({ GatewayTimestamp.parse($0) != nil }) ?? true)
            && (run.terminalAt.map({ GatewayTimestamp.parse($0) != nil }) ?? true)
            && (run.reason.map({ bounded($0, maximum: 256) }) ?? true)
            && (run.preAdmissionAttemptCount.map({ $0 >= 0 }) ?? true)
    }

    static func admits(_ target: GatewayAutomationTarget) -> Bool {
        switch target {
        case let .existingSession(sessionID): return validSessionID(sessionID)
        case let .workspace(cwd, policy): return validWorkspacePath(cwd) && policy == .newPerRun
        }
    }

    static func admitsActionTarget(actionKind: AutomationActionKind?, target: GatewayAutomationTarget) -> Bool {
        guard let actionKind else { return false }
        return actionKind == .sessionPrompt || !target.isWorkspace
    }

    static func admits(_ action: GatewayAutomationAction) -> Bool {
        switch action.typedKind {
        case .sessionPrompt:
            guard let text = action.text,
                  action.message == nil,
                  !text.isEmpty,
                  text.utf8.count <= 65_536,
                  !text.unicodeScalars.contains(where: { $0.value == 0 }) else { return false }
            if let invocation = action.resourceInvocation {
                guard invocation.source != .extension,
                      invocation.arguments == text,
                      invocation.isTransportValid else { return false }
            }
            return true
        case .notification:
            guard action.text == nil,
                  action.resourceInvocation == nil,
                  let message = action.message,
                  !message.isEmpty,
                  message.utf8.count <= 512,
                  !message.unicodeScalars.contains(where: { $0.value == 0 }) else { return false }
            return true
        case nil:
            return false
        }
    }

    static func admits(_ provenance: GatewayAutomationProvenance) -> Bool {
        switch provenance.kind {
        case "mobile", "local":
            return provenance.sessionId == nil && provenance.sourceId == nil
        case "assistant":
            return provenance.sessionId.map({ boundedText($0, maximum: 200) }) == true
                && provenance.sourceId.map({ boundedText($0, maximum: 256) }) == true
        default:
            return false
        }
    }

    static func admits(_ run: GatewayAutomationRun) -> Bool {
        opaqueID(run.runId)
            && opaqueID(run.occurrenceId)
            && run.automationRevision >= 1
            && GatewayTimestamp.parse(run.scheduledFor) != nil
            && GatewayTimestamp.parse(run.createdAt) != nil
            && admits(run.triggerSnapshot)
            && admits(run.actionSnapshot)
            && admitsActionTarget(actionKind: run.actionSnapshot.typedKind, target: run.targetSnapshot)
            && run.preAdmissionAttemptCount >= 0
            && admits(run.targetSnapshot)
            && validSessionID(run.executionSessionId)
            && (run.targetSnapshot.sessionID == run.executionSessionId
                || run.targetSnapshot.isWorkspace && validGeneratedSessionID(run.executionSessionId))
            && (run.claimedAt.map({ GatewayTimestamp.parse($0) != nil }) ?? true)
            && (run.startedAt.map({ GatewayTimestamp.parse($0) != nil }) ?? true)
            && (run.terminalAt.map({ GatewayTimestamp.parse($0) != nil }) ?? true)
            && (run.retryAt.map({ GatewayTimestamp.parse($0) != nil }) ?? true)
            && (run.reason.map({ bounded($0, maximum: 256) }) ?? true)
            && (run.notificationAdmissionStatus.map({ ["queued", "suppressed", "rate_limited", "unavailable"].contains($0) }) ?? true)
            && (run.error.map({ bounded($0.code, maximum: 128) && boundedText($0.message, maximum: 1_024) }) ?? true)
            && (run.resolution.map({
                ["succeeded", "failed", "cancelled"].contains($0.outcome)
                    && GatewayTimestamp.parse($0.resolvedAt) != nil
                    && admits($0.provenance)
            }) ?? true)
    }

    static func admits(_ record: GatewayAutomationRecord) -> Bool {
        record.schemaVersion == 2
            && opaqueID(record.id)
            && record.revision >= 1 && record.stateRevision >= 1
            && bounded(record.name, maximum: 256)
            && (record.description.map({ boundedText($0, maximum: 2_048) }) ?? true)
            && admits(record.provenance)
            && admits(record.target)
            && admitsActionTarget(actionKind: record.action.typedKind, target: record.target)
            && admits(record.trigger)
            && (record.target.isWorkspace ? admitsNewSessionInterval(record.trigger) : true)
            && ["latest", "skip"].contains(record.misfirePolicy)
            && ["skip", "queueLatest"].contains(record.overlapPolicy)
            && (300...86_400).contains(record.executionDeadlineSeconds)
            && admits(record.action)
            && GatewayTimestamp.parse(record.createdAt) != nil
            && GatewayTimestamp.parse(record.updatedAt) != nil
            && (record.nextOccurrenceAt.map({ GatewayTimestamp.parse($0) != nil }) ?? true)
            && (record.currentRun.map({ admits($0) && !$0.state.isTerminal }) ?? true)
            && (record.lastRun.map({ admits($0) && $0.state.isTerminal }) ?? true)
            && record.history.count <= 64
            && record.history.allSatisfy({ admits($0) && $0.state.isTerminal })
            && record.consecutiveFailureCount >= 0
            && (record.blockedReason.map({ bounded($0, maximum: 256) }) ?? true)
    }

    static func opaqueID(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 64 && value.unicodeScalars.allSatisfy {
            CharacterSet.alphanumerics.contains($0) || "-_".unicodeScalars.contains($0)
        }
    }

    static func validSessionID(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 200 && value.unicodeScalars.allSatisfy {
            CharacterSet.alphanumerics.contains($0) || "-_:".unicodeScalars.contains($0)
        }
    }

    static func validGeneratedSessionID(_ value: String) -> Bool {
        value.utf8.count == 36 && UUID(uuidString: value) != nil
    }

    static func validWorkspacePath(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 4_096 && value.hasPrefix("/")
            && !value.unicodeScalars.contains(where: { $0.value == 0 || CharacterSet.controlCharacters.contains($0) })
    }

    static func admitsNewSessionInterval(_ trigger: GatewayAutomationTrigger) -> Bool {
        trigger.kind != "interval" || (trigger.everySeconds ?? 0) >= minimumNewSessionIntervalSeconds
    }

    private static func bounded(_ value: String, maximum: Int) -> Bool {
        !value.isEmpty && value.utf8.count <= maximum
            && value.unicodeScalars.allSatisfy { !CharacterSet.controlCharacters.contains($0) }
    }

    private static func boundedText(_ value: String, maximum: Int) -> Bool {
        !value.isEmpty && value.utf8.count <= maximum
            && !value.unicodeScalars.contains(where: { $0.value == 0 })
    }
}

struct AutomationDashboardProfile: Identifiable, Hashable, Sendable {
    let id: String
    let label: String
    let state: DashboardServerConnectionState
    let capabilities: Set<String>
}

enum AutomationEndpointAdmissionPolicy {
    static func admits(_ profile: AutomationDashboardProfile) -> Bool {
        profile.state == .connected
            && profile.capabilities.contains(AutomationAdmissionPolicy.capability)
    }

    static func admitsTimeline(_ profile: AutomationDashboardProfile) -> Bool {
        admits(profile)
            && profile.capabilities.contains(AutomationAdmissionPolicy.timelineCapability)
    }
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
    var id: String { "\(profileID):\(occurrence.id)" }
}

struct AutomationAgendaDay: Identifiable, Hashable, Sendable {
    let date: Date
    let items: [AutomationTimelineItem]
    var id: Date { date }
}
