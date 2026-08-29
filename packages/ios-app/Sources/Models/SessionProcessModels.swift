import Foundation

enum SessionProcessKind: String, Codable, CaseIterable, Sendable { case command, subagent }

enum SessionProcessExecutionMode: String, Codable, CaseIterable, Sendable {
    case foreground, background, synchronous, asynchronous, unknown
    var displayName: String {
        switch self {
        case .foreground: "Foreground"
        case .background: "Background"
        case .synchronous: "Synchronous"
        case .asynchronous: "Asynchronous"
        case .unknown: ""
        }
    }
}

enum SessionProcessSource: String, Codable, CaseIterable, Sendable {
    case mainAssistant, delegatedAgent, admittedExtension
}

enum SessionProcessLifecycleState: String, Codable, CaseIterable, Sendable {
    case queued, running, paused, completed, failed, stopped, rejected, interrupted, unknown

    var isActive: Bool { switch self { case .queued, .running, .paused: true; default: false } }
    var isTerminal: Bool { switch self { case .completed, .failed, .stopped, .rejected, .interrupted: true; default: false } }
    var isProblem: Bool { switch self { case .failed, .rejected, .interrupted: true; default: false } }
    var displayName: String { rawValue == "unknown" ? "Unknown" : rawValue.capitalized }
}

enum SessionProcessAttention: String, Codable, CaseIterable, Sendable {
    case none, activeLongRunning, needsAttention
}

enum SessionProcessVisibility: String, Codable, CaseIterable, Sendable {
    case active, recent, historical, unknown
}

struct SessionProcessLifecycle: Codable, Hashable, Sendable {
    let version: Int
    let state: SessionProcessLifecycleState
    let attention: SessionProcessAttention
    let sequence: Int
    let observedAt: String
    let producerUpdatedAt: String?
    let terminalAt: String?
    let recentUntil: String?

    init(
        version: Int = 1,
        state: SessionProcessLifecycleState,
        attention: SessionProcessAttention = .none,
        sequence: Int,
        observedAt: String,
        producerUpdatedAt: String? = nil,
        terminalAt: String? = nil,
        recentUntil: String? = nil
    ) {
        self.version = version
        self.state = state
        self.attention = attention
        self.sequence = sequence
        self.observedAt = observedAt
        self.producerUpdatedAt = producerUpdatedAt
        self.terminalAt = terminalAt
        self.recentUntil = recentUntil
    }
}

/// Exact additive Gateway DTO. Optional fields remain optional so old history
/// and rows from different existing producers decode without fabrication.
struct SessionProcessActivity: Codable, Hashable, Identifiable, Sendable {
    let version: Int
    let processId: String
    let kind: SessionProcessKind
    let executionMode: SessionProcessExecutionMode
    let source: SessionProcessSource
    let parentProcessId: String?
    let lifecycle: SessionProcessLifecycle
    let visibility: SessionProcessVisibility
    let startedAt: String?
    let title: String
    let command: String?
    let currentTool: String?
    let currentPathBasename: String?
    let outputTail: String?
    let outputTruncated: Bool
    let durationMs: Int?
    let toolCount: Int?
    let turnCount: Int?
    let childCount: Int?
    let toolCallId: String?
    let runId: String?
    let childSessionRef: String?

    var id: String { processId }

    init(
        version: Int = 1,
        processId: String,
        kind: SessionProcessKind,
        executionMode: SessionProcessExecutionMode,
        source: SessionProcessSource,
        parentProcessId: String? = nil,
        lifecycle: SessionProcessLifecycle,
        visibility: SessionProcessVisibility,
        startedAt: String? = nil,
        title: String,
        command: String? = nil,
        currentTool: String? = nil,
        currentPathBasename: String? = nil,
        outputTail: String? = nil,
        outputTruncated: Bool = false,
        durationMs: Int? = nil,
        toolCount: Int? = nil,
        turnCount: Int? = nil,
        childCount: Int? = nil,
        toolCallId: String? = nil,
        runId: String? = nil,
        childSessionRef: String? = nil
    ) {
        self.version = version
        self.processId = processId
        self.kind = kind
        self.executionMode = executionMode
        self.source = source
        self.parentProcessId = parentProcessId
        self.lifecycle = lifecycle
        self.visibility = visibility
        self.startedAt = startedAt
        self.title = title
        self.command = command
        self.currentTool = currentTool
        self.currentPathBasename = currentPathBasename
        self.outputTail = outputTail
        self.outputTruncated = outputTruncated
        self.durationMs = durationMs
        self.toolCount = toolCount
        self.turnCount = turnCount
        self.childCount = childCount
        self.toolCallId = toolCallId
        self.runId = runId
        self.childSessionRef = childSessionRef
    }
}

struct SessionProcessOmissions: Codable, Hashable, Sendable {
    let count: Int
    let bytes: Int
    let reason: String
}

enum SessionProcessOverviewVisibility: String, Codable, CaseIterable, Sendable {
    case hidden, active, recent
}

struct SessionProcessOverview: Codable, Hashable, Sendable {
    let version: Int
    let revision: Int
    let asOf: String
    let activeCount: Int
    let recentCount: Int
    let problemCount: Int
    let visibility: SessionProcessOverviewVisibility
    let nearestExpiry: String?
    let omissions: SessionProcessOmissions?

    init(
        version: Int = 1,
        revision: Int,
        asOf: String,
        activeCount: Int,
        recentCount: Int,
        problemCount: Int,
        visibility: SessionProcessOverviewVisibility,
        nearestExpiry: String? = nil,
        omissions: SessionProcessOmissions? = nil
    ) {
        self.version = version
        self.revision = revision
        self.asOf = asOf
        self.activeCount = activeCount
        self.recentCount = recentCount
        self.problemCount = problemCount
        self.visibility = visibility
        self.nearestExpiry = nearestExpiry
        self.omissions = omissions
    }
}

struct SessionProcessDelta: Codable, Hashable, Sendable {
    let activity: SessionProcessActivity?
    let removedProcessIds: [String]?
    let processRevision: Int
    let processAsOf: String
    let overview: SessionProcessOverview
}

/// Lease invalidations are deliberately outside the mounted parent session
/// sequence. A close notification has no revision and is still admitted.
struct ProcessTranscriptChanged: Codable, Hashable, Sendable {
    let leaseId: String
    let processId: String?
    let revision: String?
    let total: Int?
    let leafEntryId: String?
    let closed: Bool?
    let reason: String?
}

enum SessionProcessAdmissionPolicy {
    static let historyCapability = "process-history.v1"
    static let transcriptCapability = "process-transcript.v1"
    static let maximumActivities = 32
    static let maximumRemovedProcessIDs = 32
    static let maximumOverviewCount = 2_080
    static let maximumStringBytes = 2_048
    static let maximumOutputBytes = 32 * 1_024
    static let maximumEncodedBytes = 256 * 1_024

    static func admits(_ process: SessionProcessActivity) -> Bool {
        guard process.version == 1,
              boundedNonempty(process.processId, 512),
              process.parentProcessId.map({ boundedNonempty($0, 512) }) ?? true,
              boundedNonempty(process.title, maximumStringBytes),
              process.command.map({ bounded($0, maximumStringBytes, newlines: true) }) ?? true,
              process.startedAt.map(validTimestamp) ?? true,
              process.currentTool.map({ bounded($0, maximumStringBytes) }) ?? true,
              process.currentPathBasename.map(validBasename) ?? true,
              process.outputTail.map({ bounded($0, maximumOutputBytes, newlines: true) }) ?? true,
              process.toolCallId.map({ boundedNonempty($0, maximumStringBytes) }) ?? true,
              process.runId.map({ boundedNonempty($0, 512) }) ?? true,
              process.childSessionRef.map({ boundedNonempty($0, 512) && !$0.contains("/") && !$0.contains("\\") }) ?? true,
              [process.durationMs, process.toolCount, process.turnCount, process.childCount]
                .allSatisfy({ $0.map { $0 >= 0 } ?? true }),
              admits(process.lifecycle, visibility: process.visibility) else { return false }
        switch process.kind {
        case .subagent:
            guard process.executionMode == .synchronous || process.executionMode == .asynchronous,
                  process.command == nil else { return false }
        case .command:
            // Decode and validate legacy Gateway rows so an older authoritative
            // snapshot can still open, but never admit them to presentation.
            guard process.executionMode == .foreground,
                  process.source == .mainAssistant,
                  process.command != nil else { return false }
        }
        if let startedAt = process.startedAt,
           let started = GatewayTimestamp.parse(startedAt),
           let observed = GatewayTimestamp.parse(process.lifecycle.observedAt), observed < started { return false }
        guard let encoded = try? JSONEncoder.gateway.encode(process), encoded.count <= maximumEncodedBytes else { return false }
        return true
    }

    static func admitted(_ processes: [SessionProcessActivity]) -> [SessionProcessActivity] {
        var seen = Set<String>()
        return Array(processes
            .filter { $0.kind == .subagent && admits($0) && seen.insert($0.processId).inserted }
            .sorted(by: SessionProcessProjection.precedes)
            .prefix(maximumActivities))
    }

    static func admits(_ overview: SessionProcessOverview) -> Bool {
        guard overview.version == 1,
              overview.revision >= 0,
              validTimestamp(overview.asOf),
              overview.nearestExpiry.map(validTimestamp) ?? true,
              boundedCount(overview.activeCount),
              boundedCount(overview.recentCount),
              boundedCount(overview.problemCount),
              overview.problemCount <= overview.activeCount + overview.recentCount,
              (overview.recentCount > 0) == (overview.nearestExpiry != nil),
              admits(overview.omissions) else { return false }
        switch overview.visibility {
        case .hidden:
            return overview.activeCount == 0 && overview.recentCount == 0 && overview.nearestExpiry == nil
        case .active:
            return overview.activeCount > 0
        case .recent:
            return overview.activeCount == 0 && overview.recentCount > 0 && overview.nearestExpiry != nil
        }
    }

    static func admits(_ delta: SessionProcessDelta) -> Bool {
        let removals = delta.removedProcessIds ?? []
        guard delta.processRevision >= 0,
              validTimestamp(delta.processAsOf),
              delta.overview.revision == delta.processRevision,
              delta.overview.asOf == delta.processAsOf,
              admits(delta.overview),
              removals.count <= maximumRemovedProcessIDs,
              Set(removals).count == removals.count,
              removals.allSatisfy({ boundedNonempty($0, 512) }),
              delta.activity != nil || !removals.isEmpty else { return false }
        guard let activity = delta.activity else { return true }
        guard admits(activity) else { return false }
        switch activity.visibility {
        case .active:
            return delta.overview.visibility == .active && delta.overview.activeCount > 0
        case .recent:
            return delta.overview.visibility != .hidden && delta.overview.recentCount > 0
        case .historical, .unknown:
            return false
        }
    }

    static func admitsMountedSubset(
        _ activities: [SessionProcessActivity],
        overview: SessionProcessOverview
    ) -> Bool {
        guard activities.allSatisfy({ $0.visibility == .active || $0.visibility == .recent }) else { return false }
        let active = activities.filter { $0.visibility == .active }.count
        let recentRows = activities.filter { $0.visibility == .recent }
        guard active <= overview.activeCount, recentRows.count <= overview.recentCount else { return false }
        switch overview.visibility {
        case .hidden:
            guard activities.isEmpty else { return false }
        case .active:
            guard active > 0 else { return false }
        case .recent:
            guard active == 0, !recentRows.isEmpty else { return false }
        }
        if let mountedNearest = recentRows.compactMap({ $0.lifecycle.recentUntil }).min(),
           let overviewNearest = overview.nearestExpiry,
           overviewNearest > mountedNearest { return false }
        return true
    }

    static func admitsSnapshotFacts(_ snapshot: SessionSnapshot) -> Bool {
        guard let overview = snapshot.processOverview else {
            return snapshot.processActivities == nil // Legacy Gateway omits the projection entirely.
        }
        let activities = snapshot.processActivities ?? []
        guard admits(overview), activities.count <= maximumActivities,
              activities.allSatisfy(admits) else { return false }
        if (overview.activeCount > 0 || overview.recentCount > 0), snapshot.processActivities == nil { return false }
        guard admitsMountedSubset(activities, overview: overview) else { return false }
        let active = activities.filter { $0.visibility == .active }.count
        let recentRows = activities.filter { $0.visibility == .recent }
        let recent = recentRows.count
        if overview.omissions == nil {
            guard active == overview.activeCount, recent == overview.recentCount else { return false }
            let nearest = recentRows.compactMap { $0.lifecycle.recentUntil }.min()
            guard nearest == overview.nearestExpiry else { return false }
        } else {
            guard active <= overview.activeCount, recent <= overview.recentCount else { return false }
            if let mountedNearest = recentRows.compactMap({ $0.lifecycle.recentUntil }).min(),
               let overviewNearest = overview.nearestExpiry,
               overviewNearest > mountedNearest { return false }
        }
        return true
    }

    static func admits(_ change: ProcessTranscriptChanged) -> Bool {
        guard boundedNonempty(change.leaseId, 256),
              change.processId.map({ boundedNonempty($0, 512) }) ?? true,
              change.revision.map({ boundedNonempty($0, 256) }) ?? true,
              change.total.map({ $0 >= 0 }) ?? true,
              change.leafEntryId.map({ boundedNonempty($0, 512) }) ?? true,
              change.reason.map({ bounded($0, maximumStringBytes) }) ?? true else { return false }
        return change.revision != nil || change.closed == true
    }

    private static func admits(_ lifecycle: SessionProcessLifecycle, visibility: SessionProcessVisibility) -> Bool {
        guard lifecycle.version == 1, lifecycle.sequence >= 0,
              validTimestamp(lifecycle.observedAt),
              lifecycle.producerUpdatedAt.map(validTimestamp) ?? true,
              lifecycle.terminalAt.map(validTimestamp) ?? true,
              lifecycle.recentUntil.map(validTimestamp) ?? true else { return false }
        switch visibility {
        case .active:
            return lifecycle.state.isActive && lifecycle.terminalAt == nil && lifecycle.recentUntil == nil
        case .recent, .historical:
            guard lifecycle.state.isTerminal,
                  let terminal = lifecycle.terminalAt.flatMap(GatewayTimestamp.parse),
                  let expiry = lifecycle.recentUntil.flatMap(GatewayTimestamp.parse) else { return false }
            return abs(expiry.timeIntervalSince(terminal) - recentInterval) < 0.001
        case .unknown:
            return lifecycle.state == .unknown && lifecycle.terminalAt == nil && lifecycle.recentUntil == nil
        }
    }

    private static let recentInterval: TimeInterval = 5 * 60

    private static func admits(_ omissions: SessionProcessOmissions?) -> Bool {
        guard let omissions else { return true }
        return omissions.count >= 0 && omissions.count <= 2_048
            && omissions.bytes >= 0 && omissions.bytes <= maximumEncodedBytes
            && ["count", "bytes", "countAndBytes"].contains(omissions.reason)
    }

    private static func boundedCount(_ value: Int) -> Bool {
        value >= 0 && value <= maximumOverviewCount
    }

    private static func validTimestamp(_ value: String) -> Bool {
        bounded(value, 128) && GatewayTimestamp.parse(value) != nil
    }

    private static func validBasename(_ value: String) -> Bool {
        boundedNonempty(value, maximumStringBytes) && !value.contains("/") && !value.contains("\\")
    }

    private static func boundedNonempty(_ value: String, _ bytes: Int) -> Bool {
        !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && bounded(value, bytes)
    }

    private static func bounded(_ value: String, _ bytes: Int, newlines: Bool = false) -> Bool {
        value.utf8.count <= bytes && !value.unicodeScalars.contains { scalar in
            if scalar.value == 0x0a || scalar.value == 0x0d { return !newlines }
            return scalar.value < 0x20 || (0x7f...0x9f).contains(scalar.value)
        }
    }
}

enum SessionProcessProjection {
    struct Sections: Equatable, Sendable {
        let active: [SessionProcessActivity]
        let recent: [SessionProcessActivity]
    }

    static func sections(_ activities: [SessionProcessActivity]) -> Sections {
        let admitted = SessionProcessAdmissionPolicy.admitted(activities)
        return Sections(
            active: admitted.filter { $0.visibility == .active },
            recent: admitted.filter { $0.visibility == .recent }
        )
    }

    /// Keep an already-presented single-run sheet attached when Gateway replaces
    /// a temporary aggregate with its exact child row. Multiple matching
    /// children are intentionally ambiguous and fail closed.
    static func mountedActivity(
        selected: SessionProcessActivity,
        activities: [SessionProcessActivity]
    ) -> SessionProcessActivity? {
        let admitted = SessionProcessAdmissionPolicy.admitted(activities)
        if let exact = admitted.first(where: { $0.processId == selected.processId }) { return exact }
        guard selected.kind == .subagent,
              let toolCallID = selected.toolCallId,
              let runID = selected.runId else { return nil }
        let successors = admitted.filter {
            $0.kind == .subagent
                && $0.toolCallId == toolCallID
                && $0.runId == runID
                && $0.processId != selected.processId
        }
        return successors.count == 1 ? successors[0] : nil
    }

    static func precedes(_ lhs: SessionProcessActivity, _ rhs: SessionProcessActivity) -> Bool {
        let lhsBucket = lhs.visibility == .active ? 0 : 1
        let rhsBucket = rhs.visibility == .active ? 0 : 1
        if lhsBucket != rhsBucket { return lhsBucket < rhsBucket }
        let lhsProblem = lhs.lifecycle.attention == .needsAttention || lhs.lifecycle.state.isProblem
        let rhsProblem = rhs.lifecycle.attention == .needsAttention || rhs.lifecycle.state.isProblem
        if lhsProblem != rhsProblem { return lhsProblem }
        let lhsTime = lhs.lifecycle.terminalAt ?? lhs.lifecycle.observedAt
        let rhsTime = rhs.lifecycle.terminalAt ?? rhs.lifecycle.observedAt
        if lhsTime != rhsTime { return lhsTime > rhsTime }
        return lhs.processId < rhs.processId
    }
}

/// Local rendering deadline only. Gateway snapshots/deltas remain authoritative;
/// this may hide stale recent chrome but can never extend or promote it.
struct SessionProcessVisualDeadline: Sendable {
    let visibility: SessionProcessOverviewVisibility
    let deadline: ContinuousClock.Instant?

    init(overview: SessionProcessOverview, now: ContinuousClock.Instant = .now, wallNow: Date = .now) {
        visibility = overview.visibility
        if overview.visibility == .recent,
           let expiry = overview.nearestExpiry.flatMap(GatewayTimestamp.parse) {
            let remaining = max(0, Int(expiry.timeIntervalSince(wallNow) * 1_000))
            deadline = remaining > 0 ? now.advanced(by: .milliseconds(remaining)) : now
        } else {
            deadline = nil
        }
    }

    func expired(at now: ContinuousClock.Instant = .now) -> Bool {
        visibility == .recent && deadline.map { now >= $0 } ?? false
    }
}
