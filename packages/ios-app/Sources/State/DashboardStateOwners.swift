import Foundation
import SwiftUI

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

/// A dashboard row's relative-activity label and the `TimelineView` schedule
/// that re-renders the row exactly when that label can change: every second
/// while it shows seconds, then once a minute, an hour, a day and so on. The
/// change instants come from the shared formatter itself, never from assumed
/// unit boundaries. This visible-surface clock never changes catalog timestamps
/// or ordering.
struct DashboardActivityClock: TimelineSchedule {
    /// Longer than the formatter's slowest unit (a leap year plus a DST hour),
    /// so a search always reaches the next change; an unchanged horizon entry
    /// only re-renders the same text.
    static let changeSearchHorizon: TimeInterval = 400 * 86_400

    /// Parsed once per row value rather than on every render.
    let updatedAt: Date?

    init(updatedAt: String) {
        self.updatedAt = GatewayTimestamp.parse(updatedAt)
    }

    /// Malformed timestamps keep today's empty label and never schedule a tick.
    func label(relativeTo reference: Date) -> String {
        updatedAt.map { GatewayTimestamp.relativeDescription($0, relativeTo: reference) } ?? ""
    }

    func entries(from startDate: Date, mode _: TimelineScheduleMode) -> Entries {
        Entries(clock: self, start: startDate)
    }

    /// Yields the start, then each later instant at which the label changes.
    /// SwiftUI pulls one entry ahead, so each search runs as the previous
    /// change renders.
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

enum DashboardServerConnectionState: Hashable, Sendable {
    case connecting
    case reconnecting
    case noPath(String?)
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
        case .noPath(let interface): GatewayNoPathPresentation(interface: interface).label
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
    var searchIdentity: String { "\(selectedProfileIDs.sorted().joined(separator: ",")):\(sortMode.rawValue)" }
    var isAllSelected: Bool { selectedProfileIDs.isEmpty }
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
enum SessionCatalogLoadBounds {
    // Limits cap one user-list traversal while allowing the current 25,000-row catalog.
    static let pageSize = 500
    static let maximumPages = 50
    static let maximumRows = 25_000
}

enum SessionCatalogLoadResult: Sendable {
    case loaded(rows: [SessionSummary], pageCount: Int, revision: Int, archivedCount: Int?)
    case revisionMoved(pageCount: Int, revision: Int?)
    case retired
    case invalid(code: String, reason: String, pageCount: Int, revision: Int?)
}

enum SessionCatalogLoader {
    private struct Params: Encodable { let cursor: String?; let limit: Int; let scope: String }
    private struct Response: Decodable {
        let sessions: [SessionSummary]
        let nextCursor: String?
        let listRevision: Int
        /// Present on the first `exclude` page and nowhere else. Archived rows
        /// are not part of this projection, so the count is the only way the
        /// dashboard learns how many sessions are hidden.
        let archivedCount: Int?
    }

    static func load(
        client: GatewayClient,
        scope: String = "user",
        admitsPublication: @MainActor () -> Bool
    ) async throws -> SessionCatalogLoadResult {
        for revisionAttempt in 0..<2 {
            var all: [SessionSummary] = []
            var cursor: String?
            var seenCursors = Set<String>()
            var seenSessionIDs = Set<String>()
            var expectedRevision: Int?
            var archivedCount: Int?
            var pageCount = 0
            var revisionChanged = false
            repeat {
                guard pageCount < SessionCatalogLoadBounds.maximumPages else {
                    return .invalid(code: "limit_exceeded", reason: "page-budget", pageCount: pageCount, revision: expectedRevision)
                }
                let requestedCursor = cursor
                let response: Response
                do {
                    response = try await client.request(
                        "session.list",
                        Params(cursor: cursor, limit: SessionCatalogLoadBounds.pageSize, scope: scope),
                        correlation: SessionListCorrelation.dashboardCatalog
                    )
                } catch let failure as GatewayFailure
                    where requestedCursor != nil && failure.code == "invalid_request" && revisionAttempt == 0 {
                    guard await admitsPublication() else { return .retired }
                    revisionChanged = true
                    break
                }
                guard await admitsPublication() else { return .retired }
                pageCount += 1
                if let expectedRevision, expectedRevision != response.listRevision {
                    revisionChanged = true
                    break
                }
                expectedRevision = response.listRevision
                guard response.sessions.count <= SessionCatalogLoadBounds.pageSize,
                      all.count <= SessionCatalogLoadBounds.maximumRows - response.sessions.count,
                      response.archivedCount.map({ $0 >= 0 && $0 <= SessionCatalogLoadBounds.maximumRows }) ?? true,
                      // `exclude` hides archived sessions. A row that still
                      // carries archive state would leak a hidden session onto
                      // the dashboard, so the projection is rejected instead.
                      response.sessions.allSatisfy({ $0.archivedAt == nil }),
                      response.sessions.allSatisfy({ seenSessionIDs.insert($0.id).inserted }) else {
                    return .invalid(code: "invalid_response", reason: "session-list-page", pageCount: pageCount, revision: response.listRevision)
                }
                if archivedCount == nil { archivedCount = response.archivedCount }
                all.append(contentsOf: response.sessions)
                cursor = response.nextCursor
                if let cursor, !seenCursors.insert(cursor).inserted {
                    return .invalid(code: "invalid_response", reason: "repeated-cursor", pageCount: pageCount, revision: response.listRevision)
                }
            } while cursor != nil

            if revisionChanged {
                if revisionAttempt == 0 { continue }
                return .revisionMoved(pageCount: pageCount, revision: expectedRevision)
            }
            return .loaded(rows: all, pageCount: pageCount, revision: expectedRevision ?? 0, archivedCount: archivedCount)
        }
        return .revisionMoved(pageCount: 0, revision: nil)
    }
}

/// Bounds the archived-page walk that names a session the dashboard projection
/// cannot hold. A profile whose archived count exceeds this bound keeps the
/// existing fallback label instead of an unbounded read.
enum SessionArchiveTargetLookup {
    static let maximumPages = 5
}

enum ArchivedSessionsLoadResult: Sendable {
    case loaded(page: ArchivedSessionsPage)
    /// The read was superseded by a newer request or its surface retired it.
    case retired
    case invalid(code: String, reason: String)
}

struct ArchivedSessionsPage: Equatable, Sendable {
    let sessions: [SessionSummary]
    let nextCursor: String?
}

/// Reads the Gateway's `archived: "only"` projection for the dashboard's
/// archived container. The dashboard bucket never supplies these rows: it
/// excludes archived sessions by contract, so a page read is the only
/// authority for them. One call reads exactly one page; the container owns
/// expansion and the cursor. The caller's managed activity and its exact
/// latest-request fence are rechecked after every await, so a page that a newer
/// archive toggle already invalidated can never reach the surface.
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

    /// Admits one response. Pure apart from the caller's publication fence, so
    /// the bounds, the archived-rows contract, and cursor progress are testable
    /// without a transport.
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

/// Sums the Gateway-owned archived-session count across profiles. Only a
/// profile that advertises `session-archive.v1` and has a known count
/// contributes; `nil` therefore means "no archive projection yet", which the
/// dashboard must never present as a fabricated zero.
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

/// One archive-capable server the dashboard container can read. Only a live
/// connection may be read; a capable but unreachable Gateway is named as a note
/// instead of listing rows that may be stale.
struct ArchivedSessionsProfileSource: Equatable, Identifiable, Sendable {
    let profileID: String
    let label: String
    let isConnected: Bool

    var id: String { profileID }
}

/// The surface that owns one archived-projection read. Each purpose keeps its
/// own latest-request fence, so a container pass and the automation form's
/// bounded target lookup can never retire each other's read.
enum SessionArchiveReadPurpose: String, CaseIterable, Hashable, Sendable {
    case container
    case targetLookup
}

/// One profile's read fence for one archived-projection purpose.
struct SessionArchiveReadKey: Hashable, Sendable {
    let profileID: String
    let purpose: SessionArchiveReadPurpose
}

/// A correlation label for one `session.list` caller. The client keeps the
/// newest request identity per label, so a dashboard catalog failure diagnostic
/// names the catalog's own request instead of whatever read ran last.
enum SessionListCorrelation {
    static let dashboardCatalog = "dashboard-catalog"
}

/// Owns the dashboard's archived container: one collapsed disclosure plus the
/// per-profile pages it reads when expanded. Archive membership stays
/// Gateway-owned, so this owner holds only the current page projection and
/// every publish is checked against the expansion generation: a page that a
/// collapse or a newer pass already superseded can never reach the surface.
struct ArchivedSessionsContainerState: Equatable {
    private(set) var isExpanded = false
    private(set) var isLoading = false
    private(set) var rowsByProfile: [String: [SessionSummary]] = [:]
    private(set) var nextCursorByProfile: [String: String] = [:]
    /// Servers whose pages cannot be shown: a capable Gateway that is not
    /// connected, or one whose page read failed. The container names them
    /// inline rather than presenting stale rows.
    private(set) var unavailableProfileIDs: Set<String> = []
    private var generation = 0

    /// Rows in Gateway archive order (newest archived first). Ordering is
    /// identity-qualified because two servers can own equal session IDs.
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

    /// True while a server still has an unpublished page.
    var hasMore: Bool { !nextCursorByProfile.isEmpty }

    var currentGeneration: Int { generation }

    func isCurrent(_ generation: Int) -> Bool { generation == self.generation }

    mutating func expand() {
        isExpanded = true
    }

    /// Collapsing retires every in-flight page: the generation moves so a late
    /// publish is dropped, and the next expansion starts from fresh first
    /// pages.
    @discardableResult
    mutating func collapse() -> Int {
        let generation = retirePages()
        isExpanded = false
        rowsByProfile = [:]
        nextCursorByProfile = [:]
        unavailableProfileIDs = []
        return generation
    }

    /// Retires the pages in flight without clearing what is already published.
    /// A newer archive authority must replace a pass that is still reading: the
    /// pass's task is cancelled as a best effort, and its page was read before
    /// that authority landed, so the generation moves here and the late page is
    /// refused. Published rows stay because the fresh pass's first page is the
    /// whole authority for its server and replaces them.
    @discardableResult
    mutating func retirePages() -> Int {
        generation &+= 1
        isLoading = false
        return generation
    }

    /// Reconciles with the current capable-server snapshot. Rows and cursors of
    /// a server that is no longer capable or connected are dropped, because a
    /// page read is their only authority.
    mutating func reconcile(_ sources: [ArchivedSessionsProfileSource]) {
        let readable = Set(sources.filter(\.isConnected).map(\.profileID))
        rowsByProfile = rowsByProfile.filter { readable.contains($0.key) }
        nextCursorByProfile = nextCursorByProfile.filter { readable.contains($0.key) }
        unavailableProfileIDs.formIntersection(Set(sources.map(\.profileID)))
        for source in sources where !source.isConnected {
            unavailableProfileIDs.insert(source.profileID)
        }
    }

    /// The reads for one pass: first pages for connected servers, or the
    /// unpublished next pages when the user asked for more.
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

    /// Publishes one admitted page. Returns false when the pass was retired or
    /// the read did not produce a page, so the caller stops paging.
    /// `requestedCursor` is the page the caller asked for: a first page (nil)
    /// replaces the server's rows, while a continuation page extends them, so
    /// "Show more" cannot discard the pages the user already saw.
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

    /// Records that a server's page could not be read.
    mutating func markUnavailable(_ profileID: String) {
        unavailableProfileIDs.insert(profileID)
    }

    /// Drops a server's continuation cursor after the Gateway refused it as
    /// unknown (expired or evicted). The same cursor can never succeed, so the
    /// caller re-reads that server's first page and paging starts over instead
    /// of leaving a control that repeats the refusal. Reports whether a cursor
    /// was actually dropped.
    @discardableResult
    mutating func discardCursor(_ profileID: String) -> Bool {
        nextCursorByProfile.removeValue(forKey: profileID) != nil
    }

    /// Applies the dashboard's summed archive count. Zero means no archived
    /// session exists on any capable server, so the container closes and every
    /// in-flight page retires. The caller owns cancelling its own pass; this
    /// reports whether the container closed.
    @discardableResult
    mutating func reconcileCount(_ count: Int?) -> Bool {
        guard count == 0 else { return false }
        collapse()
        return true
    }

    /// Appends a continuation page in Gateway order, dropping an ID the
    /// container already holds so a repeated row cannot appear twice.
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
        /// No row exists for the ID. A summary never materializes one, so the
        /// caller must ask for an authoritative list read instead.
        case unknownSession
        case updated
    }

    private(set) var sessions: [SessionSummary] = []
    private(set) var freshness: SessionCatalogFreshness = .stale
    /// Gateway-owned archived-session count for this profile's dashboard
    /// projection. Retained while a list is unavailable; `nil` means the count
    /// has never been observed for this exact catalog.
    private(set) var archivedCount: Int?
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

    mutating func markLoadUnavailable() {
        freshness = .stale
        // A failed complete list cannot erase individually observed summaries.
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

    /// Applies the authoritative archive response: the row leaves the dashboard
    /// projection immediately. Membership stays Gateway-owned, so nothing here
    /// remembers the ID — an archived row is absent from the `exclude`
    /// projection, and a summary update can never materialize a row on its own.
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
            archivedAt: summary.archivedAt,
            gatewayProfileID: summary.gatewayProfileID,
            gatewayProfileLabel: summary.gatewayProfileLabel
        )
    }
}
