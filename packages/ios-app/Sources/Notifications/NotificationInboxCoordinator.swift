import Foundation
import Observation

enum NotificationInboxKind: String, Codable, CaseIterable, Sendable {
    case explicit, ask
    case agentFinished = "agent_finished"

    var label: String {
        switch self {
        case .explicit: "Agent alert"
        case .ask: "Input needed"
        case .agentFinished: "Response complete"
        }
    }

    var icon: String {
        switch self {
        case .explicit: "bell.fill"
        case .ask: "questionmark.bubble.fill"
        case .agentFinished: "checkmark.circle.fill"
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
    }

    static func list(client: GatewayClient) async throws -> Snapshot {
        do { return try await listOnce(client: client) }
        catch let failure as GatewayFailure where failure.code == "conflict" {
            return try await listOnce(client: client)
        }
    }

    private static func listOnce(client: GatewayClient) async throws -> Snapshot {
        var cursor: String?
        var revision: String?
        var unreadCount: Int?
        var retained: [GatewayNotificationInboxItem] = []
        var retainedBytes = 0
        for _ in 0..<12 {
            let page: GatewayNotificationInboxPage = try await client.request(
                "notification.inbox.list",
                ListParams(cursor: cursor, limit: NotificationInboxAdmissionPolicy.maximumPageCount)
            )
            guard revision == nil || revision == page.revision,
                  unreadCount == nil || unreadCount == page.unreadCount else {
                throw GatewayFailure(
                    code: "conflict",
                    message: "Notifications changed while loading. Try again.",
                    retryable: true,
                    details: nil
                )
            }
            revision = page.revision
            unreadCount = page.unreadCount
            let pageBytes = (try? JSONEncoder.gateway.encode(page.notifications).count) ?? .max
            guard retained.count + page.notifications.count <= NotificationInboxAdmissionPolicy.maximumRetainedCount,
                  retainedBytes <= NotificationInboxAdmissionPolicy.maximumAggregateBytes - pageBytes else {
                throw GatewayFailure(
                    code: "invalid_response",
                    message: "The notification inbox exceeded its bounded capacity.",
                    retryable: false,
                    details: nil
                )
            }
            retained.append(contentsOf: page.notifications)
            retainedBytes += pageBytes
            guard let next = page.nextCursor else {
                return Snapshot(
                    notifications: retained,
                    revision: page.revision,
                    unreadCount: page.unreadCount
                )
            }
            guard next != cursor else {
                throw GatewayFailure(
                    code: "invalid_response",
                    message: "The notification inbox returned a repeated cursor.",
                    retryable: false,
                    details: nil
                )
            }
            cursor = next
        }
        throw GatewayFailure(
            code: "invalid_response",
            message: "The notification inbox exceeded its page bound.",
            retryable: false,
            details: nil
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
    }

    private struct CacheDocument: Codable { let version: Int; let buckets: [String: Bucket] }
    private static let cacheKey = "notificationInbox.projection.v1"

    private let defaults: UserDefaults
    private(set) var buckets: [String: Bucket] = [:]
    private(set) var loadingProfileIDs = Set<String>()
    private var failuresByProfile: [String: String] = [:]
    private var requestGenerationByProfile: [String: Int] = [:]

    var failure: String? {
        let values = Array(Set(failuresByProfile.values)).sorted()
        guard !values.isEmpty else { return nil }
        return values.count == 1 ? values[0] : "Some paired Gateways could not load notifications."
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        guard let data = defaults.data(forKey: Self.cacheKey),
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
                && bucket.unreadCount == bucket.notifications.filter(\.isUnread).count
        }
        guard retained.values.reduce(0, { $0 + $1.notifications.count }) <= NotificationInboxAdmissionPolicy.maximumRetainedCount else { return }
        buckets = retained
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
        let generation = (requestGenerationByProfile[profileID] ?? 0) &+ 1
        requestGenerationByProfile[profileID] = generation
        loadingProfileIDs.insert(profileID)
        failuresByProfile.removeValue(forKey: profileID)
        return generation
    }

    func install(
        profile: GatewayProfile,
        snapshot: NotificationInboxGatewayClient.Snapshot,
        generation: Int
    ) {
        guard requestGenerationByProfile[profile.id] == generation else { return }
        buckets[profile.id] = Bucket(
            profileLabel: profile.label,
            machineID: profile.machineId,
            notifications: snapshot.notifications,
            revision: snapshot.revision,
            unreadCount: snapshot.unreadCount
        )
        loadingProfileIDs.remove(profile.id)
        failuresByProfile.removeValue(forKey: profile.id)
        persist()
    }

    func fail(profileID: String, generation: Int, message: String) {
        guard requestGenerationByProfile[profileID] == generation else { return }
        loadingProfileIDs.remove(profileID)
        failuresByProfile[profileID] = message
    }

    func retainProfiles(_ profileIDs: Set<String>) {
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
        persist()
    }

    func markAllReadOptimistically() {
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

    private func persist() {
        let newest = notifications.prefix(NotificationInboxAdmissionPolicy.maximumRetainedCount)
        let retainedIDs = Set(newest.map(\.id))
        var retained = buckets
        for (profileID, var bucket) in retained {
            bucket.notifications = bucket.notifications.filter {
                retainedIDs.contains("\(profileID):\($0.id)")
            }
            bucket.unreadCount = bucket.notifications.filter(\.isUnread).count
            retained[profileID] = bucket
        }
        guard let data = try? JSONEncoder.gateway.encode(CacheDocument(version: 1, buckets: retained)),
              data.count <= NotificationInboxAdmissionPolicy.maximumAggregateBytes else { return }
        defaults.set(data, forKey: Self.cacheKey)
    }
}
