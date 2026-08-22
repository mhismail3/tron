import Foundation

/// Additive Gateway lifecycle facts. The coarse tool status remains available
/// for old Gateways, while this record owns native admission and recency.
enum ExtensionActivityLifecycleState: String, Codable, CaseIterable, Sendable {
    case queued, running, paused, completed, failed, stopped, rejected, unknown
    var isTerminal: Bool { switch self { case .completed, .failed, .stopped, .rejected: true; default: false } }
    var isCurrent: Bool { switch self { case .queued, .running, .paused: true; default: false } }
    var displayName: String { rawValue == "unknown" ? "Unknown" : rawValue.capitalized }
}

enum ExtensionActivityAttention: String, Codable, CaseIterable, Sendable {
    case none, activeLongRunning, needsAttention
}

enum ExtensionActivityVisibility: String, Codable, CaseIterable, Sendable {
    case current, recent, historical, unknown
}

struct ExtensionActivityLifecycle: Codable, Hashable, Sendable {
    let version: Int
    let state: ExtensionActivityLifecycleState
    let attention: ExtensionActivityAttention
    let sequence: Int
    let observedAt: String
    let producerUpdatedAt: String?
    let terminalAt: String?
    let recentUntil: String?
    let visibility: ExtensionActivityVisibility?
    let remainingMs: Int?

    init(version: Int = 1, state: ExtensionActivityLifecycleState,
         attention: ExtensionActivityAttention = .none, sequence: Int,
         observedAt: String, producerUpdatedAt: String? = nil,
         terminalAt: String? = nil, recentUntil: String? = nil,
         visibility: ExtensionActivityVisibility? = nil, remainingMs: Int? = nil) {
        self.version = version; self.state = state; self.attention = attention
        self.sequence = sequence; self.observedAt = observedAt
        self.producerUpdatedAt = producerUpdatedAt; self.terminalAt = terminalAt
        self.recentUntil = recentUntil; self.visibility = visibility
        self.remainingMs = remainingMs
    }

    var isTerminal: Bool { state.isTerminal }
}

struct ExtensionActivityOmissions: Codable, Hashable, Sendable {
    let count: Int
    let bytes: Int
    let reason: String
}

/// Strict, bounded admission is separate from Codable so optional malformed
/// activity rows can be omitted without rejecting the entire session snapshot.
enum ExtensionActivityAdmissionPolicy {
    static let capability = "extension-activity-history.v1"
    static let maximumActivities = 32
    static let maximumChildren = 32
    static let maximumDescendants = 64
    static let maximumDepth = 3
    static let maximumStringBytes = 2_048
    static let maximumEncodedBytes = 256 * 1_024
    static let terminalStates: Set<ExtensionActivityLifecycleState> = [.completed, .failed, .stopped, .rejected]

    static func admits(_ activity: ExtensionRunActivity) -> Bool {
        var descendantBudget = maximumDescendants
        guard validID(activity.id, maximum: 512),
              activity.activityId.map({ validID($0, maximum: 512) }) ?? true,
              activity.runId.map({ validID($0, maximum: 512) }) ?? true,
              validID(activity.toolCallId, maximum: maximumStringBytes),
              boundedNonEmpty(activity.title, 512),
              validTimestamp(activity.startedAt), validTimestamp(activity.updatedAt),
              validSource(activity.source),
              activity.mode.map({ bounded($0, 256) }) ?? true,
              activity.completedAt.map(validTimestamp) ?? true,
              activity.lastActivityAt.map(validTimestamp) ?? true,
              activity.currentTool.map({ bounded($0, maximumStringBytes) }) ?? true,
              activity.currentToolStartedAt.map(validTimestamp) ?? true,
              activity.currentPath.map({ bounded($0, maximumStringBytes) }) ?? true,
              activity.output.map({ bounded($0, 32 * 1_024, newlines: true) }) ?? true,
              nonnegative(activity.toolCount), nonnegative(activity.turnCount),
              nonnegative(activity.durationMs), activity.children.count <= maximumChildren,
              validReceiptTimeline(activity) else { return false }
        for child in activity.children {
            guard admits(child, depth: 0, budget: &descendantBudget) else { return false }
        }
        if let lifecycle = activity.lifecycle {
            guard lifecycle.version == 1, lifecycle.sequence >= 0,
                  bounded(lifecycle.observedAt, 128), GatewayTimestamp.parse(lifecycle.observedAt) != nil,
                  lifecycle.producerUpdatedAt.map({ bounded($0, 128) && GatewayTimestamp.parse($0) != nil }) ?? true,
                  lifecycle.terminalAt.map({ bounded($0, 128) && GatewayTimestamp.parse($0) != nil }) ?? true,
                  lifecycle.recentUntil.map({ bounded($0, 128) && GatewayTimestamp.parse($0) != nil }) ?? true,
                  lifecycle.remainingMs.map({ $0 >= 0 }) ?? true,
                  lifecycle.isTerminal == (lifecycle.terminalAt != nil),
                  validLifecycleCombination(state: lifecycle.state, status: activity.status,
                                            visibility: lifecycle.visibility,
                                            remainingMs: lifecycle.remainingMs,
                                            recentUntil: lifecycle.recentUntil) else { return false }
            if let terminalAt = lifecycle.terminalAt, let recentUntil = lifecycle.recentUntil,
               let terminal = GatewayTimestamp.parse(terminalAt), let expiry = GatewayTimestamp.parse(recentUntil), expiry < terminal { return false }
        }
        var childIDs = Set<String>()
        guard activity.children.allSatisfy({ child in
            childIDs.insert(child.id).inserted
        }) else { return false }
        guard let encoded = try? JSONEncoder.gateway.encode(activity), encoded.count <= maximumEncodedBytes else { return false }
        return true
    }

    static func admitted(_ activities: [ExtensionRunActivity], preserving protectedIDs: Set<String> = []) -> [ExtensionRunActivity] {
        var seen = Set<String>()
        var result = activities.filter { activity in
            admits(activity) && seen.insert(activity.stableID).inserted
        }
        guard result.count > maximumActivities else { return result }
        let protected = Array(result.filter { protectedIDs.contains($0.stableID) }.prefix(maximumActivities))
        let candidates = result.filter { !protectedIDs.contains($0.stableID) }
        let sorted = candidates.sorted { evictionPrecedes($0, $1) }
        let keepCount = max(0, maximumActivities - protected.count)
        result = protected + Array(sorted.suffix(keepCount))
        return result
    }

    static func admitsDelta(_ delta: ExtensionActivityDelta) -> Bool {
        delta.liveActivityRevision >= 0
            && validTimestamp(delta.extensionActivityAsOf)
            && admits(delta.activity)
    }

    static func admitsToolFacts(_ tool: ToolExecutionState) -> Bool {
        guard (tool.liveActivityRevision == nil) == (tool.extensionActivityAsOf == nil) else { return false }
        if let revision = tool.liveActivityRevision, revision < 0 { return false }
        if let asOf = tool.extensionActivityAsOf, !validTimestamp(asOf) { return false }
        return tool.extensionActivity != nil || (tool.liveActivityRevision == nil && tool.extensionActivityAsOf == nil)
    }

    static func admitsSnapshotFacts(_ snapshot: SessionSnapshot) -> Bool {
        if let revision = snapshot.liveActivityRevision, revision < 0 { return false }
        if let asOf = snapshot.extensionActivityAsOf,
           !validTimestamp(asOf) { return false }
        // New Gateway facts are an atomic pair. Older snapshots may omit both.
        guard (snapshot.liveActivityRevision == nil) == (snapshot.extensionActivityAsOf == nil) else { return false }
        if let activities = snapshot.extensionActivities,
           admitted(activities).count != activities.filter(admits).count {
            return false
        }
        guard let omissions = snapshot.extensionActivityOmissions else { return true }
        return omissions.count >= 0 && omissions.count <= 2_048
            && omissions.bytes >= 0
            && omissions.bytes <= maximumEncodedBytes
            && ["count", "bytes", "countAndBytes"].contains(omissions.reason)
    }

    private static func admits(_ owner: ExtensionOwner) -> Bool {
        validID(owner.id, maximum: 512) && boundedNonEmpty(owner.title, 512)
            && boundedNonEmpty(owner.source, maximumStringBytes)
    }

    private static func admits(_ child: ExtensionRunChild, depth: Int, budget: inout Int) -> Bool {
        guard depth < maximumDepth, validID(child.id, maximum: 512), boundedNonEmpty(child.label, 512),
              child.task.map({ bounded($0, maximumStringBytes) }) ?? true,
              child.lastActivityAt.map(validTimestamp) ?? true,
              child.currentTool.map({ bounded($0, maximumStringBytes) }) ?? true,
              child.currentToolStartedAt.map(validTimestamp) ?? true,
              child.currentPath.map({ bounded($0, maximumStringBytes) }) ?? true,
              child.output.map({ bounded($0, 32 * 1_024, newlines: true) }) ?? true,
              nonnegative(child.toolCount), nonnegative(child.turnCount), nonnegative(child.durationMs),
              (child.children ?? []).count <= maximumChildren else { return false }
        budget -= 1
        guard budget >= 0 else { return false }
        var childIDs = Set<String>()
        guard (child.children ?? []).allSatisfy({ child in childIDs.insert(child.id).inserted }) else { return false }
        guard validChildLifecycleCombination(state: child.lifecycle, status: child.status) else { return false }
        for nested in child.children ?? [] {
            guard admits(nested, depth: depth + 1, budget: &budget) else { return false }
        }
        return true
    }

    private static func validLifecycleCombination(
        state: ExtensionActivityLifecycleState,
        status: ExtensionRunActivity.Status,
        visibility: ExtensionActivityVisibility?,
        remainingMs: Int?,
        recentUntil: String?
    ) -> Bool {
        switch state {
        case .queued, .running, .paused:
            return status == .running && (visibility == nil || visibility == .current)
                && remainingMs == nil && recentUntil == nil
        case .completed:
            return status == .completed && visibility != .current
                && (visibility == .recent ? remainingMs.map { $0 > 0 } == true : remainingMs == nil || remainingMs == 0)
        case .failed:
            return status == .failed && visibility != .current
                && (visibility == .recent ? remainingMs.map { $0 > 0 } == true : remainingMs == nil || remainingMs == 0)
        case .stopped, .rejected:
            // The rolling status vocabulary represents both terminal outcomes
            // as completed; the lifecycle label remains authoritative.
            return status == .completed && visibility != .current
                && (visibility == .recent ? remainingMs.map { $0 > 0 } == true : remainingMs == nil || remainingMs == 0)
        case .unknown:
            return visibility == .unknown && remainingMs == nil
        }
    }

    private static func validChildLifecycleCombination(
        state: ExtensionActivityLifecycleState?,
        status: ExtensionRunChild.Status
    ) -> Bool {
        guard let state else { return true }
        switch state {
        case .queued, .running, .paused: return status == .running
        case .completed: return status == .completed
        case .failed: return status == .failed
        case .stopped, .rejected: return status == .completed
        case .unknown: return false
        }
    }

    private static func validID(_ value: String, maximum: Int) -> Bool {
        boundedNonEmpty(value, maximum)
    }

    private static func boundedNonEmpty(_ value: String, _ bytes: Int) -> Bool {
        !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && bounded(value, bytes)
    }

    private static func validTimestamp(_ value: String) -> Bool {
        bounded(value, 128) && GatewayTimestamp.parse(value) != nil
    }

    /// Terminal receipt facts must never describe a lifecycle that runs
    /// backwards. This covers both versioned Gateway rows and legacy rows
    /// without a lifecycle wrapper.
    private static func validReceiptTimeline(_ activity: ExtensionRunActivity) -> Bool {
        guard let terminalAt = activity.lifecycle?.terminalAt ?? activity.completedAt else { return true }
        guard let started = GatewayTimestamp.parse(activity.startedAt),
              let terminal = GatewayTimestamp.parse(terminalAt),
              let observed = GatewayTimestamp.parse(activity.lifecycle?.observedAt ?? activity.updatedAt) else { return false }
        return started <= terminal && terminal <= observed
    }

    private static func validSource(_ source: ExtensionToolOrigin) -> Bool {
        guard boundedNonEmpty(source.source, maximumStringBytes), source.owner.map(admits) ?? true else { return false }
        return source.owner != nil || !source.source.contains(where: { $0 == "/" || $0 == "\\" })
    }

    private static func evictionPrecedes(_ left: ExtensionRunActivity, _ right: ExtensionRunActivity) -> Bool {
        let leftPriority = left.isLive ? 2 : (left.lifecycle?.visibility == .recent ? 1 : 0)
        let rightPriority = right.isLive ? 2 : (right.lifecycle?.visibility == .recent ? 1 : 0)
        if leftPriority != rightPriority { return leftPriority < rightPriority }
        return left.updatedAt < right.updatedAt
    }

    private static func bounded(_ value: String, _ bytes: Int, newlines: Bool = false) -> Bool {
        value.utf8.count <= bytes && !value.unicodeScalars.contains { scalar in
            if scalar.value == 0x0a || scalar.value == 0x0d { return !newlines }
            return scalar.value < 0x20 || (0x7f...0x9f).contains(scalar.value)
        }
    }
    private static func nonnegative(_ value: Int?) -> Bool { value.map { $0 >= 0 } ?? true }
}

enum ExtensionActivityVisibilityPolicy {
    static func ambient(_ activity: ExtensionRunActivity) -> Bool {
        guard let lifecycle = activity.lifecycle else { return activity.status == .running }
        guard lifecycle.state.isCurrent else { return lifecycle.state.isTerminal && lifecycle.visibility == .recent }
        return lifecycle.visibility == nil || lifecycle.visibility == .current
    }
    static func authoritativeBucket(_ activity: ExtensionRunActivity) -> ExtensionActivityVisibility {
        activity.lifecycle?.visibility ?? (activity.status == .running ? .current : .unknown)
    }
}

struct ExtensionActivityPillSample: Hashable, Sendable {
    let ownerID: String
    let title: String
    let state: ExtensionActivityLifecycleState
    let count: Int
    let attention: ExtensionActivityAttention
}

enum ExtensionActivityGroupProjection {
    /// Owner identity is primary. Source fallback is accepted only when the
    /// inventory proves that one source maps to one owner.
    static func owner(for activity: ExtensionRunActivity, inventory: [ExtensionOwner]) -> ExtensionOwner? {
        if let owner = activity.source.owner { return owner }
        let candidates = inventory.filter { $0.source == activity.source.source }
        return candidates.count == 1 ? candidates[0] : nil
    }

    static func ambientGroups(_ activities: [ExtensionRunActivity], inventory: [ExtensionOwner]) -> [ExtensionActivityPillSample] {
        let admitted = activities.filter { ExtensionActivityAdmissionPolicy.admits($0) && ExtensionActivityVisibilityPolicy.ambient($0) }
        var grouped: [String: (ExtensionOwner, [ExtensionRunActivity])] = [:]
        for activity in admitted {
            guard let owner = owner(for: activity, inventory: inventory) else { continue }
            grouped[owner.id, default: (owner, [])].1.append(activity)
        }
        return grouped.values.map { owner, rows in
            let states = rows.map { $0.lifecycle?.state ?? ($0.status == .failed ? .failed : .running) }
            let state = states.first(where: { $0 == .failed || $0 == .rejected })
                ?? states.first(where: { $0 == .paused })
                ?? states.first(where: { $0 == .running || $0 == .queued })
                ?? .completed
            let attention = rows.first(where: { $0.lifecycle?.attention == .needsAttention })?.lifecycle?.attention
                ?? rows.first?.lifecycle?.attention ?? .none
            return ExtensionActivityPillSample(ownerID: owner.id, title: owner.title, state: state, count: rows.count, attention: attention)
        }.sorted { $0.ownerID < $1.ownerID }
    }
}

/// Monotonic local visual deadline. It can only animate toward the Gateway's
/// already-authoritative bucket and never promotes a historical row.
struct ExtensionActivityVisualDeadline: Sendable {
    let bucket: ExtensionActivityVisibility
    let deadline: ContinuousClock.Instant?
    init(bucket: ExtensionActivityVisibility, remainingMs: Int?, now: ContinuousClock.Instant = .now) {
        self.bucket = bucket
        self.deadline = bucket == .recent && (remainingMs ?? 0) > 0
            ? now.advanced(by: .milliseconds(remainingMs!)) : nil
    }
    func expired(at now: ContinuousClock.Instant) -> Bool { bucket == .recent && deadline.map { now >= $0 } ?? false }
}

/// A live duration is anchored once to the monotonic clock. Gateway updates
/// may raise the observed floor, but wall-clock changes can never make the
/// displayed active time run backwards.
struct ExtensionActivityDurationAnchor: Sendable, Equatable {
    let startedAt: String
    let observedDurationMs: Int
    let anchor: ContinuousClock.Instant

    init(startedAt: String, observedDurationMs: Int, anchor: ContinuousClock.Instant = .now) {
        self.startedAt = startedAt
        self.observedDurationMs = max(0, observedDurationMs)
        self.anchor = anchor
    }

    func durationMs(at now: ContinuousClock.Instant = .now) -> Int {
        let components = (now - anchor).components
        guard components.seconds > 0 || (components.seconds == 0 && components.attoseconds > 0) else {
            return observedDurationMs
        }

        let secondsMilliseconds = components.seconds.multipliedReportingOverflow(by: 1_000)
        let elapsedMilliseconds: Int
        if secondsMilliseconds.overflow {
            elapsedMilliseconds = Int.max
        } else {
            let wholeMilliseconds = Int(clamping: secondsMilliseconds.partialValue)
            let fractionalMilliseconds = Int(clamping: components.attoseconds / 1_000_000_000_000_000)
            let combined = wholeMilliseconds.addingReportingOverflow(fractionalMilliseconds)
            elapsedMilliseconds = combined.overflow ? Int.max : combined.partialValue
        }

        let total = observedDurationMs.addingReportingOverflow(elapsedMilliseconds)
        return total.overflow ? Int.max : max(observedDurationMs, total.partialValue)
    }
}
