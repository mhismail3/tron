import Foundation

// MARK: - Native Notification Contract

enum NotificationAuthorizationState: String, Codable, Equatable, Sendable {
    case notDetermined = "not_determined"
    case denied
    case authorized
    case provisional
    case ephemeral
}

enum NotificationAPNSEnvironment: String, Codable, Equatable, Sendable {
    case sandbox
    case production
}

enum NotificationTransportMode: String, Codable, Equatable, Sendable {
    case relay
    case direct
}

struct NotificationTransportReadinessDTO: Decodable, Equatable, Sendable {
    let mode: NotificationTransportMode
    let configured: Bool
    let problemCode: String?
}

enum NotificationAcknowledgement: String, Codable, Equatable, Sendable {
    case opened
    case complete
    case snooze
    case clearUnread = "clear_unread"
}

struct NotificationDeviceUpsertDTO: Encodable, Equatable, Sendable {
    let installationId: String
    let clientServerId: String
    let topic: String
    let environment: NotificationAPNSEnvironment
    let authorizationStatus: NotificationAuthorizationState
    let token: String?
}

struct NotificationDeviceRegistrationDTO: Decodable, Equatable, Sendable {
    let installationId: String
    let authorizationStatus: NotificationAuthorizationState
    let environment: NotificationAPNSEnvironment
    let topic: String
    let enabled: Bool
    let ready: Bool
    let registeredAt: String
    let transport: NotificationTransportReadinessDTO
}

struct NotificationDeviceDisableDTO: Decodable, Equatable, Sendable {
    let installationId: String
    let enabled: Bool
    let changed: Bool
}

struct NotificationDeliveryDTO: Codable, Equatable, Identifiable, Sendable {
    let deliveryId: String
    let workerId: String
    let workerVersion: String
    let sourceWorkerId: String?
    let sourceWorkerVersion: String?
    let producerWorkerId: String?
    let producerWorkerVersion: String?
    let sourceInvocationId: String?
    let sourceRecordId: String?
    let title: String
    let body: String
    let threadKey: String?
    let expiresAt: String
    let notBefore: String?
    let transportMode: NotificationTransportMode?
    let actions: [String]
    let onOpen: String?
    var readAt: String?
    var terminalResponse: String?
    var terminalRespondedAt: String?
    let createdAt: String
    var updatedAt: String
    let targetSummary: NotificationDeliveryTargetSummaryDTO

    var id: String { deliveryId }
    var isUnread: Bool { readAt == nil }
}

struct NotificationDeliveryTargetSummaryDTO: Codable, Equatable, Sendable {
    let total: Int
    let queued: Int
    let retryWait: Int
    let acceptedByAPNs: Int
    let blocked: Int
    let permanentFailure: Int
    let expired: Int
    let cancelled: Int?
}

struct NotificationDeliveriesRequestDTO: Encodable, Equatable, Sendable {
    let cursor: String?
    let limit: Int
    let unreadOnly: Bool
}

struct NotificationDeliveriesPageDTO: Decodable, Equatable, Sendable {
    let deliveries: [NotificationDeliveryDTO]
    let unreadCount: Int
    let nextCursor: String?
}

struct NotificationAcknowledgeDTO: Encodable, Equatable, Sendable {
    let deliveryId: String
    let installationId: String
    let clientMutationId: String
    let acknowledgement: NotificationAcknowledgement
    let occurredAt: String?
}

struct NotificationAcknowledgementResultDTO: Decodable, Equatable, Sendable {
    let deliveryId: String
    let clientMutationId: String
    let acknowledgement: NotificationAcknowledgement
    let accepted: Bool
    let currentTerminalResponse: String?
    let read: Bool
    let eventRequired: Bool
    let workerId: String
    let sourceRecordId: String?
    let traceId: String
    let occurredAt: String
}

struct NotificationDeliveryStatusRequestDTO: Encodable, Equatable, Sendable {
    let deliveryId: String
}

struct NotificationDeliveryTargetDTO: Decodable, Equatable, Identifiable, Sendable {
    let targetId: String
    let installationId: String
    let state: String
    let attemptCount: Int
    let apnsId: String?
    let errorCode: String?
    let acceptedAt: String?
    let updatedAt: String

    var id: String { targetId }
}

struct NotificationDeliveryStatusDTO: Decodable, Equatable, Sendable {
    let delivery: NotificationDeliveryDTO
    let targets: [NotificationDeliveryTargetDTO]
    let attempts: [NotificationDeliveryAttemptDTO]?
}

struct NotificationDeliveryAttemptDTO: Decodable, Equatable, Identifiable, Sendable {
    let attemptId: String
    let targetId: String
    let attemptNumber: Int
    let state: String
    let apnsId: String?
    let errorCode: String?
    let startedAt: String
    let completedAt: String
    let transportKind: NotificationTransportMode?
    let providerRequestId: String?

    var id: String { attemptId }
}
