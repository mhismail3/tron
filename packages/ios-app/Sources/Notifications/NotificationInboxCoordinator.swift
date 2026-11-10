import Foundation
import Observation
import TronMobileCore

enum NotificationInboxFilter: String, Codable, CaseIterable, Identifiable, Sendable {
    case all
    case unread

    var id: String { rawValue }

    var label: String {
        switch self {
        case .all: "All"
        case .unread: "Unread"
        }
    }
}

struct NotificationInboxPosition: Hashable, Comparable {
    let milliseconds: Int
    let id: String

    init(milliseconds: Int, id: String) {
        self.milliseconds = milliseconds
        self.id = id
    }

    init?(cursor: String) {
        guard let separator = cursor.firstIndex(of: "."),
              let milliseconds = Int(cursor[cursor.startIndex..<separator]) else { return nil }
        let id = String(cursor[cursor.index(after: separator)...])
        guard !id.isEmpty, id.utf8.count <= 160 else { return nil }
        self.init(milliseconds: milliseconds, id: id)
    }

    var cursor: String { "\(milliseconds).\(id)" }

    static func < (left: Self, right: Self) -> Bool {
        left.milliseconds != right.milliseconds ? left.milliseconds > right.milliseconds : left.id < right.id
    }
}

extension GatewayNotificationInboxItem {
    var inboxPosition: NotificationInboxPosition {
        let date = GatewayTimestamp.parse(createdAt) ?? .distantPast
        return NotificationInboxPosition(
            milliseconds: Int((date.timeIntervalSince1970 * 1_000).rounded()),
            id: id
        )
    }

    func markingRead(at date: Date) -> Self {
        Self(
            version: version,
            id: id,
            kind: kind,
            createdAt: createdAt,
            updatedAt: GatewayTimestamp.string(from: date),
            title: title,
            message: message,
            sessionId: sessionId,
            isUnread: false,
            outcome: outcome
        )
    }
}

struct NotificationInboxWindow: Codable, Sendable, Equatable {
    var rows: [GatewayNotificationInboxItem] = []
    var nextCursor: String?
}

struct NotificationInboxWindowID: Hashable, Sendable {
    let profileID: String
    let filter: NotificationInboxFilter
}

struct NotificationInboxOlderPage: Hashable, Sendable {
    let profileID: String
    let filter: NotificationInboxFilter
    let cursor: String
}

struct NotificationInboxReadAllTarget: Hashable, Sendable {
    let profileID: String
    let through: String
}

struct NotificationInboxItem: Hashable, Identifiable, Sendable {
    let profileID: String
    let profileLabel: String
    let machineID: String
    let notification: GatewayNotificationInboxItem

    var id: String { "\(profileID):\(notification.id)" }
}

enum NotificationInboxGatewayClient {
    #if HOSTED_TEST
    @TaskLocal static var hostedAfterPage: (@Sendable () async -> Void)?
    #endif

    private struct ListParams: Encodable { let filter: NotificationInboxFilter; let cursor: String?; let limit: Int }
    private struct ReadParams: Encodable { let commandId: String; let id: String }
    private struct ReadRequestParams: Encodable { let commandId: String; let requestId: String }
    private struct ReadAllParams: Encodable { let commandId: String; let through: String }
    private struct ReadResponse: Decodable { let changed: Bool; let id: String? }
    private struct ReadAllResponse: Decodable { let changed: Int }

    struct Snapshot: Sendable {
        let notifications: [GatewayNotificationInboxItem]
        let revision: String
        let unreadCount: Int
        let nextCursor: String?
        let connectionID: Int

        init(
            notifications: [GatewayNotificationInboxItem],
            revision: String,
            unreadCount: Int,
            nextCursor: String? = nil,
            connectionID: Int = 0
        ) {
            self.notifications = notifications
            self.revision = revision
            self.unreadCount = unreadCount
            self.nextCursor = nextCursor
            self.connectionID = connectionID
        }
    }

    static func list(
        client: GatewayClient,
        filter: NotificationInboxFilter,
        cursor: String? = nil,
        expectedConnectionID: Int? = nil
    ) async throws -> Snapshot {
        guard let connectionID = await client.activeConnectionID(),
              expectedConnectionID == nil || expectedConnectionID == connectionID else {
            throw GatewayFailure(code: "disconnected", message: "The Mac gateway is offline.", retryable: true, details: nil)
        }
        try Task.checkCancellation()
        let page: GatewayNotificationInboxPage = try await client.request(
            "notification.inbox.list",
            ListParams(filter: filter, cursor: cursor, limit: NotificationInboxAdmissionPolicy.maximumPageCount),
            expectedEpochID: connectionID
        )
        #if HOSTED_TEST
        await hostedAfterPage?()
        #endif
        try Task.checkCancellation()
        guard await client.activeConnectionID() == connectionID else { throw CancellationError() }
        return Snapshot(
            notifications: page.notifications,
            revision: page.revision,
            unreadCount: page.unreadCount,
            nextCursor: page.nextCursor,
            connectionID: connectionID
        )
    }

    static func markRead(id: String, client: GatewayClient, commandID: String) async throws {
        let _: ReadResponse = try await client.request(
            "notification.inbox.read",
            ReadParams(commandId: commandID, id: id)
        )
    }

    static func markRead(requestID: String, client: GatewayClient, commandID: String) async throws {
        let _: ReadResponse = try await client.request(
            "notification.inbox.read",
            ReadRequestParams(commandId: commandID, requestId: requestID)
        )
    }

    static func markAllRead(client: GatewayClient, commandID: String, through: String) async throws {
        let _: ReadAllResponse = try await client.request(
            "notification.inbox.readAll",
            ReadAllParams(commandId: commandID, through: through)
        )
    }
}

@MainActor
@Observable
final class NotificationInboxCoordinator {
    struct Bucket: Codable, Sendable {
        let profileLabel: String
        let machineID: String
        var all: NotificationInboxWindow
        var unread: NotificationInboxWindow
        var revision: String
        var unreadCount: Int
        var connectionID: Int?

        func window(_ filter: NotificationInboxFilter) -> NotificationInboxWindow {
            filter == .all ? all : unread
        }

        mutating func setWindow(_ filter: NotificationInboxFilter, _ window: NotificationInboxWindow) {
            switch filter {
            case .all: all = window
            case .unread: unread = window
            }
        }
    }

    private struct CacheDocument: Codable { let version: Int; let buckets: [String: Bucket] }
    private static let cacheKey = "notificationInbox.projection.v2"

    private let defaults: UserDefaults?
    private(set) var buckets: [String: Bucket] = [:]
    private(set) var loadingProfileIDs = Set<String>()
    private(set) var isMarkingAllRead = false
    private var nextRefreshGeneration = 0
    private var requestGenerationByProfile: [String: Int] = [:]
    private var refreshTasks: [String: Task<Void, Never>] = [:]
    private var pendingRefreshProfiles: [String: GatewayProfile] = [:]
    private var loadingOlderWindows = Set<NotificationInboxWindowID>()
    private var windowRequestGenerations: [NotificationInboxWindowID: Int] = [:]

    init(defaults: UserDefaults? = nil) {
        self.defaults = defaults
        guard let data = defaults?.data(forKey: Self.cacheKey),
              data.count <= NotificationInboxAdmissionPolicy.maximumAggregateBytes,
              let cached = try? JSONDecoder.gateway.decode(CacheDocument.self, from: data),
              cached.version == 2 else { return }
        let retained = cached.buckets.filter { profileID, bucket in
            !profileID.isEmpty && profileID.utf8.count <= 160
                && !bucket.profileLabel.isEmpty && bucket.profileLabel.utf8.count <= 256
                && !bucket.machineID.isEmpty && bucket.machineID.utf8.count <= 256
                && bucket.revision.utf8.count <= 128
                && bucket.all.rows.allSatisfy(NotificationInboxAdmissionPolicy.admits)
                && bucket.unread.rows.allSatisfy(NotificationInboxAdmissionPolicy.admits)
                && bucket.unread.rows.allSatisfy(\.isUnread)
                && bucket.unreadCount >= bucket.unread.rows.count
                && bucket.unreadCount <= NotificationInboxAdmissionPolicy.maximumRetainedCount
        }
        guard Self.retainedRowCount(retained) <= NotificationInboxAdmissionPolicy.maximumRetainedCount else { return }
        buckets = retained.mapValues { cached in
            var current = cached
            current.connectionID = nil
            return current
        }
    }

    func notifications(filter: NotificationInboxFilter) -> [NotificationInboxItem] {
        buckets.flatMap { profileID, bucket in
            bucket.window(filter).rows.map {
                NotificationInboxItem(
                    profileID: profileID,
                    profileLabel: bucket.profileLabel,
                    machineID: bucket.machineID,
                    notification: $0
                )
            }
        }
        .sorted { $0.notification.inboxPosition < $1.notification.inboxPosition }
    }

    var notifications: [NotificationInboxItem] { notifications(filter: .all) }

    var unreadCount: Int {
        min(NotificationInboxAdmissionPolicy.maximumRetainedCount, buckets.values.reduce(0) { $0 + $1.unreadCount })
    }

    var isLoadingFirstWindows: Bool { !loadingProfileIDs.isEmpty && buckets.isEmpty }

    func hasOlderPages(filter: NotificationInboxFilter) -> Bool {
        buckets.values.contains { $0.window(filter).nextCursor != nil }
    }

    func olderPageTriggers(filter: NotificationInboxFilter) -> [NotificationInboxOlderPage] {
        buckets.compactMap { profileID, bucket in
            bucket.window(filter).nextCursor.map {
                NotificationInboxOlderPage(profileID: profileID, filter: filter, cursor: $0)
            }
        }
        .sorted { ($0.profileID, $0.cursor) < ($1.profileID, $1.cursor) }
    }

    func isLoadingOlder(_ trigger: NotificationInboxOlderPage) -> Bool {
        loadingOlderWindows.contains(NotificationInboxWindowID(profileID: trigger.profileID, filter: trigger.filter))
    }

    @discardableResult
    func begin(profileID: String) -> Int {
        invalidateOlderWindows(profileID: profileID)
        nextRefreshGeneration &+= 1
        requestGenerationByProfile[profileID] = nextRefreshGeneration
        loadingProfileIDs.insert(profileID)
        return nextRefreshGeneration
    }

    func merge(
        profile: GatewayProfile,
        all: NotificationInboxGatewayClient.Snapshot,
        unread: NotificationInboxGatewayClient.Snapshot,
        generation: Int
    ) {
        guard requestGenerationByProfile[profile.id] == generation else { return }
        invalidateOlderWindows(profileID: profile.id)
        let previous = buckets[profile.id]
        buckets[profile.id] = Bucket(
            profileLabel: profile.label,
            machineID: profile.machineId,
            all: Self.merged(
                existing: previous?.all ?? NotificationInboxWindow(),
                page: all.notifications,
                nextCursor: all.nextCursor
            ),
            unread: Self.merged(
                existing: previous?.unread ?? NotificationInboxWindow(),
                page: unread.notifications,
                nextCursor: unread.nextCursor
            ),
            revision: all.revision,
            unreadCount: all.unreadCount,
            connectionID: all.connectionID
        )
        loadingProfileIDs.remove(profile.id)
        persist()
    }

    private static func merged(
        existing: NotificationInboxWindow,
        page: [GatewayNotificationInboxItem],
        nextCursor: String?
    ) -> NotificationInboxWindow {
        guard let boundary = page.last?.inboxPosition else {
            return NotificationInboxWindow()
        }
        guard nextCursor != nil else {
            return NotificationInboxWindow(rows: page, nextCursor: nil)
        }
        let pageIDs = Set(page.map(\.id))
        let older = existing.rows.filter { !pageIDs.contains($0.id) && $0.inboxPosition > boundary }
        return NotificationInboxWindow(
            rows: page + older,
            nextCursor: older.isEmpty ? nextCursor : existing.nextCursor
        )
    }

    @discardableResult
    func applyInboxChanged(profileID: String, change: NotificationInboxChanged?) -> Bool {
        guard var bucket = buckets[profileID] else { return true }
        guard let change else { return true }
        bucket.unreadCount = change.unreadCount
        buckets[profileID] = bucket
        persist()
        return change.revision != bucket.revision
    }

    @discardableResult
    func loadNextPage(
        profileID: String,
        filter: NotificationInboxFilter,
        operation: @MainActor (String, Int?) async throws -> NotificationInboxGatewayClient.Snapshot
    ) async -> Bool {
        let windowID = NotificationInboxWindowID(profileID: profileID, filter: filter)
        guard !loadingOlderWindows.contains(windowID),
              let initial = buckets[profileID],
              let cursor = initial.window(filter).nextCursor else { return false }
        nextRefreshGeneration &+= 1
        let generation = nextRefreshGeneration
        windowRequestGenerations[windowID] = generation
        loadingOlderWindows.insert(windowID)
        defer {
            if windowRequestGenerations[windowID] == generation {
                loadingOlderWindows.remove(windowID)
                windowRequestGenerations[windowID] = nil
            }
        }
        do {
            let snapshot = try await operation(cursor, initial.connectionID)
            guard !Task.isCancelled,
                  windowRequestGenerations[windowID] == generation,
                  var current = buckets[profileID],
                  current.window(filter).nextCursor == cursor,
                  snapshot.connectionID == initial.connectionID,
                  snapshot.notifications.allSatisfy(NotificationInboxAdmissionPolicy.admits) else { return false }
            var window = current.window(filter)
            let existing = Set(window.rows.map(\.id))
            guard snapshot.notifications.allSatisfy({ !existing.contains($0.id) }),
                  window.rows.count + snapshot.notifications.count <= NotificationInboxAdmissionPolicy.maximumRetainedCount else {
                return true
            }
            window.rows.append(contentsOf: snapshot.notifications)
            window.nextCursor = snapshot.nextCursor
            current.setWindow(filter, window)
            current.unreadCount = snapshot.unreadCount
            buckets[profileID] = current
            persist()
            return false
        } catch {
            return false
        }
    }

    @discardableResult
    func scheduleRefresh(
        profile: GatewayProfile,
        operation: @escaping @MainActor @Sendable (GatewayProfile, Int) async -> Void
    ) -> Task<Void, Never> {
        invalidateOlderWindows(profileID: profile.id)
        if let task = refreshTasks[profile.id] {
            pendingRefreshProfiles[profile.id] = profile
            return task
        }
        let generation = begin(profileID: profile.id)
        let task = Task { @MainActor [weak self, operation] in
            guard let self else { return }
            var currentProfile = profile
            var currentGeneration = generation
            defer {
                if self.requestGenerationByProfile[profile.id] == currentGeneration {
                    self.refreshTasks[profile.id] = nil
                    self.pendingRefreshProfiles[profile.id] = nil
                    self.requestGenerationByProfile[profile.id] = nil
                    self.loadingProfileIDs.remove(profile.id)
                }
            }
            while true {
                guard !Task.isCancelled,
                      self.requestGenerationByProfile[currentProfile.id] == currentGeneration else { return }
                await operation(currentProfile, currentGeneration)
                guard self.requestGenerationByProfile[currentProfile.id] == currentGeneration else { return }
                guard !Task.isCancelled,
                      let pending = self.pendingRefreshProfiles.removeValue(forKey: currentProfile.id) else { return }
                currentProfile = pending
                currentGeneration = self.begin(profileID: currentProfile.id)
            }
        }
        refreshTasks[profile.id] = task
        return task
    }

    func cancelRefreshes() {
        for task in refreshTasks.values { task.cancel() }
        loadingOlderWindows.removeAll()
        windowRequestGenerations.removeAll()
        refreshTasks.removeAll()
        pendingRefreshProfiles.removeAll()
        requestGenerationByProfile.removeAll()
        loadingProfileIDs.removeAll()
    }

    func retainProfiles(_ profileIDs: Set<String>) {
        loadingOlderWindows = loadingOlderWindows.filter { profileIDs.contains($0.profileID) }
        windowRequestGenerations = windowRequestGenerations.filter { profileIDs.contains($0.key.profileID) }
        for profileID in Array(refreshTasks.keys) where !profileIDs.contains(profileID) {
            refreshTasks[profileID]?.cancel()
            refreshTasks[profileID] = nil
            pendingRefreshProfiles[profileID] = nil
            requestGenerationByProfile[profileID] = nil
            loadingProfileIDs.remove(profileID)
        }
        buckets = buckets.filter { profileIDs.contains($0.key) }
        loadingProfileIDs.formIntersection(profileIDs)
        requestGenerationByProfile = requestGenerationByProfile.filter { profileIDs.contains($0.key) }
        persist()
    }

    func markReadOptimistically(_ item: NotificationInboxItem) {
        guard var bucket = buckets[item.profileID],
              (bucket.all.rows + bucket.unread.rows).contains(where: { $0.id == item.notification.id && $0.isUnread })
        else { return }
        if let index = bucket.all.rows.firstIndex(where: { $0.id == item.notification.id }) {
            bucket.all.rows[index] = bucket.all.rows[index].markingRead(at: .now)
        }
        bucket.unread.rows.removeAll { $0.id == item.notification.id }
        bucket.unreadCount = max(0, bucket.unreadCount - 1)
        buckets[item.profileID] = bucket
        invalidateOlderWindows(profileID: item.profileID)
        persist()
    }

    var readAllTargets: [NotificationInboxReadAllTarget] {
        buckets.compactMap { profileID, bucket in
            guard bucket.unreadCount > 0,
                  let newest = (bucket.all.rows + bucket.unread.rows)
                      .min(by: { $0.inboxPosition < $1.inboxPosition }) else { return nil }
            return NotificationInboxReadAllTarget(profileID: profileID, through: newest.inboxPosition.cursor)
        }
        .sorted { $0.profileID < $1.profileID }
    }

    func beginMarkingAllRead() { isMarkingAllRead = true }

    func finishMarkingAllRead() { isMarkingAllRead = false }

    func markAllReadOptimistically(_ target: NotificationInboxReadAllTarget) {
        guard var bucket = buckets[target.profileID],
              let cut = NotificationInboxPosition(cursor: target.through) else { return }
        let unreadAtOrOlder = Set(
            (bucket.all.rows + bucket.unread.rows)
                .filter { $0.isUnread && $0.inboxPosition >= cut }
                .map(\.id)
        )
        bucket.all.rows = bucket.all.rows.map { $0.isUnread && $0.inboxPosition >= cut ? $0.markingRead(at: .now) : $0 }
        bucket.unread.rows.removeAll { $0.inboxPosition >= cut }
        bucket.unreadCount = max(0, bucket.unreadCount - unreadAtOrOlder.count)
        buckets[target.profileID] = bucket
        invalidateOlderWindows(profileID: target.profileID)
        persist()
    }

    private func invalidateOlderWindows(profileID: String) {
        for filter in NotificationInboxFilter.allCases {
            let windowID = NotificationInboxWindowID(profileID: profileID, filter: filter)
            windowRequestGenerations[windowID] = nil
            loadingOlderWindows.remove(windowID)
        }
    }

    private static func retainedRowCount(_ buckets: [String: Bucket]) -> Int {
        buckets.values.reduce(0) { $0 + $1.all.rows.count + $1.unread.rows.count }
    }

    private func persist() {
        var retained = buckets
        var windowRows: [(windowID: NotificationInboxWindowID, row: GatewayNotificationInboxItem)] = []
        for (profileID, bucket) in retained {
            for row in bucket.all.rows {
                windowRows.append((NotificationInboxWindowID(profileID: profileID, filter: .all), row))
            }
            for row in bucket.unread.rows {
                windowRows.append((NotificationInboxWindowID(profileID: profileID, filter: .unread), row))
            }
        }
        let retainedRows = Set(
            windowRows
                .sorted { $0.row.inboxPosition < $1.row.inboxPosition }
                .prefix(NotificationInboxAdmissionPolicy.maximumRetainedCount)
                .map { "\($0.windowID.profileID):\($0.windowID.filter.rawValue):\($0.row.id)" }
        )
        for (profileID, var bucket) in retained {
            for filter in NotificationInboxFilter.allCases {
                var window = bucket.window(filter)
                let kept = window.rows.filter { retainedRows.contains("\(profileID):\(filter.rawValue):\($0.id)") }
                if kept.count != window.rows.count {
                    window.nextCursor = kept.last?.inboxPosition.cursor
                    window.rows = kept
                    bucket.setWindow(filter, window)
                }
            }
            retained[profileID] = bucket
        }
        guard let data = try? JSONEncoder.gateway.encode(CacheDocument(version: 2, buckets: retained)),
              data.count <= NotificationInboxAdmissionPolicy.maximumAggregateBytes else { return }
        defaults?.set(data, forKey: Self.cacheKey)
    }
}
