import Foundation
import Observation

enum NotificationInboxKind: String, Codable, CaseIterable, Sendable {
    case explicit, ask
    case agentFinished = "agent_finished"

    var label: String {
        switch self {
        case .explicit: "Agent alert"
        case .ask: "Input needed"
        case .agentFinished: "Agent finished"
        }
    }

    var icon: String {
        switch self {
        case .explicit: "bell.fill"
        case .ask: "questionmark.bubble.fill"
        // This category includes errors and interruptions, not just success.
        case .agentFinished: "stop.circle.fill"
        }
    }
}

enum NotificationInboxOutcome: String, Codable, CaseIterable, Sendable {
    case queued
    case acceptedByAPNs = "accepted_by_apns"
    case failed, ambiguous, expired

    var label: String {
        switch self {
        case .queued: "Sending"
        case .acceptedByAPNs: "Sent"
        case .failed: "Failed"
        case .ambiguous: "Delivery unknown"
        case .expired: "Expired"
        }
    }
}

struct GatewayNotificationInboxItem: Codable, Hashable, Identifiable, Sendable {
    let version: Int
    let id: String
    let kind: NotificationInboxKind
    let createdAt: String
    let updatedAt: String
    let title: String
    let message: String
    let sessionId: String
    let isUnread: Bool
    let outcome: NotificationInboxOutcome
}

struct GatewayNotificationInboxPage: Decodable, Sendable {
    let notifications: [GatewayNotificationInboxItem]
    let revision: String
    let unreadCount: Int
    let nextCursor: String?

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let notifications = try values.decode([GatewayNotificationInboxItem].self, forKey: .notifications)
        let revision = try values.decode(String.self, forKey: .revision)
        let unreadCount = try values.decode(Int.self, forKey: .unreadCount)
        let nextCursor = try values.decodeIfPresent(String.self, forKey: .nextCursor)
        guard notifications.count <= NotificationInboxAdmissionPolicy.maximumPageCount,
              notifications.allSatisfy(NotificationInboxAdmissionPolicy.admits),
              Set(notifications.map(\.id)).count == notifications.count,
              !revision.isEmpty, revision.utf8.count <= 128,
              (0...NotificationInboxAdmissionPolicy.maximumRetainedCount).contains(unreadCount),
              nextCursor.map({ !$0.isEmpty && $0.utf8.count <= 256 }) ?? true else {
            throw DecodingError.dataCorruptedError(
                forKey: .notifications,
                in: values,
                debugDescription: "Notification inbox page is invalid"
            )
        }
        self.notifications = notifications
        self.revision = revision
        self.unreadCount = unreadCount
        self.nextCursor = nextCursor
    }

    private enum CodingKeys: String, CodingKey { case notifications, revision, unreadCount, nextCursor }
}

struct NotificationInboxItem: Hashable, Identifiable, Sendable {
    let profileID: String
    let profileLabel: String
    let machineID: String
    let notification: GatewayNotificationInboxItem

    var id: String { "\(profileID):\(notification.id)" }
}

enum NotificationInboxAdmissionPolicy {
    static let maximumPageCount = 50
    static let maximumRetainedCount = 512
    static let maximumAggregateBytes = 512 * 1_024

    static func admits(_ item: GatewayNotificationInboxItem) -> Bool {
        guard item.version == 1,
              opaqueID(item.id, 160),
              bounded(item.title, 256),
              bounded(item.message, 512),
              sessionID(item.sessionId),
              let createdAt = GatewayTimestamp.parse(item.createdAt),
              let updatedAt = GatewayTimestamp.parse(item.updatedAt) else { return false }
        return updatedAt >= createdAt
    }

    private static func opaqueID(_ value: String, _ maximum: Int) -> Bool {
        (8...maximum).contains(value.utf8.count) && value.unicodeScalars.allSatisfy {
            CharacterSet.alphanumerics.contains($0) || "-_".unicodeScalars.contains($0)
        }
    }

    private static func sessionID(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 160 && value.unicodeScalars.allSatisfy {
            CharacterSet.alphanumerics.contains($0) || "-_:".unicodeScalars.contains($0)
        }
    }

    private static func bounded(_ value: String, _ maximum: Int) -> Bool {
        !value.isEmpty && value.utf8.count <= maximum
            && value.unicodeScalars.allSatisfy {
                !CharacterSet.controlCharacters.contains($0) || $0 == "\t" || $0 == "\n" || $0 == "\r"
            }
    }
}

enum NotificationInboxGatewayClient {
    #if HOSTED_TEST
    // Gate the real between-page suspension in one task, never global test state.
    @TaskLocal static var hostedAfterPage: (@Sendable () async -> Void)?
    #endif

    private struct ListParams: Encodable { let cursor: String?; let limit: Int }
    private struct ReadParams: Encodable { let commandId: String; let id: String }
    private struct ReadRequestParams: Encodable { let commandId: String; let requestId: String }
    private struct ReadAllParams: Encodable { let commandId: String }
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
        cursor: String? = nil,
        expectedRevision: String? = nil,
        expectedConnectionID: Int? = nil
    ) async throws -> Snapshot {
        guard let connectionID = await client.activeConnectionID(),
              expectedConnectionID == nil || expectedConnectionID == connectionID else {
            throw GatewayFailure(code: "disconnected", message: "The Mac gateway is offline.", retryable: true, details: nil)
        }
        try Task.checkCancellation()
        let page: GatewayNotificationInboxPage = try await client.request(
            "notification.inbox.list",
            ListParams(cursor: cursor, limit: NotificationInboxAdmissionPolicy.maximumPageCount),
            expectedEpochID: connectionID,
            diagnosticPurpose: "notification-page",
            diagnosticPage: cursor == nil ? 1 : 2
        )
        #if HOSTED_TEST
        await hostedAfterPage?()
        #endif
        try Task.checkCancellation()
        guard await client.activeConnectionID() == connectionID else { throw CancellationError() }
        guard expectedRevision == nil || expectedRevision == page.revision else {
            throw GatewayFailure(
                code: "conflict",
                message: "Notifications changed while loading. Try again.",
                retryable: true,
                details: nil
            )
        }
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

    static func markAllRead(client: GatewayClient, commandID: String) async throws {
        let _: ReadAllResponse = try await client.request(
            "notification.inbox.readAll",
            ReadAllParams(commandId: commandID)
        )
    }
}

@MainActor
@Observable
final class NotificationInboxCoordinator {
    struct Bucket: Codable, Sendable {
        let profileLabel: String
        let machineID: String
        var notifications: [GatewayNotificationInboxItem]
        var revision: String
        var unreadCount: Int
        var nextCursor: String?
        var connectionID: Int?
    }

    private struct CacheDocument: Codable { let version: Int; let buckets: [String: Bucket] }
    private static let cacheKey = "notificationInbox.projection.v1"

    private let defaults: UserDefaults?
    private(set) var buckets: [String: Bucket] = [:]
    private(set) var loadingProfileIDs = Set<String>()
    private var failuresByProfile: [String: String] = [:]
    // One coordinator-wide counter makes every admission unique without
    // retaining historical generations for removed profiles.
    private var nextRefreshGeneration = 0
    private var requestGenerationByProfile: [String: Int] = [:]
    private var refreshTasks: [String: Task<Void, Never>] = [:]
    private var pendingRefreshProfiles: [String: GatewayProfile] = [:]
    private var loadingOlderProfileIDs = Set<String>()
    private var pageRequestGenerations: [String: Int] = [:]

    var failure: String? {
        let values = Array(Set(failuresByProfile.values)).sorted()
        guard !values.isEmpty else { return nil }
        return values.count == 1 ? values[0] : "Some paired Gateways could not load notifications."
    }

    init(defaults: UserDefaults? = nil) {
        self.defaults = defaults
        guard let data = defaults?.data(forKey: Self.cacheKey),
              data.count <= NotificationInboxAdmissionPolicy.maximumAggregateBytes,
              let cached = try? JSONDecoder.gateway.decode(CacheDocument.self, from: data),
              cached.version == 1 else { return }
        let retained = cached.buckets.filter { profileID, bucket in
            !profileID.isEmpty && profileID.utf8.count <= 160
                && !bucket.profileLabel.isEmpty && bucket.profileLabel.utf8.count <= 256
                && !bucket.machineID.isEmpty && bucket.machineID.utf8.count <= 256
                && bucket.revision.utf8.count <= 128
                && bucket.notifications.count <= NotificationInboxAdmissionPolicy.maximumRetainedCount
                && bucket.notifications.allSatisfy(NotificationInboxAdmissionPolicy.admits)
                && bucket.unreadCount >= bucket.notifications.filter(\.isUnread).count
                && bucket.unreadCount <= NotificationInboxAdmissionPolicy.maximumRetainedCount
        }
        guard retained.values.reduce(0, { $0 + $1.notifications.count }) <= NotificationInboxAdmissionPolicy.maximumRetainedCount else { return }
        buckets = retained.mapValues { cached in
            var current = cached
            current.nextCursor = nil
            current.connectionID = nil
            return current
        }
    }

    var notifications: [NotificationInboxItem] {
        buckets.flatMap { profileID, bucket in
            bucket.notifications.map {
                NotificationInboxItem(
                    profileID: profileID,
                    profileLabel: bucket.profileLabel,
                    machineID: bucket.machineID,
                    notification: $0
                )
            }
        }
        .sorted {
            let left = GatewayTimestamp.parse($0.notification.createdAt) ?? .distantPast
            let right = GatewayTimestamp.parse($1.notification.createdAt) ?? .distantPast
            return left != right ? left > right : $0.id < $1.id
        }
    }

    var unreadCount: Int {
        min(NotificationInboxAdmissionPolicy.maximumRetainedCount, buckets.values.reduce(0) { $0 + $1.unreadCount })
    }

    var isLoading: Bool { !loadingProfileIDs.isEmpty }

    @discardableResult
    func begin(profileID: String) -> Int {
        invalidateOlderPage(profileID: profileID)
        nextRefreshGeneration &+= 1
        requestGenerationByProfile[profileID] = nextRefreshGeneration
        loadingProfileIDs.insert(profileID)
        failuresByProfile.removeValue(forKey: profileID)
        return nextRefreshGeneration
    }

    func install(
        profile: GatewayProfile,
        snapshot: NotificationInboxGatewayClient.Snapshot,
        generation: Int
    ) {
        guard requestGenerationByProfile[profile.id] == generation else { return }
        invalidateOlderPage(profileID: profile.id)
        buckets[profile.id] = Bucket(
            profileLabel: profile.label,
            machineID: profile.machineId,
            notifications: snapshot.notifications,
            revision: snapshot.revision,
            unreadCount: snapshot.unreadCount,
            nextCursor: snapshot.nextCursor,
            connectionID: snapshot.connectionID
        )
        loadingProfileIDs.remove(profile.id)
        failuresByProfile.removeValue(forKey: profile.id)
        persist()
    }

    var profilesWithOlderPages: [String] {
        buckets.compactMap { profileID, bucket in bucket.nextCursor == nil ? nil : profileID }.sorted()
    }

    var loadingOlderProfiles: Set<String> { loadingOlderProfileIDs }

    func loadNextPage(
        profileID: String,
        operation: @MainActor (String, String, Int?) async throws -> NotificationInboxGatewayClient.Snapshot
    ) async {
        guard !loadingOlderProfileIDs.contains(profileID),
              let initial = buckets[profileID],
              let cursor = initial.nextCursor else { return }
        nextRefreshGeneration &+= 1
        let generation = nextRefreshGeneration
        pageRequestGenerations[profileID] = generation
        loadingOlderProfileIDs.insert(profileID)
        defer {
            if pageRequestGenerations[profileID] == generation {
                loadingOlderProfileIDs.remove(profileID)
                pageRequestGenerations[profileID] = nil
            }
        }
        do {
            let snapshot = try await operation(cursor, initial.revision, initial.connectionID)
            guard !Task.isCancelled,
                  pageRequestGenerations[profileID] == generation,
                  var current = buckets[profileID],
                  current.nextCursor == cursor,
                  current.revision == initial.revision,
                  snapshot.revision == initial.revision,
                  snapshot.connectionID == initial.connectionID,
                  snapshot.notifications.allSatisfy(NotificationInboxAdmissionPolicy.admits) else { return }
            let existing = Set(current.notifications.map(\.id))
            guard snapshot.notifications.allSatisfy({ !existing.contains($0.id) }),
                  current.notifications.count + snapshot.notifications.count <= NotificationInboxAdmissionPolicy.maximumRetainedCount else {
                failuresByProfile[profileID] = "Notification history changed. Refresh to try again."
                return
            }
            current.notifications.append(contentsOf: snapshot.notifications)
            current.nextCursor = snapshot.nextCursor
            current.unreadCount = snapshot.unreadCount
            buckets[profileID] = current
            failuresByProfile.removeValue(forKey: profileID)
            persist()
        } catch is CancellationError {
            return
        } catch let failure as GatewayFailure where failure.code == "conflict" {
            guard !Task.isCancelled, pageRequestGenerations[profileID] == generation else { return }
            failuresByProfile[profileID] = failure.message
        } catch {
            guard !Task.isCancelled, pageRequestGenerations[profileID] == generation else { return }
            // An older-page read is optional presentation work; errors remain in
            // the owning inbox surface and never become a global mutation toast.
            failuresByProfile[profileID] = (error as? GatewayFailure)?.message ?? "Notification history is unavailable."
        }
    }

    func fail(profileID: String, generation: Int, message: String) {
        guard requestGenerationByProfile[profileID] == generation else { return }
        loadingProfileIDs.remove(profileID)
        failuresByProfile[profileID] = message
    }

    @discardableResult
    func scheduleRefresh(
        profile: GatewayProfile,
        operation: @escaping @MainActor @Sendable (GatewayProfile, Int) async -> Void
    ) -> Task<Void, Never> {
        invalidateOlderPage(profileID: profile.id)
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
                // Retired work must neither strand its loading flag nor clear
                // a remove/re-add successor's task, pending pass or generation.
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
        loadingOlderProfileIDs.removeAll()
        pageRequestGenerations.removeAll()
        refreshTasks.removeAll()
        pendingRefreshProfiles.removeAll()
        requestGenerationByProfile.removeAll()
        loadingProfileIDs.removeAll()
    }

    func retainProfiles(_ profileIDs: Set<String>) {
        loadingOlderProfileIDs.formIntersection(profileIDs)
        pageRequestGenerations = pageRequestGenerations.filter { profileIDs.contains($0.key) }
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
        failuresByProfile = failuresByProfile.filter { profileIDs.contains($0.key) }
        persist()
    }

    func markReadOptimistically(_ item: NotificationInboxItem) {
        guard var bucket = buckets[item.profileID],
              let index = bucket.notifications.firstIndex(where: { $0.id == item.notification.id }),
              bucket.notifications[index].isUnread else { return }
        let current = bucket.notifications[index]
        bucket.notifications[index] = GatewayNotificationInboxItem(
            version: current.version,
            id: current.id,
            kind: current.kind,
            createdAt: current.createdAt,
            updatedAt: GatewayTimestamp.string(from: .now),
            title: current.title,
            message: current.message,
            sessionId: current.sessionId,
            isUnread: false,
            outcome: current.outcome
        )
        bucket.unreadCount = max(0, bucket.unreadCount - 1)
        buckets[item.profileID] = bucket
        invalidateOlderPage(profileID: item.profileID)
        persist()
    }

    func markAllReadOptimistically() {
        for profileID in buckets.keys { invalidateOlderPage(profileID: profileID) }
        for (profileID, var bucket) in buckets {
            bucket.notifications = bucket.notifications.map { current in
                GatewayNotificationInboxItem(
                    version: current.version,
                    id: current.id,
                    kind: current.kind,
                    createdAt: current.createdAt,
                    updatedAt: current.updatedAt,
                    title: current.title,
                    message: current.message,
                    sessionId: current.sessionId,
                    isUnread: false,
                    outcome: current.outcome
                )
            }
            bucket.unreadCount = 0
            buckets[profileID] = bucket
        }
        persist()
    }

    private func invalidateOlderPage(profileID: String) {
        pageRequestGenerations[profileID] = nil
        loadingOlderProfileIDs.remove(profileID)
    }

    private func persist() {
        let newest = notifications.prefix(NotificationInboxAdmissionPolicy.maximumRetainedCount)
        let retainedIDs = Set(newest.map(\.id))
        var retained = buckets
        for (profileID, var bucket) in retained {
            bucket.notifications = bucket.notifications.filter {
                retainedIDs.contains("\(profileID):\($0.id)")
            }
            retained[profileID] = bucket
        }
        guard let data = try? JSONEncoder.gateway.encode(CacheDocument(version: 1, buckets: retained)),
              data.count <= NotificationInboxAdmissionPolicy.maximumAggregateBytes else { return }
        defaults?.set(data, forKey: Self.cacheKey)
    }
}
