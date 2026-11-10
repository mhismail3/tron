import Foundation
import SwiftUI
import TronMobileCore

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

struct DashboardActivityClock: TimelineSchedule {
    static let changeSearchHorizon: TimeInterval = 400 * 86_400

    let updatedAt: Date?

    init(updatedAt: String) {
        self.updatedAt = GatewayTimestamp.parse(updatedAt)
    }

    func label(relativeTo reference: Date) -> String {
        updatedAt.map { GatewayTimestamp.relativeDescription($0, relativeTo: reference) } ?? ""
    }

    func entries(from startDate: Date, mode _: TimelineScheduleMode) -> Entries {
        Entries(clock: self, start: startDate)
    }

    struct Entries: Sequence, IteratorProtocol {
        let clock: DashboardActivityClock
        let start: Date
        private var previous: Date?

        init(clock: DashboardActivityClock, start: Date) {
            self.clock = clock
            self.start = start
        }

        mutating func next() -> Date? {
            guard let previous else {
                previous = start
                return start
            }
            guard let updatedAt = clock.updatedAt else { return nil }
            let change = PresentationLabelChange.next(
                after: previous,
                horizon: DashboardActivityClock.changeSearchHorizon,
                lattice: updatedAt,
                label: clock.label(relativeTo:)
            )
            self.previous = change
            return change
        }
    }
}

enum DashboardProjectionRetentionPolicy {
    static func retainsExistingBucket(
        profileExists: Bool,
        existingSessionCount: Int,
        incomingSessionCount: Int,
        state: DashboardServerConnectionState
    ) -> Bool {
        let unavailable: Bool
        switch state {
        case .connecting, .reconnecting, .noPath, .restarting, .offline, .stale:
            unavailable = true
        default:
            unavailable = false
        }
        return profileExists
            && existingSessionCount > 0
            && incomingSessionCount == 0
            && unavailable
    }
}

struct DashboardServerSource: Identifiable, Equatable, Sendable {
    let profileID: String
    let label: String
    let sessionCount: Int
    let state: DashboardServerConnectionState
    let capabilities: Set<String>

    var id: String { profileID }
}

enum DashboardSessionSortMode: String, CaseIterable, Identifiable, Sendable {
    case home = "Home"
    case projectServer = "By Project / Server"
    case recent = "Recent Activity"

    var id: String { rawValue }
    var detail: String {
        switch self {
        case .home: "Usage, Home’s running and recently finished workers, then other sessions, read or unread."
        case .projectServer: "Group sessions by project folder and server."
        case .recent: "Show active sessions first, then the newest history across servers."
        }
    }
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
        return DashboardServerFilterState(sortMode: .home)
    }

    static func save(_ state: DashboardServerFilterState, to defaults: UserDefaults = .standard) {
        let selected = state.selectedProfileIDs.sorted()
        guard selected.count <= maximumProfileCount,
              selected.allSatisfy(admitsProfileID) else { return }
        let document = Document(version: version, sortMode: state.sortMode.rawValue, selectedProfileIDs: selected)
        guard let data = try? JSONEncoder().encode(document), data.count <= maximumDocumentBytes else { return }
        defaults.set(data, forKey: documentKey)
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
        sortMode: DashboardSessionSortMode = .home
    ) {
        self.selectedProfileIDs = selectedProfileIDs
        self.sortMode = sortMode
    }

    var isAllSelected: Bool { selectedProfileIDs.isEmpty }
    mutating func reconcile(profileIDs: [String]) {
        let admitted = Set(profileIDs)
        availableProfileIDs = admitted
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

enum SessionCatalogLoadBounds {
    static let pageSize = 500
    static let maximumPages = 50
    static let maximumRows = 25_000
}

enum SessionCatalogLoadResult: Sendable {
    case loaded(rows: [SessionSummary], pageCount: Int, revision: Int, projectionToken: String, archivedCount: Int?)
    case unchanged(revision: Int)
    case revisionMoved(pageCount: Int, revision: Int?)
    case retired
    case invalid(code: String, reason: String, pageCount: Int, revision: Int?)
}

enum SessionCatalogLoader {
    private struct Params: Encodable {
        let cursor: String?
        let limit: Int
        let scope: String
        let projectionToken: String?
    }
    private struct Response: Decodable {
        let sessions: [SessionSummary]
        let nextCursor: String?
        let listRevision: Int
        let projectionToken: String
        let notModified: Bool?
        let archivedCount: Int?
    }

    static func load(
        client: GatewayClient,
        scope: String = "user",
        sinceToken: String? = nil,
        admitsPublication: @MainActor () -> Bool
    ) async throws -> SessionCatalogLoadResult {
        for revisionAttempt in 0..<2 {
            var all: [SessionSummary] = []
            var cursor: String?
            var seenCursors = Set<String>()
            var seenSessionIDs = Set<String>()
            var expectedToken: String?
            var latestRevision: Int?
            var archivedCount: Int?
            var pageCount = 0
            var revisionChanged = false
            repeat {
                guard pageCount < SessionCatalogLoadBounds.maximumPages else {
                    return .invalid(code: "limit_exceeded", reason: "page-budget", pageCount: pageCount, revision: latestRevision)
                }
                let requestedCursor = cursor
                let response: Response
                do {
                    response = try await client.request(
                        "session.list",
                        Params(
                            cursor: cursor,
                            limit: SessionCatalogLoadBounds.pageSize,
                            scope: scope,
                            projectionToken: cursor == nil ? sinceToken : nil
                        ),
                        correlation: SessionListCorrelation.dashboardCatalog
                    )
                } catch let failure as GatewayFailure
                    where requestedCursor != nil && failure.code == "invalid_request" && revisionAttempt == 0 {
                    guard await admitsPublication() else { return .retired }
                    revisionChanged = true
                    break
                }
                guard await admitsPublication() else { return .retired }
                if response.notModified == true {
                    guard cursor == nil, pageCount == 0, let sinceToken,
                          response.projectionToken == sinceToken,
                          response.sessions.isEmpty, response.nextCursor == nil, response.archivedCount == nil else {
                        return .invalid(code: "invalid_response", reason: "session-list-not-modified", pageCount: pageCount, revision: response.listRevision)
                    }
                    return .unchanged(revision: response.listRevision)
                }
                pageCount += 1
                guard !response.projectionToken.isEmpty else {
                    return .invalid(code: "invalid_response", reason: "session-list-token", pageCount: pageCount, revision: response.listRevision)
                }
                if let expectedToken, expectedToken != response.projectionToken {
                    revisionChanged = true
                    break
                }
                expectedToken = response.projectionToken
                latestRevision = response.listRevision
                guard response.sessions.count <= SessionCatalogLoadBounds.pageSize,
                      all.count <= SessionCatalogLoadBounds.maximumRows - response.sessions.count,
                      response.archivedCount.map({ $0 >= 0 && $0 <= SessionCatalogLoadBounds.maximumRows }) ?? true,
                      response.sessions.allSatisfy({ $0.archivedAt == nil }),
                      response.sessions.allSatisfy({ seenSessionIDs.insert($0.id).inserted }) else {
                    return .invalid(code: "invalid_response", reason: "session-list-page", pageCount: pageCount, revision: latestRevision)
                }
                if archivedCount == nil { archivedCount = response.archivedCount }
                all.append(contentsOf: response.sessions)
                cursor = response.nextCursor
                if let cursor, !seenCursors.insert(cursor).inserted {
                    return .invalid(code: "invalid_response", reason: "repeated-cursor", pageCount: pageCount, revision: latestRevision)
                }
            } while cursor != nil

            if revisionChanged {
                if revisionAttempt == 0 { continue }
                return .revisionMoved(pageCount: pageCount, revision: latestRevision)
            }
            guard let token = expectedToken else {
                return .invalid(code: "invalid_response", reason: "session-list-empty", pageCount: pageCount, revision: latestRevision)
            }
            return .loaded(rows: all, pageCount: pageCount, revision: latestRevision ?? 0, projectionToken: token, archivedCount: archivedCount)
        }
        return .revisionMoved(pageCount: 0, revision: nil)
    }
}

enum SessionArchiveTargetLookup {
    static let maximumPages = 5
}

enum ArchivedSessionsLoadResult: Sendable {
    case loaded(page: ArchivedSessionsPage)
    case retired
    case invalid(code: String, reason: String)
}

struct ArchivedSessionsPage: Equatable, Sendable {
    let sessions: [SessionSummary]
    let nextCursor: String?
}

enum ArchivedSessionsLoader {
    struct PageRequest: Encodable {
        let cursor: String?
        let limit: Int
        let scope: String
        let archived: String
    }

    struct PageResponse: Decodable {
        let sessions: [SessionSummary]
        let nextCursor: String?
    }

    static let pageSize = 200

    static func admit(
        _ response: PageResponse,
        requestedCursor: String?,
        admitsPublication: @MainActor () -> Bool
    ) async -> ArchivedSessionsLoadResult {
        guard await admitsPublication() else { return .retired }
        guard response.sessions.count <= pageSize,
              response.sessions.allSatisfy({ $0.kind == .user && $0.isArchived }) else {
            return .invalid(code: "invalid_response", reason: "archived-session-page")
        }
        if let nextCursor = response.nextCursor {
            guard !nextCursor.isEmpty, nextCursor != requestedCursor else {
                return .invalid(code: "invalid_response", reason: "repeated-cursor")
            }
        }
        return .loaded(page: ArchivedSessionsPage(sessions: response.sessions, nextCursor: response.nextCursor))
    }
}

enum SessionArchiveCountProjection {
    static func total(countsByProfile: [String: Int], capableProfileIDs: Set<String>) -> Int? {
        var total = 0
        var counted = false
        for profileID in capableProfileIDs.sorted() {
            guard let count = countsByProfile[profileID], count >= 0 else { continue }
            total += count
            counted = true
        }
        return counted ? total : nil
    }
}

struct ArchivedSessionsProfileSource: Equatable, Identifiable, Sendable {
    let profileID: String
    let label: String
    let isConnected: Bool

    var id: String { profileID }
}

enum SessionArchiveReadPurpose: String, CaseIterable, Hashable, Sendable {
    case container
    case targetLookup
}

struct SessionArchiveReadKey: Hashable, Sendable {
    let profileID: String
    let purpose: SessionArchiveReadPurpose
}

enum SessionListCorrelation {
    static let dashboardCatalog = "dashboard-catalog"
}

struct ArchivedSessionsContainerState: Equatable {
    private(set) var isExpanded = false
    private(set) var isLoading = false
    private(set) var rowsByProfile: [String: [SessionSummary]] = [:]
    private(set) var nextCursorByProfile: [String: String] = [:]
    private(set) var unavailableProfileIDs: Set<String> = []
    private var generation = 0

    var rows: [SessionSummary] {
        rowsByProfile.values.flatMap { $0 }.sorted { left, right in
            let leftInstant = left.archivedAt.flatMap(GatewayTimestamp.parse)
            let rightInstant = right.archivedAt.flatMap(GatewayTimestamp.parse)
            switch (leftInstant, rightInstant) {
            case let (leftDate?, rightDate?) where leftDate != rightDate:
                return leftDate > rightDate
            case (_?, nil): return true
            case (nil, _?): return false
            default: return left.dashboardID < right.dashboardID
            }
        }
    }

    var hasMore: Bool { !nextCursorByProfile.isEmpty }

    var currentGeneration: Int { generation }

    func isCurrent(_ generation: Int) -> Bool { generation == self.generation }

    mutating func expand() {
        isExpanded = true
    }

    @discardableResult
    mutating func collapse() -> Int {
        let generation = retirePages()
        isExpanded = false
        rowsByProfile = [:]
        nextCursorByProfile = [:]
        unavailableProfileIDs = []
        return generation
    }

    @discardableResult
    mutating func retirePages() -> Int {
        generation &+= 1
        isLoading = false
        return generation
    }

    mutating func reconcile(_ sources: [ArchivedSessionsProfileSource]) {
        let readable = Set(sources.filter(\.isConnected).map(\.profileID))
        rowsByProfile = rowsByProfile.filter { readable.contains($0.key) }
        nextCursorByProfile = nextCursorByProfile.filter { readable.contains($0.key) }
        unavailableProfileIDs.formIntersection(Set(sources.map(\.profileID)))
        for source in sources where !source.isConnected {
            unavailableProfileIDs.insert(source.profileID)
        }
    }

    func pageRequests(
        for sources: [ArchivedSessionsProfileSource],
        more: Bool
    ) -> [(profileID: String, cursor: String?)] {
        sources.filter(\.isConnected).compactMap { source in
            guard more else { return (source.profileID, nil) }
            guard let cursor = nextCursorByProfile[source.profileID] else { return nil }
            return (source.profileID, cursor)
        }
    }

    mutating func beginLoading() { isLoading = true }

    mutating func finishLoading() { isLoading = false }

    @discardableResult
    mutating func apply(
        _ result: ArchivedSessionsLoadResult,
        profileID: String,
        generation: Int,
        requestedCursor: String?
    ) -> Bool {
        guard isCurrent(generation) else { return false }
        switch result {
        case let .loaded(page):
            rowsByProfile[profileID] = requestedCursor == nil
                ? page.sessions
                : Self.extending(rowsByProfile[profileID] ?? [], with: page.sessions)
            nextCursorByProfile[profileID] = page.nextCursor
            unavailableProfileIDs.remove(profileID)
            return true
        case .retired:
            return false
        case .invalid:
            unavailableProfileIDs.insert(profileID)
            return false
        }
    }

    mutating func markUnavailable(_ profileID: String) {
        unavailableProfileIDs.insert(profileID)
    }

    @discardableResult
    mutating func discardCursor(_ profileID: String) -> Bool {
        nextCursorByProfile.removeValue(forKey: profileID) != nil
    }

    @discardableResult
    mutating func reconcileCount(_ count: Int?) -> Bool {
        guard count == 0 else { return false }
        collapse()
        return true
    }

    private static func extending(
        _ rows: [SessionSummary],
        with page: [SessionSummary]
    ) -> [SessionSummary] {
        var seen = Set(rows.map(\.id))
        return rows + page.filter { seen.insert($0.id).inserted }
    }
}

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
    private(set) var archivedCount: Int?
    private var indicesByID: [String: Int] = [:]
    private var liveUpdates: [String: SessionSummaryUpdate] = [:]
    private var liveSessionIDs: Set<String> = []
    private var loadGeneration = 0
    private(set) var projectionToken: String?

    mutating func beginLoad(key: SessionCatalogLoadKey? = nil) -> LoadAdmission {
        loadGeneration &+= 1
        return LoadAdmission(generation: loadGeneration, key: key)
    }

    private mutating func dropProjectionToken() {
        projectionToken = nil
    }

    mutating func invalidateLoads() {
        loadGeneration &+= 1
        dropProjectionToken()
    }

    mutating func markLoadUnavailable() {
        freshness = .stale
        liveSessionIDs = Set(liveUpdates.keys)
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
        admission: LoadAdmission,
        projectionToken: String,
        archivedCount: Int? = nil
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
        self.archivedCount = archivedCount
        self.projectionToken = projectionToken
        freshness = .live
        return true
    }

    mutating func confirmUnchanged(admission: LoadAdmission) -> Bool {
        guard admits(admission, key: admission.key), projectionToken != nil else { return false }
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
            homeTaskId: current.homeTaskId,
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
            archivedAt: current.archivedAt,
            gatewayProfileID: current.gatewayProfileID,
            gatewayProfileLabel: current.gatewayProfileLabel
        )
        liveSessionIDs.insert(sessionID)
        return true
    }

    mutating func installCached(_ cached: [SessionSummary], archivedCount: Int? = nil) {
        invalidateLoads()
        liveUpdates.removeAll()
        liveSessionIDs.removeAll()
        sessions = cached
        rebuildIndex()
        self.archivedCount = archivedCount
        freshness = .cached
    }

    mutating func markDisconnected() {
        loadGeneration &+= 1
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

    mutating func markArchived(sessionID: String) {
        invalidateLoads()
        liveUpdates.removeValue(forKey: sessionID)
        liveSessionIDs.remove(sessionID)
        if let index = indicesByID[sessionID], sessions.indices.contains(index) {
            sessions.remove(at: index)
            rebuildIndex()
        }
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
        archivedCount = nil
        sessions.removeAll()
        indicesByID.removeAll()
        freshness = .stale
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
            homeTaskId: summary.homeTaskId,
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
            archivedAt: summary.archivedAt,
            gatewayProfileID: summary.gatewayProfileID,
            gatewayProfileLabel: summary.gatewayProfileLabel
        )
    }
}
