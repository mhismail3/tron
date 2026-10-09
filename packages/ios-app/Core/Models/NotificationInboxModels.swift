import Foundation

// The Gateway's notification inbox wire projections and their admission
// bounds. The inbox coordinator that presents them stays in Notifications.

package enum NotificationInboxKind: String, Codable, CaseIterable, Sendable {
    case explicit, ask, waiting
    case agentFinished = "agent_finished"

    package var label: String {
        switch self {
        case .explicit: "Agent alert"
        case .ask: "Input needed"
        case .agentFinished: "Agent finished"
        case .waiting: "Waiting on background work"
        }
    }

    package var icon: String {
        switch self {
        case .explicit: "bell.fill"
        case .ask: "questionmark.bubble.fill"
        // This category includes errors and interruptions, not just success.
        case .agentFinished: "stop.circle.fill"
        case .waiting: "hourglass"
        }
    }
}

package enum NotificationInboxOutcome: String, Codable, CaseIterable, Sendable {
    case queued
    case acceptedByAPNs = "accepted_by_apns"
    case failed, ambiguous, expired

    package var label: String {
        switch self {
        case .queued: "Sending"
        case .acceptedByAPNs: "Sent"
        case .failed: "Failed"
        case .ambiguous: "Delivery unknown"
        case .expired: "Expired"
        }
    }
}

package struct GatewayNotificationInboxItem: Codable, Hashable, Identifiable, Sendable {
    package let version: Int
    package let id: String
    package let kind: NotificationInboxKind
    package let createdAt: String
    package let updatedAt: String
    package let title: String
    package let message: String
    package let sessionId: String
    package let isUnread: Bool
    package let outcome: NotificationInboxOutcome

    package init(
        version: Int,
        id: String,
        kind: NotificationInboxKind,
        createdAt: String,
        updatedAt: String,
        title: String,
        message: String,
        sessionId: String,
        isUnread: Bool,
        outcome: NotificationInboxOutcome
    ) {
        self.version = version
        self.id = id
        self.kind = kind
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.title = title
        self.message = message
        self.sessionId = sessionId
        self.isUnread = isUnread
        self.outcome = outcome
    }
}

package struct GatewayNotificationInboxPage: Decodable, Sendable {
    package let notifications: [GatewayNotificationInboxItem]
    package let revision: String
    package let unreadCount: Int
    package let nextCursor: String?

    package init(from decoder: Decoder) throws {
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

/// The coalesced `notification.inbox.changed` payload: the Gateway's committed
/// revision and its total unread count. The count is projected onto the bell
/// immediately; a refetch happens only when the revision is newer than the
/// projection's.
package struct NotificationInboxChanged: Decodable, Sendable, Equatable {
    package let revision: String
    package let unreadCount: Int

    package init(revision: String, unreadCount: Int) {
        self.revision = revision
        self.unreadCount = unreadCount
    }
}

package enum NotificationInboxAdmissionPolicy {
    // Match the Gateway page limit so one scroll request cannot over-read.
    package static let maximumPageCount = 50
    // Bound aggregate retained rows across profile buckets and windows.
    package static let maximumRetainedCount = 512
    // Cap encoded projection size while retaining bounded history.
    package static let maximumAggregateBytes = 512 * 1_024

    package static func admits(_ item: GatewayNotificationInboxItem) -> Bool {
        guard item.version == 1,
              opaqueID(item.id, 160),
              bounded(item.title, 256),
              bounded(item.message, 512),
              sessionID(item.sessionId),
              let createdAt = GatewayTimestamp.parse(item.createdAt),
              let updatedAt = GatewayTimestamp.parse(item.updatedAt) else { return false }
        return updatedAt >= createdAt
    }

    package static func admits(_ change: NotificationInboxChanged) -> Bool {
        !change.revision.isEmpty && change.revision.utf8.count <= 128
            && (0...maximumRetainedCount).contains(change.unreadCount)
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
