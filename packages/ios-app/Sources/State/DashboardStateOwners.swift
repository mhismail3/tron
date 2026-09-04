import Foundation

/// Requires the mounted chat generation to retire before a different route mounts.
struct SessionRouteReplacementOwner: Equatable {
    private struct Pending: Equatable {
        let retiringRouteID: String
        let retiringToken: PresentationSurfaceToken?
        let replacement: AppModel.SessionNavigationRoute
    }

    enum RequestAction: Equatable {
        case present(AppModel.SessionNavigationRoute)
        case dismissCurrent
        case waitForRetirement
    }

    private var pending: Pending?

    mutating func request(
        current: AppModel.SessionNavigationRoute?,
        currentToken: PresentationSurfaceToken?,
        replacement: AppModel.SessionNavigationRoute
    ) -> RequestAction {
        guard let current else {
            if let pending {
                self.pending = Pending(
                    retiringRouteID: pending.retiringRouteID,
                    retiringToken: pending.retiringToken,
                    replacement: replacement
                )
                return .waitForRetirement
            }
            return .present(replacement)
        }
        guard current.id != replacement.id else {
            pending = nil
            return .present(replacement)
        }
        pending = Pending(
            retiringRouteID: current.id,
            retiringToken: currentToken,
            replacement: replacement
        )
        return .dismissCurrent
    }

    mutating func completeRetirement(
        routeID: String,
        token: PresentationSurfaceToken
    ) -> AppModel.SessionNavigationRoute? {
        guard let pending,
              pending.retiringRouteID == routeID,
              pending.retiringToken == nil || pending.retiringToken == token else { return nil }
        self.pending = nil
        return pending.replacement
    }

    mutating func invalidate() {
        pending = nil
    }
}

/// Admits only the latest asynchronous dashboard navigation intent.
struct DashboardNavigationOwner: Equatable {
    private var generation = 0

    mutating func begin() -> Int {
        generation &+= 1
        return generation
    }

    mutating func invalidate() {
        generation &+= 1
    }

    mutating func admit(_ requestedGeneration: Int) -> Bool {
        guard requestedGeneration == generation else { return false }
        generation &+= 1
        return true
    }
}

enum SessionCatalogFreshness: Equatable, Sendable {
    case cached
    case stale
    case live
}

enum DashboardSessionActivity: Equatable, Sendable {
    case idle
    case active
    case waitingForUser
    case subagentsWorking
    case resuming
    case interrupted
}

struct DashboardPresentationSnapshot: Equatable {
    var sessions: [SessionSummary] = []
    var activityByDashboardID: [String: DashboardSessionActivity] = [:]

    func activity(for session: SessionSummary) -> DashboardSessionActivity {
        activityByDashboardID[session.dashboardID] ?? .idle
    }
}

enum DashboardActivityClock {
    /// Relative labels age while the dashboard is otherwise idle. Gateway live
    /// summaries still drive exact activity timestamps and row reordering.
    static let refreshInterval: TimeInterval = 30
}

enum DashboardServerConnectionState: Equatable, Sendable {
    case connecting
    case reconnecting
    case restarting
    case connected
    case offline
    case stale
    case blocked
    case identityMismatch
    case needsVerification
    case disabled

    var label: String {
        switch self {
        case .connecting: "Connecting"
        case .reconnecting: "Reconnecting"
        case .restarting: "Restarting"
        case .connected: "Connected"
        case .offline: "Offline"
        case .stale: "Cached"
        case .blocked: "Blocked (same Mac)"
        case .identityMismatch: "Identity changed"
        case .needsVerification: "Select to identify"
        case .disabled: "Disabled"
        }
    }
}

enum DashboardProjectionRetentionPolicy {
    /// Background connection retirement is not deletion. Keep an existing
    /// bounded dashboard bucket while a profile is reconnecting, blocked, or
    /// otherwise temporarily unavailable.
    static func retainsExistingBucket(
        profileExists: Bool,
        existingSessionCount: Int,
        incomingSessionCount: Int,
        state: DashboardServerConnectionState
    ) -> Bool {
        profileExists
            && existingSessionCount > 0
            && incomingSessionCount == 0
            && [.connecting, .reconnecting, .restarting, .offline, .stale].contains(state)
    }
}

struct DashboardServerSource: Identifiable, Equatable, Sendable {
    let profileID: String
    let label: String
    let sessionCount: Int
    let state: DashboardServerConnectionState

    var id: String { profileID }
}

enum DashboardSessionSortMode: String, CaseIterable, Identifiable, Sendable {
    case projectServer = "By Project / Server"
    case recent = "Recent Activity"

    var id: String { rawValue }
    var detail: String {
        switch self {
        case .projectServer: "Group sessions by project folder and server."
        case .recent: "Show active sessions first, then the newest history across servers."
        }
    }
}

enum AutomationDashboardViewMode: String, CaseIterable, Identifiable, Sendable {
    case upcoming = "Upcoming"
    case all = "All"

    var id: String { rawValue }
}

enum AutomationInventoryFilter: String, CaseIterable, Identifiable, Sendable {
    case all = "All"
    case active = "Active"
    case attention = "Needs attention"
    case drafts = "Drafts"
    case paused = "Paused"
    case completed = "Completed"

    var id: String { rawValue }

    func matches(_ summary: GatewayAutomationSummary) -> Bool {
        switch self {
        case .all: true
        case .active: summary.activation == .enabled
        case .attention: summary.isAttentionRequired
        case .drafts: summary.activation == .draft
        case .paused: summary.activation == .paused
        case .completed: summary.activation == .completed
        }
    }
}

struct AutomationDashboardViewPreferences: Equatable, Sendable {
    var mode: AutomationDashboardViewMode = .upcoming
    var inventoryFilter: AutomationInventoryFilter = .all
    var actionFilter: AutomationActionKind?
    var selectedProfileID: String?

    func effectiveProfileID(eligibleProfileIDs: Set<String>) -> String? {
        guard let selectedProfileID, eligibleProfileIDs.contains(selectedProfileID) else { return nil }
        return selectedProfileID
    }

    mutating func reconcile(knownProfileIDs: [String]) {
        let known = Set(knownProfileIDs)
        guard !known.isEmpty,
              let selectedProfileID,
              !known.contains(selectedProfileID) else { return }
        self.selectedProfileID = nil
    }
}

enum AutomationDashboardPreferences {
    private struct Document: Codable {
        let version: Int
        let mode: String
        let inventoryFilter: String
        let actionFilter: String?
        let selectedProfileID: String?
    }

    static let documentKey = "dashboard.automations.preferences.v1"
    private static let version = 1
    private static let maximumProfileIDBytes = 160
    private static let maximumDocumentBytes = 4 * 1024

    static func load(from defaults: UserDefaults = .standard) -> AutomationDashboardViewPreferences {
        guard let data = defaults.data(forKey: documentKey),
              data.count <= maximumDocumentBytes,
              let document = try? JSONDecoder().decode(Document.self, from: data),
              document.version == version,
              let mode = AutomationDashboardViewMode(rawValue: document.mode),
              let inventoryFilter = AutomationInventoryFilter(rawValue: document.inventoryFilter) else {
            return AutomationDashboardViewPreferences()
        }

        let actionFilter: AutomationActionKind?
        if let storedActionFilter = document.actionFilter {
            guard let decoded = AutomationActionKind(rawValue: storedActionFilter) else {
                return AutomationDashboardViewPreferences()
            }
            actionFilter = decoded
        } else {
            actionFilter = nil
        }
        if let selectedProfileID = document.selectedProfileID,
           !admitsProfileID(selectedProfileID) {
            return AutomationDashboardViewPreferences()
        }

        return AutomationDashboardViewPreferences(
            mode: mode,
            inventoryFilter: inventoryFilter,
            actionFilter: actionFilter,
            selectedProfileID: document.selectedProfileID
        )
    }

    static func save(
        _ preferences: AutomationDashboardViewPreferences,
        to defaults: UserDefaults = .standard
    ) {
        guard preferences.selectedProfileID.map(admitsProfileID) ?? true else { return }
        let document = Document(
            version: version,
            mode: preferences.mode.rawValue,
            inventoryFilter: preferences.inventoryFilter.rawValue,
            actionFilter: preferences.actionFilter?.rawValue,
            selectedProfileID: preferences.selectedProfileID
        )
        guard let data = try? JSONEncoder().encode(document),
              data.count <= maximumDocumentBytes else { return }
        defaults.set(data, forKey: documentKey)
    }

    private static func admitsProfileID(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= maximumProfileIDBytes
    }
}

struct AutomationDashboardPreferencesOwner {
    private let defaults: UserDefaults
    private(set) var value: AutomationDashboardViewPreferences

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        value = AutomationDashboardPreferences.load(from: defaults)
    }

    mutating func set(_ value: AutomationDashboardViewPreferences) {
        self.value = value
        AutomationDashboardPreferences.save(value, to: defaults)
    }
}

enum DashboardServerFilterPreferences {
    private struct Document: Codable {
        let version: Int
        let sortMode: String
        let selectedProfileIDs: [String]
    }

    static let documentKey = "dashboard.serverFilter.preferences.v2"
    static let legacySortModeKey = "dashboard.serverFilter.sortMode.v1"
    private static let version = 1
    private static let maximumProfileCount = 128
    private static let maximumProfileIDBytes = 160
    private static let maximumDocumentBytes = 32 * 1024

    static func load(from defaults: UserDefaults = .standard) -> DashboardServerFilterState {
        if let data = defaults.data(forKey: documentKey),
           data.count <= maximumDocumentBytes,
           let document = try? JSONDecoder().decode(Document.self, from: data),
           document.version == version,
           document.selectedProfileIDs.count <= maximumProfileCount,
           Set(document.selectedProfileIDs).count == document.selectedProfileIDs.count,
           document.selectedProfileIDs.allSatisfy(Self.admitsProfileID),
           let sortMode = DashboardSessionSortMode(rawValue: document.sortMode) {
            return DashboardServerFilterState(
                selectedProfileIDs: Set(document.selectedProfileIDs),
                sortMode: sortMode
            )
        }
        let legacy = defaults.string(forKey: legacySortModeKey)
            .flatMap(DashboardSessionSortMode.init(rawValue:))
            ?? .projectServer
        return DashboardServerFilterState(sortMode: legacy)
    }

    static func save(_ state: DashboardServerFilterState, to defaults: UserDefaults = .standard) {
        let selected = state.selectedProfileIDs.sorted()
        guard selected.count <= maximumProfileCount,
              selected.allSatisfy(admitsProfileID) else { return }
        let document = Document(version: version, sortMode: state.sortMode.rawValue, selectedProfileIDs: selected)
        guard let data = try? JSONEncoder().encode(document), data.count <= maximumDocumentBytes else { return }
        defaults.set(data, forKey: documentKey)
        defaults.removeObject(forKey: legacySortModeKey)
    }

    private static func admitsProfileID(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= maximumProfileIDBytes
    }
}

struct DashboardServerFilterState: Equatable, Sendable {
    private(set) var selectedProfileIDs: Set<String>
    private var availableProfileIDs: Set<String> = []
    private(set) var sortMode: DashboardSessionSortMode

    init(
        selectedProfileIDs: Set<String> = [],
        sortMode: DashboardSessionSortMode = .projectServer
    ) {
        self.selectedProfileIDs = selectedProfileIDs
        self.sortMode = sortMode
    }

    var isFiltering: Bool { !selectedProfileIDs.isEmpty || sortMode != .projectServer }
    var isAllSelected: Bool { selectedProfileIDs.isEmpty }
    var accessibilityLabel: String {
        let serverSelection = isAllSelected
            ? "all servers selected"
            : "\(selectedProfileIDs.count) servers selected"
        let ordering = sortMode == .recent ? ", recent activity order" : ""
        return "Filter servers, \(serverSelection)\(ordering)"
    }

    mutating func reconcile(profileIDs: [String]) {
        let admitted = Set(profileIDs)
        availableProfileIDs = admitted
        // An empty source list is a transient startup/offline projection. Keep
        // the persisted choice until an authoritative non-empty set can
        // reconcile removed or re-paired profiles.
        guard !admitted.isEmpty else { return }
        selectedProfileIDs = selectedProfileIDs.intersection(admitted)
        if selectedProfileIDs.count == admitted.count { selectedProfileIDs.removeAll() }
    }

    func allows(_ profileID: String?) -> Bool {
        guard let profileID else { return selectedProfileIDs.isEmpty }
        return selectedProfileIDs.isEmpty || selectedProfileIDs.contains(profileID)
    }

    func allows(_ profileID: String?, selectedProfileID: String?) -> Bool {
        allows(profileID ?? selectedProfileID)
    }

    func isSelected(_ profileID: String) -> Bool {
        selectedProfileIDs.isEmpty || selectedProfileIDs.contains(profileID)
    }

    mutating func selectAll() { selectedProfileIDs.removeAll() }

    mutating func setSortMode(_ mode: DashboardSessionSortMode) {
        sortMode = mode
    }

    mutating func toggle(_ profileID: String) {
        if selectedProfileIDs.isEmpty {
            selectedProfileIDs = availableProfileIDs.subtracting([profileID])
        } else if selectedProfileIDs.contains(profileID) {
            selectedProfileIDs.remove(profileID)
        } else {
            selectedProfileIDs.insert(profileID)
        }
        if selectedProfileIDs.count == availableProfileIDs.count { selectedProfileIDs.removeAll() }
    }
}

enum SessionCatalogRefreshOutcome: Equatable, Sendable {
    case published
    case retained
    case transportFailure
}

struct SessionCatalogLoadKey: Equatable, Sendable {
    let profileID: String
    let lifecycleGeneration: Int
    let connectionID: Int
}

/// Owns the bounded dashboard projection, revisioned global row overlays, and
/// exact admission for one catalog materialization. Gateway remains canonical.
struct SessionCatalogCoordinator: Equatable {
    struct LoadAdmission: Equatable, Sendable {
        fileprivate let generation: Int
        fileprivate let key: SessionCatalogLoadKey?
    }

    enum SummaryUpdateAdmission: Equatable, Sendable {
        case stale
        case unknownSession
        case updated
    }

    private(set) var sessions: [SessionSummary] = []
    private(set) var freshness: SessionCatalogFreshness = .stale
    private var indicesByID: [String: Int] = [:]
    private var liveUpdates: [String: SessionSummaryUpdate] = [:]
    private var liveSessionIDs: Set<String> = []
    private var loadGeneration = 0

    mutating func beginLoad(key: SessionCatalogLoadKey? = nil) -> LoadAdmission {
        loadGeneration &+= 1
        return LoadAdmission(generation: loadGeneration, key: key)
    }

    mutating func invalidateLoads() {
        loadGeneration &+= 1
    }

    func admits(_ admission: LoadAdmission, key: SessionCatalogLoadKey? = nil) -> Bool {
        admission.generation == loadGeneration
            && (key == nil || admission.key == key)
    }

    func activity(for sessionID: String) -> DashboardSessionActivity {
        guard let index = indicesByID[sessionID], sessions.indices.contains(index) else { return .idle }
        let phase = sessions[index].phase
        let isLive = freshness == .live || liveSessionIDs.contains(sessionID)
        guard isLive else {
            return phase == .idle ? .idle : .resuming
        }
        if sessions[index].waitingForUser { return .waitingForUser }
        if phase.isActive {
            return sessions[index].hasOnlyActiveSubagents ? .subagentsWorking : .active
        }
        return phase == .interrupted ? .interrupted : .idle
    }

    @discardableResult
    mutating func publishAuthoritative(
        _ authoritative: [SessionSummary],
        admission: LoadAdmission
    ) -> Bool {
        guard admits(admission, key: admission.key) else { return false }
        let ids = Set(authoritative.map(\.id))
        liveUpdates = liveUpdates.filter { ids.contains($0.key) }
        sessions = authoritative.map { summary in
            guard let update = liveUpdates[summary.id],
                  update.summaryRevision > (summary.summaryRevision ?? 0) else { return summary }
            return applying(update, to: summary)
        }
        rebuildIndex()
        liveSessionIDs = ids
        freshness = .live
        return true
    }

    mutating func apply(_ update: SessionSummaryUpdate) -> SummaryUpdateAdmission {
        if let current = liveUpdates[update.sessionId],
           update.summaryRevision <= current.summaryRevision {
            return .stale
        }
        if let index = indicesByID[update.sessionId], sessions.indices.contains(index),
           update.summaryRevision <= (sessions[index].summaryRevision ?? 0) {
            return .stale
        }
        let retained = liveUpdates[update.sessionId]
        let admitted = retained.map { merging(update, preservingAttentionFrom: $0) } ?? update
        liveUpdates[update.sessionId] = admitted
        liveSessionIDs.insert(update.sessionId)
        guard let index = indicesByID[update.sessionId], sessions.indices.contains(index) else {
            return .unknownSession
        }
        sessions[index] = applying(admitted, to: sessions[index])
        return .updated
    }

    /// Applies the authoritative attention mutation response without inventing
    /// a row for an unknown session. Attention revisions are independent of
    /// summary revisions, so a late response cannot overwrite newer state.
    @discardableResult
    mutating func applyAttention(
        sessionID: String,
        _ projection: SessionAttentionProjection
    ) -> Bool {
        guard let index = indicesByID[sessionID], sessions.indices.contains(index) else { return false }
        let current = sessions[index]
        guard projection.attentionRevision > current.attentionRevision,
              projection.completionRevision >= current.completionRevision else { return false }
        if let update = liveUpdates[sessionID] {
            guard projection.attentionRevision > update.attentionRevision,
                  projection.completionRevision >= update.completionRevision else { return false }
            liveUpdates[sessionID] = SessionSummaryUpdate(
                sessionId: update.sessionId,
                summaryRevision: update.summaryRevision,
                phase: update.phase,
                foregroundPhase: update.foregroundPhase,
                hasActiveSubagents: update.hasActiveSubagents,
                waitingForUser: update.waitingForUser,
                name: update.name,
                updatedAt: update.updatedAt,
                activeSince: update.activeSince,
                messageCount: update.messageCount,
                firstMessage: update.firstMessage,
                completionRevision: projection.completionRevision,
                attentionRevision: projection.attentionRevision,
                isUnread: projection.isUnread
            )
        }
        sessions[index] = SessionSummary(
            id: current.id,
            name: current.name,
            cwd: current.cwd,
            kind: current.kind,
            parentSessionId: current.parentSessionId,
            creationOrigin: current.creationOrigin,
            createdAt: current.createdAt,
            updatedAt: current.updatedAt,
            activeSince: current.activeSince,
            messageCount: current.messageCount,
            firstMessage: current.firstMessage,
            phase: current.phase,
            foregroundPhase: current.foregroundPhase,
            hasActiveSubagents: current.hasActiveSubagents,
            waitingForUser: current.waitingForUser,
            summaryRevision: current.summaryRevision,
            completionRevision: projection.completionRevision,
            attentionRevision: projection.attentionRevision,
            isUnread: projection.isUnread,
            gatewayProfileID: current.gatewayProfileID,
            gatewayProfileLabel: current.gatewayProfileLabel
        )
        liveSessionIDs.insert(sessionID)
        return true
    }

    mutating func installCached(_ cached: [SessionSummary]) {
        invalidateLoads()
        liveUpdates.removeAll()
        liveSessionIDs.removeAll()
        sessions = cached
        rebuildIndex()
        freshness = .cached
    }

    mutating func markDisconnected() {
        invalidateLoads()
        liveUpdates.removeAll()
        liveSessionIDs.removeAll()
        freshness = .stale
    }

    mutating func remove(_ sessionID: String) {
        invalidateLoads()
        liveUpdates.removeValue(forKey: sessionID)
        liveSessionIDs.remove(sessionID)
        guard let index = indicesByID[sessionID], sessions.indices.contains(index) else { return }
        sessions.remove(at: index)
        rebuildIndex()
    }

    mutating func replaceForFacade(_ replacement: [SessionSummary]) {
        invalidateLoads()
        liveUpdates.removeAll()
        sessions = replacement
        rebuildIndex()
        liveSessionIDs = Set(replacement.map(\.id))
        freshness = .live
    }

    mutating func clear() {
        invalidateLoads()
        liveUpdates.removeAll()
        liveSessionIDs.removeAll()
        sessions.removeAll()
        indicesByID.removeAll()
        freshness = .stale
    }

    func hasConsistentIndex() -> Bool {
        indicesByID.count == sessions.count
            && sessions.enumerated().allSatisfy { indicesByID[$0.element.id] == $0.offset }
    }

    private mutating func rebuildIndex() {
        indicesByID = Dictionary(uniqueKeysWithValues: sessions.enumerated().map { ($0.element.id, $0.offset) })
    }

    private func merging(
        _ update: SessionSummaryUpdate,
        preservingAttentionFrom prior: SessionSummaryUpdate
    ) -> SessionSummaryUpdate {
        let preserve = update.completionRevision < prior.completionRevision
            || update.attentionRevision < prior.attentionRevision
        return SessionSummaryUpdate(
            sessionId: update.sessionId,
            summaryRevision: update.summaryRevision,
            phase: update.phase,
            foregroundPhase: update.foregroundPhase,
            hasActiveSubagents: update.hasActiveSubagents,
            waitingForUser: update.waitingForUser,
            name: update.name,
            updatedAt: update.updatedAt,
            activeSince: update.activeSince,
            messageCount: update.messageCount,
            firstMessage: update.firstMessage,
            completionRevision: preserve ? prior.completionRevision : update.completionRevision,
            attentionRevision: preserve ? prior.attentionRevision : update.attentionRevision,
            isUnread: preserve ? prior.isUnread : update.isUnread
        )
    }

    private func applying(
        _ update: SessionSummaryUpdate,
        to summary: SessionSummary
    ) -> SessionSummary {
        let preserve = update.completionRevision < summary.completionRevision
            || update.attentionRevision < summary.attentionRevision
        return SessionSummary(
            id: summary.id,
            name: update.name,
            cwd: summary.cwd,
            kind: summary.kind,
            parentSessionId: summary.parentSessionId,
            creationOrigin: summary.creationOrigin,
            createdAt: summary.createdAt,
            updatedAt: update.updatedAt,
            activeSince: update.activeSince,
            messageCount: update.messageCount,
            firstMessage: update.firstMessage,
            phase: update.phase,
            foregroundPhase: update.foregroundPhase,
            hasActiveSubagents: update.hasActiveSubagents,
            waitingForUser: update.waitingForUser,
            summaryRevision: update.summaryRevision,
            completionRevision: preserve ? summary.completionRevision : update.completionRevision,
            attentionRevision: preserve ? summary.attentionRevision : update.attentionRevision,
            isUnread: preserve ? summary.isUnread : update.isUnread,
            gatewayProfileID: summary.gatewayProfileID,
            gatewayProfileLabel: summary.gatewayProfileLabel
        )
    }
}
